#!/bin/bash

#===============================================================================
# VPS 快照备份脚本 v2.1
# 支持: Ubuntu, Debian, CentOS, Alpine
# 功能: 创建/恢复快照 + rsync 远程同步 + Telegram 通知 + 自动清理
#===============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

CONFIG_FILE="/etc/vps-snapshot.conf"
LOG_FILE="/var/log/vps-snapshot.log"
SSH_KEY_PATH="/root/.ssh/vps_snapshot_key"

print_banner() {
    echo -e "${BLUE}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║           VPS 快照备份脚本 v2.1                           ║"
    echo "║       支持 Ubuntu/Debian/CentOS/Alpine                    ║"
    echo "║       支持密码/SSH密钥认证                                ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log() { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}" >&2; echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }
error() { echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}" >&2; echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >> "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $1${NC}" >&2; }

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

#-------------------------------------------------------------------------------
# SSH 密钥管理
#-------------------------------------------------------------------------------

generate_ssh_key() {
    log "生成 SSH 密钥对..."
    if [ -f "$SSH_KEY_PATH" ]; then
        warn "密钥已存在: $SSH_KEY_PATH"
        read -p "是否覆盖? [y/N]: " overwrite
        [[ ! "$overwrite" =~ ^[Yy]$ ]] && return 0
    fi
    ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -C "vps-snapshot-${VPS_NAME:-$(hostname)}"
    chmod 600 "$SSH_KEY_PATH"
    log "密钥生成完成"
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

#-------------------------------------------------------------------------------
# 交互式配置
#-------------------------------------------------------------------------------

interactive_setup() {
    print_banner
    echo -e "${YELLOW}开始交互式配置...${NC}\n"

    # VPS 名称
    read -p "请输入 VPS 名称 (用于区分备份): " VPS_NAME
    VPS_NAME=${VPS_NAME:-$(hostname)}

    # 远程服务器信息
    read -p "请输入远程服务器 IP: " REMOTE_IP
    read -p "请输入 SSH 端口 [22]: " REMOTE_PORT
    REMOTE_PORT=${REMOTE_PORT:-22}
    read -p "请输入 SSH 用户名 [root]: " REMOTE_USER
    REMOTE_USER=${REMOTE_USER:-root}

    # 认证方式
    echo -e "\n${YELLOW}选择认证方式:${NC}"
    echo "1) SSH 密钥 (推荐)"
    echo "2) 密码"
    read -p "请选择 [1]: " AUTH_TYPE

    if [ "${AUTH_TYPE:-1}" = "1" ]; then
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
        generate_ssh_key
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
    # 远程目录 - 自动创建以 VPS 名称命名的文件夹
    read -p "请输入远程备份根目录 [/backup]: " REMOTE_BASE
    REMOTE_BASE=${REMOTE_BASE:-/backup}
    REMOTE_DIR="${REMOTE_BASE}/${VPS_NAME}"
    
    read -p "请输入本地快照目录 [/var/snapshots]: " LOCAL_DIR
    LOCAL_DIR=${LOCAL_DIR:-/var/snapshots}
    read -p "本地保留快照数量 [3]: " LOCAL_KEEP
    LOCAL_KEEP=${LOCAL_KEEP:-3}
    read -p "远程保留天数 [30]: " REMOTE_KEEP_DAYS
    REMOTE_KEEP_DAYS=${REMOTE_KEEP_DAYS:-30}

    # Telegram
    read -p "是否启用 Telegram 通知? [y/N]: " ENABLE_TG
    if [[ "$ENABLE_TG" =~ ^[Yy]$ ]]; then
        read -p "请输入 Telegram Bot Token: " TG_BOT_TOKEN
        read -p "请输入 Telegram Chat ID: " TG_CHAT_ID
    fi

    setup_backup_dirs
}

setup_backup_dirs() {
    echo -e "\n${YELLOW}选择要备份的内容:${NC}"
    echo "1) 完整系统 (排除临时文件)"
    echo "2) 仅 /etc /home /root /var/www"
    echo "3) 自定义目录"
    read -p "请选择 [1]: " BACKUP_TYPE

    case ${BACKUP_TYPE:-1} in
        2) BACKUP_DIRS="/etc /home /root /var/www" ;;
        3) read -p "请输入目录 (空格分隔): " BACKUP_DIRS ;;
        *) BACKUP_DIRS="/" ;;
    esac

    save_config
    
    # 创建远程目录
    log "创建远程目录: $REMOTE_DIR"
    ssh_exec "mkdir -p $REMOTE_DIR"
}

save_config() {
    log "保存配置到 $CONFIG_FILE"
    cat > "$CONFIG_FILE" << CONF
VPS_NAME="$VPS_NAME"
AUTH_METHOD="$AUTH_METHOD"
SSH_KEY_PATH="$SSH_KEY_PATH"
REMOTE_IP="$REMOTE_IP"
REMOTE_PORT="$REMOTE_PORT"
REMOTE_USER="$REMOTE_USER"
REMOTE_PASS="$REMOTE_PASS"
REMOTE_BASE="$REMOTE_BASE"
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
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" || { error "未配置，请先运行: $0 setup"; return 1; }
}

#-------------------------------------------------------------------------------
# 快照操作
#-------------------------------------------------------------------------------

create_snapshot() {
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local snapshot_name="${VPS_NAME}_${timestamp}.tar.gz"
    local snapshot_path="${LOCAL_DIR}/${snapshot_name}"

    mkdir -p "$LOCAL_DIR"
    log "开始创建快照: $snapshot_name"
    send_telegram "🔄 <b>开始备份</b>%0AVPS: ${VPS_NAME}"

    local excludes="--exclude=/proc --exclude=/sys --exclude=/dev"
    excludes+=" --exclude=/run --exclude=/tmp --exclude=/mnt"
    excludes+=" --exclude=/media --exclude=/lost+found"
    excludes+=" --exclude=${LOCAL_DIR} --exclude=/var/cache"

    if [ "$BACKUP_DIRS" = "/" ]; then
        tar $excludes -czf "$snapshot_path" / 2>/dev/null || true
    else
        tar -czf "$snapshot_path" $BACKUP_DIRS 2>/dev/null || true
    fi

    log "快照完成: $snapshot_path ($(du -h "$snapshot_path" | cut -f1))"
    echo "$snapshot_path"
}

sync_to_remote() {
    local snapshot_path="$1"
    log "同步到远程: $REMOTE_DIR"
    
    if [ "$AUTH_METHOD" = "key" ]; then
        rsync -avz --progress -e "ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no -p $REMOTE_PORT" \
            "$snapshot_path" "${REMOTE_USER}@${REMOTE_IP}:${REMOTE_DIR}/"
    else
        sshpass -p "$REMOTE_PASS" rsync -avz --progress \
            -e "ssh -o StrictHostKeyChecking=no -p $REMOTE_PORT" \
            "$snapshot_path" "${REMOTE_USER}@${REMOTE_IP}:${REMOTE_DIR}/"
    fi
    log "同步完成"
}

cleanup_local() {
    log "清理本地快照，保留 $LOCAL_KEEP 个"
    cd "$LOCAL_DIR"
    ls -1t *.tar.gz 2>/dev/null | tail -n +$((LOCAL_KEEP + 1)) | xargs -r rm -f
}

cleanup_remote() {
    log "清理远程 $REMOTE_KEEP_DAYS 天前的快照"
    ssh_exec "find $REMOTE_DIR -name '*.tar.gz' -mtime +$REMOTE_KEEP_DAYS -delete" 2>/dev/null
}

run_backup() {
    load_config || exit 1
    local start=$(date +%s)

    log "===== 开始备份 [$VPS_NAME] ====="
    local snapshot=$(create_snapshot)
    sync_to_remote "$snapshot"
    cleanup_local
    cleanup_remote

    local dur=$(($(date +%s) - start))
    local size=$(du -h "$snapshot" | cut -f1)
    log "===== 备份完成 ====="
    send_telegram "✅ <b>备份完成</b>%0AVPS: ${VPS_NAME}%0A大小: ${size}%0A耗时: ${dur}秒"
}

#-------------------------------------------------------------------------------
# 快照列表
#-------------------------------------------------------------------------------

list_local_snapshots() {
    echo -e "\n${CYAN}=== 本地快照 ===${NC}"
    if [ -d "$LOCAL_DIR" ]; then
        ls -lh "$LOCAL_DIR"/*.tar.gz 2>/dev/null | awk '{print NR") "$9" ("$5")"}'
    else
        echo "  (无)"
    fi
}

list_remote_snapshots() {
    echo -e "\n${CYAN}=== 远程快照 [$VPS_NAME] ===${NC}"
    ssh_exec "ls -lh $REMOTE_DIR/*.tar.gz 2>/dev/null" | awk '{print NR") "$9" ("$5")"}'
}

#-------------------------------------------------------------------------------
# 恢复快照
#-------------------------------------------------------------------------------

select_restore_mode() {
    echo -e "\n${YELLOW}选择恢复模式:${NC}"
    echo "1) 覆盖模式 - 只覆盖快照中的文件（安全，保留新增文件）"
    echo "2) 完整恢复 - 删除快照中不存在的文件（危险，恢复到干净状态）"
    read -p "请选择 [1]: " mode
    echo "${mode:-1}"
}

do_restore() {
    local file="$1"
    local mode="$2"
    local temp_dir="/tmp/snapshot_restore_$$"
    
    log "解压快照到临时目录..."
    mkdir -p "$temp_dir"
    tar -xzf "$file" -C "$temp_dir" 2>/dev/null
    
    if [ "$mode" = "2" ]; then
        log "完整恢复模式: 使用 rsync --delete"
        echo -e "${RED}警告: 将删除系统中快照不存在的文件！${NC}"
        echo -e "${RED}排除目录: /proc /sys /dev /run /tmp /mnt /media${NC}"
        read -p "最后确认，输入 YES 继续: " final
        [ "$final" != "YES" ] && { rm -rf "$temp_dir"; return 1; }
        
        # 完整恢复，删除快照中不存在的文件
        rsync -aAXv --delete \
            --exclude='/proc/*' \
            --exclude='/sys/*' \
            --exclude='/dev/*' \
            --exclude='/run/*' \
            --exclude='/tmp/*' \
            --exclude='/mnt/*' \
            --exclude='/media/*' \
            --exclude='/lost+found' \
            --exclude="$LOCAL_DIR/*" \
            --exclude="$temp_dir" \
            "$temp_dir/" /
    else
        log "覆盖模式: 只覆盖已有文件"
        rsync -aAXv "$temp_dir/" /
    fi
    
    rm -rf "$temp_dir"
    log "恢复完成，建议重启系统"
}

restore_local() {
    load_config || exit 1
    list_local_snapshots
    
    echo ""
    read -p "选择要恢复的快照编号: " num
    local file=$(ls -1t "$LOCAL_DIR"/*.tar.gz 2>/dev/null | sed -n "${num}p")
    
    [ -z "$file" ] && { error "无效选择"; return 1; }
    
    local mode=$(select_restore_mode)
    
    echo -e "${RED}警告: 即将恢复快照到系统！${NC}"
    read -p "确认恢复 $file? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return
    
    do_restore "$file" "$mode"
}

restore_from_remote() {
    load_config || exit 1
    list_remote_snapshots
    
    echo ""
    read -p "选择要恢复的快照编号: " num
    local file=$(ssh_exec "ls -1t $REMOTE_DIR/*.tar.gz" | sed -n "${num}p")
    
    [ -z "$file" ] && { error "无效选择"; return 1; }
    
    log "下载远程快照: $file"
    local local_file="$LOCAL_DIR/$(basename $file)"
    mkdir -p "$LOCAL_DIR"
    
    if [ "$AUTH_METHOD" = "key" ]; then
        rsync -avz -e "ssh -i $SSH_KEY_PATH -p $REMOTE_PORT" \
            "${REMOTE_USER}@${REMOTE_IP}:${file}" "$local_file"
    else
        sshpass -p "$REMOTE_PASS" rsync -avz \
            -e "ssh -p $REMOTE_PORT" \
            "${REMOTE_USER}@${REMOTE_IP}:${file}" "$local_file"
    fi
    
    local mode=$(select_restore_mode)
    
    echo -e "${RED}警告: 即将恢复快照！${NC}"
    read -p "确认恢复? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return
    
    do_restore "$local_file" "$mode"
}

restore_custom_remote() {
    load_config || exit 1
    
    read -p "输入远程快照完整路径: " remote_file
    [ -z "$remote_file" ] && { error "路径不能为空"; return 1; }
    
    local local_file="$LOCAL_DIR/$(basename $remote_file)"
    mkdir -p "$LOCAL_DIR"
    
    log "下载: $remote_file"
    if [ "$AUTH_METHOD" = "key" ]; then
        rsync -avz -e "ssh -i $SSH_KEY_PATH -p $REMOTE_PORT" \
            "${REMOTE_USER}@${REMOTE_IP}:${remote_file}" "$local_file"
    else
        sshpass -p "$REMOTE_PASS" rsync -avz \
            -e "ssh -p $REMOTE_PORT" \
            "${REMOTE_USER}@${REMOTE_IP}:${remote_file}" "$local_file"
    fi
    
    local mode=$(select_restore_mode)
    
    echo -e "${RED}警告: 即将恢复!${NC}"
    read -p "确认? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return
    
    do_restore "$local_file" "$mode"
}

#-------------------------------------------------------------------------------
# 配置管理
#-------------------------------------------------------------------------------

edit_config() {
    load_config || exit 1
    
    echo -e "\n${CYAN}=== 当前配置 ===${NC}"
    echo "1) VPS名称: $VPS_NAME"
    echo "2) 远程IP: $REMOTE_IP"
    echo "3) 远程端口: $REMOTE_PORT"
    echo "4) 远程用户: $REMOTE_USER"
    echo "5) 远程目录: $REMOTE_DIR"
    echo "6) 本地目录: $LOCAL_DIR"
    echo "7) 本地保留: $LOCAL_KEEP 个"
    echo "8) 远程保留: $REMOTE_KEEP_DAYS 天"
    echo "9) Telegram: $([ -n "$TG_BOT_TOKEN" ] && echo '已配置' || echo '未配置')"
    echo "0) 返回"
    
    read -p "选择要修改的项: " choice
    case $choice in
        1) read -p "新VPS名称: " VPS_NAME; REMOTE_DIR="${REMOTE_BASE}/${VPS_NAME}" ;;
        2) read -p "新远程IP: " REMOTE_IP ;;
        3) read -p "新端口: " REMOTE_PORT ;;
        4) read -p "新用户: " REMOTE_USER ;;
        5) read -p "新远程目录: " REMOTE_DIR ;;
        6) read -p "新本地目录: " LOCAL_DIR ;;
        7) read -p "本地保留数: " LOCAL_KEEP ;;
        8) read -p "远程保留天数: " REMOTE_KEEP_DAYS ;;
        9) read -p "Bot Token: " TG_BOT_TOKEN; read -p "Chat ID: " TG_CHAT_ID ;;
        0) return ;;
    esac
    save_config
    echo -e "${GREEN}配置已更新${NC}"
}

setup_cron() {
    echo -e "${YELLOW}设置定时备份${NC}"
    echo "1) 每天凌晨 3 点"
    echo "2) 每 3 天凌晨 3 点"
    echo "3) 每周日凌晨 3 点"
    echo "4) 每月 1 号"
    read -p "选择 [1]: " c
    
    case ${c:-1} in
        2) expr="0 3 */3 * *" ;;
        3) expr="0 3 * * 0" ;;
        4) expr="0 3 1 * *" ;;
        *) expr="0 3 * * *" ;;
    esac

    local path=$(readlink -f "$0")
    (crontab -l 2>/dev/null | grep -v "vps-snapshot"; echo "$expr $path run") | crontab -
    log "定时任务: $expr"
}

show_status() {
    print_banner
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        echo -e "${GREEN}VPS: $VPS_NAME${NC}"
        echo "认证: $AUTH_METHOD"
        echo "远程: ${REMOTE_USER}@${REMOTE_IP}:${REMOTE_PORT}"
        echo "远程目录: $REMOTE_DIR"
        echo "本地目录: $LOCAL_DIR"
        echo "保留: 本地${LOCAL_KEEP}个 / 远程${REMOTE_KEEP_DAYS}天"
        echo "TG: $([ -n "$TG_BOT_TOKEN" ] && echo '✓' || echo '✗')"
        list_local_snapshots
    else
        echo -e "${RED}未配置${NC}"
    fi
}

#-------------------------------------------------------------------------------
# 主菜单
#-------------------------------------------------------------------------------

show_menu() {
    load_config 2>/dev/null
    print_banner
    echo -e "${CYAN}VPS: ${VPS_NAME:-未配置}${NC}\n"
    echo "1) 创建快照并同步"
    echo "2) 仅创建本地快照"
    echo "3) 查看本地快照"
    echo "4) 查看远程快照"
    echo "5) 恢复本地快照"
    echo "6) 从远程恢复快照"
    echo "7) 自定义远程恢复"
    echo "8) 修改配置"
    echo "9) 设置定时任务"
    echo "10) 查看状态"
    echo "0) 退出"
    echo ""
    read -p "请选择: " choice
    
    case $choice in
        1) run_backup ;;
        2) load_config && create_snapshot ;;
        3) load_config && list_local_snapshots ;;
        4) load_config && list_remote_snapshots ;;
        5) restore_local ;;
        6) restore_from_remote ;;
        7) restore_custom_remote ;;
        8) edit_config ;;
        9) setup_cron ;;
        10) show_status ;;
        0) exit 0 ;;
        *) echo "无效选择" ;;
    esac
    
    echo ""
    read -p "按回车继续..."
    show_menu
}

show_help() {
    print_banner
    echo "用法: $0 <命令>"
    echo ""
    echo "命令:"
    echo "  setup    交互式配置"
    echo "  run      创建快照并同步"
    echo "  menu     交互式菜单"
    echo "  list     查看快照"
    echo "  restore  恢复快照"
    echo "  config   修改配置"
    echo "  cron     设置定时"
    echo "  status   查看状态"
}

main() {
    [ "$EUID" -ne 0 ] && { error "请用 root 运行"; exit 1; }
    touch "$LOG_FILE"

    case "${1:-menu}" in
        setup) install_dependencies; interactive_setup ;;
        run) run_backup ;;
        menu) show_menu ;;
        list) load_config && list_local_snapshots && list_remote_snapshots ;;
        restore) restore_local ;;
        config) edit_config ;;
        cron) setup_cron ;;
        status) show_status ;;
        *) show_help ;;
    esac
}

main "$@"
