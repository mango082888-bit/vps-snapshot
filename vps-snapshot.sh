#!/bin/bash

#===============================================================================
# VPS 快照备份脚本 v1.1
# 支持: Ubuntu, Debian, CentOS, Alpine
# 功能: 系统快照 + rsync 远程同步 + Telegram 通知 + 自动清理
# 认证: 支持密码和 SSH 密钥两种方式
#===============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CONFIG_FILE="/etc/vps-snapshot.conf"
LOG_FILE="/var/log/vps-snapshot.log"
SSH_KEY_PATH="/root/.ssh/vps_snapshot_key"

print_banner() {
    echo -e "${BLUE}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║           VPS 快照备份脚本 v1.1                           ║"
    echo "║       支持 Ubuntu/Debian/CentOS/Alpine                    ║"
    echo "║       支持密码/SSH密钥认证                                ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log() { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }
error() { echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >> "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $1${NC}"; }

detect_os() {
    if [ -f /etc/os-release ]; then . /etc/os-release; echo "$ID"
    elif [ -f /etc/redhat-release ]; then echo "centos"
    else echo "unknown"; fi
}

install_dependencies() {
    local os=$(detect_os)
    log "检测到系统: $os"
    log "安装依赖包..."
    case $os in
        ubuntu|debian) apt-get update -qq && apt-get install -y -qq rsync sshpass curl tar gzip openssh-client ;;
        centos|rhel|fedora) yum install -y -q rsync sshpass curl tar gzip openssh-clients ;;
        alpine) apk add --no-cache rsync sshpass curl tar gzip openssh-client ;;
        *) error "不支持的系统: $os"; exit 1 ;;
    esac
    log "依赖安装完成"
}

generate_ssh_key() {
    log "生成 SSH 密钥对..."
    if [ -f "$SSH_KEY_PATH" ]; then
        warn "密钥已存在: $SSH_KEY_PATH"
        read -p "是否覆盖? [y/N]: " overwrite
        [[ ! "$overwrite" =~ ^[Yy]$ ]] && return 0
    fi
    ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -C "vps-snapshot-$(hostname)"
    chmod 600 "$SSH_KEY_PATH"
    log "密钥生成完成: $SSH_KEY_PATH"
}

copy_ssh_key_to_remote() {
    log "复制公钥到远程服务器 ${REMOTE_USER}@${REMOTE_IP}..."
    sshpass -p "$1" ssh-copy-id -i "${SSH_KEY_PATH}.pub" -o StrictHostKeyChecking=no -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_IP}"
    log "公钥复制完成"
}

test_ssh_connection() {
    log "测试 SSH 连接..."
    if ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o BatchMode=yes -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_IP}" "echo ok" &>/dev/null; then
        log "SSH 密钥连接成功 ✓"
        return 0
    else
        error "SSH 密钥连接失败"
        return 1
    fi
}

interactive_setup() {
    print_banner
    echo -e "${YELLOW}开始交互式配置...${NC}\n"

    read -p "请输入远程服务器 IP: " REMOTE_IP
    read -p "请输入 SSH 端口 [22]: " REMOTE_PORT
    REMOTE_PORT=${REMOTE_PORT:-22}
    read -p "请输入 SSH 用户名 [root]: " REMOTE_USER
    REMOTE_USER=${REMOTE_USER:-root}

    echo -e "\n${YELLOW}选择认证方式:${NC}"
    echo "1) SSH 密钥 (推荐，更安全)"
    echo "2) 密码"
    read -p "请选择 [1]: " AUTH_TYPE
    AUTH_TYPE=${AUTH_TYPE:-1}

    if [ "$AUTH_TYPE" = "1" ]; then
        setup_ssh_key_auth
    else
        setup_password_auth
    fi
}

setup_ssh_key_auth() {
    AUTH_METHOD="key"
    REMOTE_PASS=""
    
    echo -e "\n${YELLOW}SSH 密钥认证配置${NC}"
    
    if [ -f "$SSH_KEY_PATH" ]; then
        echo "检测到已有密钥: $SSH_KEY_PATH"
        read -p "使用现有密钥? [Y/n]: " use_existing
        [[ "$use_existing" =~ ^[Nn]$ ]] && generate_ssh_key
    else
        read -p "是否生成新的 SSH 密钥? [Y/n]: " gen_key
        [[ ! "$gen_key" =~ ^[Nn]$ ]] && generate_ssh_key
    fi
    
    echo -e "\n需要将公钥复制到远程服务器"
    read -s -p "请输入远程服务器密码 (仅用于复制公钥): " temp_pass
    echo
    
    copy_ssh_key_to_remote "$temp_pass"
    
    if test_ssh_connection; then
        echo -e "${GREEN}密钥认证配置成功！${NC}"
    else
        error "密钥认证失败"; exit 1
    fi
    
    continue_setup
}

setup_password_auth() {
    AUTH_METHOD="password"
    read -s -p "请输入 SSH 密码: " REMOTE_PASS
    echo
    continue_setup
}

continue_setup() {
    read -p "请输入远程备份目录 [/backup/snapshots]: " REMOTE_DIR
    REMOTE_DIR=${REMOTE_DIR:-/backup/snapshots}
    read -p "请输入本地快照目录 [/var/snapshots]: " LOCAL_DIR
    LOCAL_DIR=${LOCAL_DIR:-/var/snapshots}
    read -p "本地保留快照数量 [1]: " LOCAL_KEEP
    LOCAL_KEEP=${LOCAL_KEEP:-1}
    read -p "远程保留天数 [30]: " REMOTE_KEEP_DAYS
    REMOTE_KEEP_DAYS=${REMOTE_KEEP_DAYS:-30}

    read -p "是否启用 Telegram 通知? [y/N]: " ENABLE_TG
    if [[ "$ENABLE_TG" =~ ^[Yy]$ ]]; then
        read -p "请输入 Telegram Bot Token: " TG_BOT_TOKEN
        read -p "请输入 Telegram Chat ID: " TG_CHAT_ID
    fi

    echo -e "\n${YELLOW}选择要备份的内容:${NC}"
    echo "1) 完整系统 (排除临时文件)"
    echo "2) 仅 /etc /home /root /var/www"
    echo "3) 自定义目录"
    read -p "请选择 [1]: " BACKUP_TYPE
    BACKUP_TYPE=${BACKUP_TYPE:-1}

    case $BACKUP_TYPE in
        2) BACKUP_DIRS="/etc /home /root /var/www" ;;
        3) read -p "请输入要备份的目录 (空格分隔): " BACKUP_DIRS ;;
        *) BACKUP_DIRS="/" ;;
    esac

    save_config
}

save_config() {
    log "保存配置到 $CONFIG_FILE"
    cat > "$CONFIG_FILE" << CONF
AUTH_METHOD="$AUTH_METHOD"
SSH_KEY_PATH="$SSH_KEY_PATH"
REMOTE_IP="$REMOTE_IP"
REMOTE_PORT="$REMOTE_PORT"
REMOTE_USER="$REMOTE_USER"
REMOTE_PASS="$REMOTE_PASS"
REMOTE_DIR="$REMOTE_DIR"
LOCAL_DIR="$LOCAL_DIR"
LOCAL_KEEP="$LOCAL_KEEP"
REMOTE_KEEP_DAYS="$REMOTE_KEEP_DAYS"
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
BACKUP_DIRS="$BACKUP_DIRS"
CONF
    chmod 600 "$CONFIG_FILE"
    log "配置已保存"
}

load_config() {
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" || { error "配置文件不存在，请先运行: $0 setup"; return 1; }
}

ssh_exec() {
    if [ "$AUTH_METHOD" = "key" ]; then
        ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_IP}" "$1"
    else
        sshpass -p "$REMOTE_PASS" ssh -o StrictHostKeyChecking=no -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_IP}" "$1"
    fi
}

send_telegram() {
    [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ] && \
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d chat_id="$TG_CHAT_ID" -d text="$1" -d parse_mode="HTML" >/dev/null 2>&1
}

create_snapshot() {
    local hostname=$(hostname)
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local snapshot_name="${hostname}_${timestamp}.tar.gz"
    local snapshot_path="${LOCAL_DIR}/${snapshot_name}"

    mkdir -p "$LOCAL_DIR"
    log "开始创建快照: $snapshot_name"
    send_telegram "🔄 <b>开始备份</b>%0A主机: ${hostname}"

    local excludes="--exclude=/proc --exclude=/sys --exclude=/dev"
    excludes+=" --exclude=/run --exclude=/tmp --exclude=/mnt"
    excludes+=" --exclude=/media --exclude=/lost+found"
    excludes+=" --exclude=${LOCAL_DIR} --exclude=/var/cache"

    if [ "$BACKUP_DIRS" = "/" ]; then
        tar $excludes -czf "$snapshot_path" / 2>/dev/null || true
    else
        tar -czf "$snapshot_path" $BACKUP_DIRS 2>/dev/null || true
    fi

    log "快照创建完成: $snapshot_path ($(du -h "$snapshot_path" | cut -f1))"
    echo "$snapshot_path"
}

sync_to_remote() {
    local snapshot_path="$1"
    log "创建远程目录: $REMOTE_DIR"
    ssh_exec "mkdir -p $REMOTE_DIR"

    log "开始同步到远程..."
    if [ "$AUTH_METHOD" = "key" ]; then
        rsync -avz -e "ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no -p $REMOTE_PORT" \
            "$snapshot_path" "${REMOTE_USER}@${REMOTE_IP}:${REMOTE_DIR}/"
    else
        sshpass -p "$REMOTE_PASS" rsync -avz \
            -e "ssh -o StrictHostKeyChecking=no -p $REMOTE_PORT" \
            "$snapshot_path" "${REMOTE_USER}@${REMOTE_IP}:${REMOTE_DIR}/"
    fi
    log "远程同步完成"
}

cleanup_local() {
    log "清理本地快照，保留最新 $LOCAL_KEEP 个"
    cd "$LOCAL_DIR"
    ls -1t *.tar.gz 2>/dev/null | tail -n +$((LOCAL_KEEP + 1)) | xargs -r rm -f
}

cleanup_remote() {
    log "清理远程超过 $REMOTE_KEEP_DAYS 天的快照"
    ssh_exec "find $REMOTE_DIR -name '*.tar.gz' -mtime +$REMOTE_KEEP_DAYS -delete" 2>/dev/null
    log "远程清理完成"
}

run_backup() {
    load_config || exit 1
    local start_time=$(date +%s)
    local hostname=$(hostname)

    log "========== 开始备份任务 =========="
    local snapshot_path=$(create_snapshot)
    sync_to_remote "$snapshot_path"
    cleanup_local
    cleanup_remote

    local duration=$(($(date +%s) - start_time))
    local size=$(du -h "$snapshot_path" | cut -f1)
    log "========== 备份完成 =========="
    send_telegram "✅ <b>备份完成</b>%0A主机: ${hostname}%0A大小: ${size}%0A耗时: ${duration}秒"
}

setup_cron() {
    echo -e "${YELLOW}设置定时备份任务${NC}"
    echo "1) 每天凌晨 3 点"
    echo "2) 每周日凌晨 3 点"
    echo "3) 每月 1 号凌晨 3 点"
    read -p "请选择 [1]: " choice
    
    case ${choice:-1} in
        2) cron_expr="0 3 * * 0" ;;
        3) cron_expr="0 3 1 * *" ;;
        *) cron_expr="0 3 * * *" ;;
    esac

    local script_path=$(readlink -f "$0")
    (crontab -l 2>/dev/null | grep -v "vps-snapshot"; echo "$cron_expr $script_path run") | crontab -
    log "定时任务已设置: $cron_expr"
}

show_status() {
    print_banner
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        echo -e "${GREEN}配置状态:${NC}"
        echo "  认证方式:   ${AUTH_METHOD}"
        echo "  远程服务器: ${REMOTE_USER}@${REMOTE_IP}:${REMOTE_PORT}"
        echo "  远程目录:   ${REMOTE_DIR}"
        echo "  本地目录:   ${LOCAL_DIR}"
        echo "  本地保留:   ${LOCAL_KEEP} 个"
        echo "  远程保留:   ${REMOTE_KEEP_DAYS} 天"
        echo "  Telegram:   $([ -n "$TG_BOT_TOKEN" ] && echo '已配置' || echo '未配置')"
        echo -e "\n${GREEN}本地快照:${NC}"
        ls -lh "$LOCAL_DIR"/*.tar.gz 2>/dev/null || echo "  (无)"
    else
        echo -e "${RED}未配置，请运行: $0 setup${NC}"
    fi
}

show_help() {
    print_banner
    echo "用法: $0 <命令>"
    echo ""
    echo "命令:"
    echo "  setup     交互式配置"
    echo "  run       执行备份"
    echo "  install   安装依赖"
    echo "  cron      设置定时任务"
    echo "  status    查看配置状态"
    echo "  help      显示帮助"
}

main() {
    [ "$EUID" -ne 0 ] && { error "请使用 root 权限运行"; exit 1; }
    touch "$LOG_FILE"

    case "${1:-help}" in
        setup) install_dependencies; interactive_setup
            echo -e "\n${GREEN}配置完成！${NC}"
            echo "运行 '$0 run' 执行备份"
            echo "运行 '$0 cron' 设置定时任务" ;;
        run) run_backup ;;
        install) install_dependencies ;;
        cron) setup_cron ;;
        status) show_status ;;
        *) show_help ;;
    esac
}

main "$@"
