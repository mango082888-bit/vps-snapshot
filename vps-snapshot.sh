#!/bin/bash

#===============================================================================
# VPS 快照备份脚本 v2.3
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
    echo "║           VPS 快照备份脚本 v2.3                           ║"
    echo "║       支持 Ubuntu/Debian/CentOS/Alpine                    ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log() { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}" >&2; echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }
error() { echo -e "${RED}[ERROR] $1${NC}" >&2; echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >> "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARN] $1${NC}" >&2; }

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

#===============================================================================
# SSH 连接
#===============================================================================

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
    log "复制公钥到远程服务器..."
    sshpass -p "$1" ssh-copy-id -i "${SSH_KEY_PATH}.pub" -o StrictHostKeyChecking=no -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_IP}"
    log "公钥复制完成"
}

test_ssh_connection() {
    log "测试 SSH 连接..."
    if ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o BatchMode=yes -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_IP}" "echo ok" &>/dev/null; then
        log "SSH 连接成功"
        return 0
    else
        error "SSH 连接失败"
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

#===============================================================================
# 配置管理
#===============================================================================

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        return 0
    else
        error "未找到配置文件，请先运行: $0 setup"
        return 1
    fi
}

save_config() {
    log "保存配置..."
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

interactive_setup() {
    print_banner
    echo -e "${CYAN}=== 开始配置 ===${NC}\n"

    read -p "VPS 名称 (用于区分备份): " VPS_NAME
    VPS_NAME=${VPS_NAME:-$(hostname)}

    read -p "远程服务器 IP: " REMOTE_IP
    read -p "SSH 端口 [22]: " REMOTE_PORT
    REMOTE_PORT=${REMOTE_PORT:-22}
    read -p "SSH 用户名 [root]: " REMOTE_USER
    REMOTE_USER=${REMOTE_USER:-root}

    echo -e "\n${CYAN}认证方式:${NC}"
    echo "1) SSH 密钥 (推荐)"
    echo "2) 密码"
    read -p "选择 [1]: " auth_choice

    if [ "${auth_choice:-1}" = "1" ]; then
        AUTH_METHOD="key"
        REMOTE_PASS=""
        [ ! -f "$SSH_KEY_PATH" ] && generate_ssh_key
        echo ""
        read -s -p "输入远程密码 (仅用于复制公钥): " temp_pass
        echo ""
        copy_ssh_key_to_remote "$temp_pass"
        test_ssh_connection || exit 1
    else
        AUTH_METHOD="password"
        read -s -p "SSH 密码: " REMOTE_PASS
        echo ""
    fi

    read -p "远程备份根目录 [/backup]: " REMOTE_BASE
    REMOTE_BASE=${REMOTE_BASE:-/backup}
    REMOTE_DIR="${REMOTE_BASE}/${VPS_NAME}"

    read -p "本地快照目录 [/var/snapshots]: " LOCAL_DIR
    LOCAL_DIR=${LOCAL_DIR:-/var/snapshots}
    
    read -p "本地保留快照数 [3]: " LOCAL_KEEP
    LOCAL_KEEP=${LOCAL_KEEP:-3}
    
    read -p "远程保留天数 [30]: " REMOTE_KEEP_DAYS
    REMOTE_KEEP_DAYS=${REMOTE_KEEP_DAYS:-30}

    read -p "启用 Telegram 通知? [y/N]: " enable_tg
    if [[ "$enable_tg" =~ ^[Yy]$ ]]; then
        read -p "Bot Token: " TG_BOT_TOKEN
        read -p "Chat ID: " TG_CHAT_ID
    fi

    echo -e "\n${CYAN}备份内容:${NC}"
    echo "1) 完整系统"
    echo "2) 仅 /etc /home /root /var/www"
    echo "3) 自定义"
    read -p "选择 [1]: " backup_choice

    case ${backup_choice:-1} in
        2) BACKUP_DIRS="/etc /home /root /var/www" ;;
        3) read -p "输入目录 (空格分隔): " BACKUP_DIRS ;;
        *) BACKUP_DIRS="/" ;;
    esac

    save_config

    log "创建远程目录: $REMOTE_DIR"
    ssh_exec "mkdir -p $REMOTE_DIR"

    echo -e "\n${GREEN}配置完成！${NC}"
}

edit_config() {
    load_config || return 1

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

#===============================================================================
# 快照创建
#===============================================================================

create_snapshot() {
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local snapshot_name="${VPS_NAME}_${timestamp}.tar.gz"
    local snapshot_path="${LOCAL_DIR}/${snapshot_name}"

    mkdir -p "$LOCAL_DIR"
    log "创建快照: $snapshot_name"

    local excludes="--exclude=/proc --exclude=/sys --exclude=/dev"
    excludes+=" --exclude=/run --exclude=/tmp --exclude=/mnt"
    excludes+=" --exclude=/media --exclude=/lost+found"
    excludes+=" --exclude=${LOCAL_DIR} --exclude=/var/cache"

    if [ "$BACKUP_DIRS" = "/" ]; then
        tar $excludes -czf "$snapshot_path" / 2>/dev/null || true
    else
        tar -czf "$snapshot_path" $BACKUP_DIRS 2>/dev/null || true
    fi

    local size=$(du -h "$snapshot_path" | cut -f1)
    log "快照完成: $snapshot_path ($size)"
    echo "$snapshot_path"
}

sync_to_remote() {
    local snapshot_path="$1"
    log "同步到远程..."

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
    ssh_exec "find $REMOTE_DIR -name '*.tar.gz' -mtime +$REMOTE_KEEP_DAYS -delete" 2>/dev/null || true
}

run_backup() {
    load_config || exit 1
    local start=$(date +%s)

    log "===== 开始备份 [$VPS_NAME] ====="
    send_telegram "🔄 <b>开始备份</b>%0AVPS: ${VPS_NAME}%0A时间: $(date '+%Y-%m-%d %H:%M:%S')"
    
    local snapshot=$(create_snapshot)
    if [ ! -f "$snapshot" ]; then
        send_telegram "❌ <b>备份失败</b>%0AVPS: ${VPS_NAME}%0A原因: 快照创建失败"
        error "快照创建失败"
        return 1
    fi
    
    local size=$(du -h "$snapshot" | cut -f1)
    local filename=$(basename "$snapshot")
    
    send_telegram "📦 <b>快照完成</b>%0AVPS: ${VPS_NAME}%0A文件: ${filename}%0A大小: ${size}%0A开始同步..."
    
    if ! sync_to_remote "$snapshot"; then
        send_telegram "❌ <b>同步失败</b>%0AVPS: ${VPS_NAME}%0A原因: 远程同步失败"
        error "远程同步失败"
        return 1
    fi
    
    cleanup_local
    cleanup_remote

    local dur=$(($(date +%s) - start))
    local remote_path="${REMOTE_DIR}/${filename}"
    log "===== 备份完成 ====="
    send_telegram "✅ <b>备份完成</b>%0AVPS: ${VPS_NAME}%0A大小: ${size}%0A耗时: ${dur}秒%0A远程: ${REMOTE_IP}:${remote_path}"
}

#===============================================================================
# 快照列表
#===============================================================================

list_local_snapshots() {
    echo -e "\n${CYAN}=== 本地快照 ===${NC}"
    if [ -d "$LOCAL_DIR" ] && ls "$LOCAL_DIR"/*.tar.gz &>/dev/null; then
        ls -1t "$LOCAL_DIR"/*.tar.gz | nl -w2 -s') '
    else
        echo "  (无快照)"
    fi
}

list_remote_snapshots() {
    echo -e "\n${CYAN}=== 远程快照 [$VPS_NAME] ===${NC}"
    local list=$(ssh_exec "ls -1t $REMOTE_DIR/*.tar.gz 2>/dev/null")
    if [ -n "$list" ]; then
        echo "$list" | nl -w2 -s') '
    else
        echo "  (无快照)"
    fi
}

#===============================================================================
# 快照恢复
#===============================================================================

select_restore_mode() {
    echo -e "\n${CYAN}=== 选择恢复模式 ===${NC}" >&2
    echo "1) 覆盖模式 - 只覆盖文件，保留新增文件 (安全)" >&2
    echo "2) 完整恢复 - 删除快照中不存在的文件 (危险!)" >&2
    echo "" >&2
    read -p "请选择恢复模式 [1]: " mode </dev/tty
    echo "${mode:-1}"
}

do_restore() {
    local file="$1"
    local mode="$2"
    local temp_dir="/tmp/snapshot_restore_$$"

    log "解压快照..."
    mkdir -p "$temp_dir"
    tar -xzf "$file" -C "$temp_dir" 2>/dev/null

    if [ "$mode" = "2" ]; then
        echo -e "\n${RED}!!! 完整恢复模式 !!!${NC}"
        echo -e "${RED}将删除系统中快照不存在的文件${NC}"
        echo -e "${YELLOW}排除: /proc /sys /dev /run /tmp /mnt /media${NC}"
        echo ""
        read -p "输入 YES 确认: " confirm
        if [ "$confirm" != "YES" ]; then
            rm -rf "$temp_dir"
            echo "已取消"
            return 1
        fi

        log "完整恢复: rsync --delete"
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
        log "覆盖恢复"
        rsync -aAXv "$temp_dir/" /
    fi

    rm -rf "$temp_dir"
    log "恢复完成，建议重启系统"
}

restore_local() {
    load_config || return 1
    list_local_snapshots

    echo ""
    read -p "选择快照编号: " num
    local file=$(ls -1t "$LOCAL_DIR"/*.tar.gz 2>/dev/null | sed -n "${num}p")
    [ -z "$file" ] && { error "无效选择"; return 1; }

    local mode=$(select_restore_mode)

    echo -e "\n${RED}警告: 即将恢复快照!${NC}"
    read -p "确认? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return

    do_restore "$file" "$mode"
}

restore_from_remote() {
    load_config || return 1
    list_remote_snapshots

    echo ""
    read -p "选择快照编号: " num
    local file=$(ssh_exec "ls -1t $REMOTE_DIR/*.tar.gz" 2>/dev/null | sed -n "${num}p")
    [ -z "$file" ] && { error "无效选择"; return 1; }

    log "下载快照: $file"
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

    echo -e "\n${RED}警告: 即将恢复快照!${NC}"
    read -p "确认? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return

    do_restore "$local_file" "$mode"
}

restore_custom() {
    echo -e "\n${CYAN}=== 自定义远程恢复 ===${NC}"
    echo "从任意服务器拉取快照恢复"
    echo ""
    
    read -p "远程服务器 IP: " custom_ip
    [ -z "$custom_ip" ] && { error "IP 不能为空"; return 1; }
    
    read -p "SSH 端口 [22]: " custom_port
    custom_port=${custom_port:-22}
    
    read -p "SSH 用户名 [root]: " custom_user
    custom_user=${custom_user:-root}
    
    read -s -p "SSH 密码: " custom_pass
    echo ""
    
    read -p "快照完整路径 (如 /backup/vps/xxx.tar.gz): " remote_file
    [ -z "$remote_file" ] && { error "路径不能为空"; return 1; }

    local local_file="/tmp/$(basename $remote_file)"

    log "从 ${custom_user}@${custom_ip} 下载: $remote_file"
    sshpass -p "$custom_pass" rsync -avz --progress \
        -e "ssh -o StrictHostKeyChecking=no -p $custom_port" \
        "${custom_user}@${custom_ip}:${remote_file}" "$local_file"

    [ ! -f "$local_file" ] && { error "下载失败"; return 1; }

    local mode=$(select_restore_mode)

    echo -e "\n${RED}警告: 即将恢复!${NC}"
    read -p "确认? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { rm -f "$local_file"; return; }

    do_restore "$local_file" "$mode"
    rm -f "$local_file"
}

#===============================================================================
# 一键迁移
#===============================================================================

migrate_server() {
    echo -e "\n${CYAN}=== 一键迁移 ===${NC}"
    echo "从源服务器创建快照，直接恢复到当前服务器"
    echo -e "${YELLOW}注意: 会覆盖当前服务器数据!${NC}\n"
    
    # 源服务器信息
    echo -e "${CYAN}--- 源服务器 (A) ---${NC}"
    read -p "源服务器 IP: " src_ip
    [ -z "$src_ip" ] && { error "IP 不能为空"; return 1; }
    
    read -p "SSH 端口 [22]: " src_port
    src_port=${src_port:-22}
    
    read -p "SSH 用户名 [root]: " src_user
    src_user=${src_user:-root}
    
    read -s -p "SSH 密码: " src_pass
    echo ""
    
    # 测试连接
    log "测试源服务器连接..."
    if ! sshpass -p "$src_pass" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p "$src_port" "${src_user}@${src_ip}" "echo ok" &>/dev/null; then
        error "无法连接源服务器"
        return 1
    fi
    log "源服务器连接成功"
    
    # 备份目录选择
    echo -e "\n${CYAN}备份内容:${NC}"
    echo "1) 完整系统"
    echo "2) 仅 /etc /home /root /var/www"
    echo "3) 自定义目录"
    read -p "选择 [1]: " backup_choice
    
    case ${backup_choice:-1} in
        2) backup_dirs="/etc /home /root /var/www" ;;
        3) read -p "输入目录 (空格分隔): " backup_dirs ;;
        *) backup_dirs="/" ;;
    esac
    
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local remote_snapshot="/tmp/migrate_${timestamp}.tar.gz"
    local local_snapshot="/tmp/migrate_${timestamp}.tar.gz"
    
    # 在源服务器创建快照
    log "在源服务器创建快照..."
    echo "正在打包，请稍候..."
    
    local excludes="--exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run --exclude=/tmp --exclude=/mnt --exclude=/media --exclude=/lost+found --exclude=/var/cache"
    
    if [ "$backup_dirs" = "/" ]; then
        sshpass -p "$src_pass" ssh -o StrictHostKeyChecking=no -p "$src_port" "${src_user}@${src_ip}" \
            "tar $excludes -czf $remote_snapshot / 2>/dev/null"
    else
        sshpass -p "$src_pass" ssh -o StrictHostKeyChecking=no -p "$src_port" "${src_user}@${src_ip}" \
            "tar -czf $remote_snapshot $backup_dirs 2>/dev/null"
    fi
    
    # 获取快照大小
    local size=$(sshpass -p "$src_pass" ssh -o StrictHostKeyChecking=no -p "$src_port" "${src_user}@${src_ip}" "du -h $remote_snapshot | cut -f1")
    log "源服务器快照完成: $size"
    
    # 下载快照
    log "下载快照到本地..."
    sshpass -p "$src_pass" rsync -avz --progress \
        -e "ssh -o StrictHostKeyChecking=no -p $src_port" \
        "${src_user}@${src_ip}:${remote_snapshot}" "$local_snapshot"
    
    # 清理源服务器临时文件
    sshpass -p "$src_pass" ssh -o StrictHostKeyChecking=no -p "$src_port" "${src_user}@${src_ip}" "rm -f $remote_snapshot"
    
    [ ! -f "$local_snapshot" ] && { error "下载失败"; return 1; }
    
    # 选择恢复模式
    local mode=$(select_restore_mode)
    
    echo -e "\n${RED}!!! 警告 !!!${NC}"
    echo -e "${RED}即将把源服务器数据恢复到当前服务器${NC}"
    echo -e "源: ${src_user}@${src_ip}"
    echo -e "目标: 当前服务器"
    echo ""
    read -p "输入 确认迁移 继续: " confirm
    
    if [ "$confirm" != "确认迁移" ]; then
        rm -f "$local_snapshot"
        echo "已取消"
        return 1
    fi
    
    do_restore "$local_snapshot" "$mode"
    rm -f "$local_snapshot"
    
    echo -e "\n${GREEN}迁移完成！${NC}"
    echo -e "${YELLOW}建议操作:${NC}"
    echo "1. 重启当前服务器"
    echo "2. 关闭源服务器 (${src_ip}) 避免冲突"
    echo ""
    read -p "是否关闭源服务器? [y/N]: " shutdown_src
    if [[ "$shutdown_src" =~ ^[Yy]$ ]]; then
        log "正在关闭源服务器..."
        sshpass -p "$src_pass" ssh -o StrictHostKeyChecking=no -p "$src_port" "${src_user}@${src_ip}" "shutdown -h now" &>/dev/null || true
        echo -e "${GREEN}源服务器关机命令已发送${NC}"
    fi
    
    log "迁移完成！建议重启服务器"
}

#===============================================================================
# 定时任务
#===============================================================================

setup_cron() {
    echo -e "${CYAN}=== 定时备份 ===${NC}"
    echo "1) 每天凌晨 3 点"
    echo "2) 每 3 天凌晨 3 点"
    echo "3) 每周日凌晨 3 点"
    echo "4) 每月 1 号"
    read -p "选择 [1]: " choice

    case ${choice:-1} in
        2) expr="0 3 */3 * *" ;;
        3) expr="0 3 * * 0" ;;
        4) expr="0 3 1 * *" ;;
        *) expr="0 3 * * *" ;;
    esac

    local script_path=$(readlink -f "$0")
    (crontab -l 2>/dev/null | grep -v "vps-snapshot"; echo "$expr $script_path run") | crontab -
    log "定时任务已设置: $expr"
}

#===============================================================================
# 状态显示
#===============================================================================

show_status() {
    print_banner
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        echo -e "${GREEN}VPS: $VPS_NAME${NC}"
        echo "认证方式: $AUTH_METHOD"
        echo "远程服务器: ${REMOTE_USER}@${REMOTE_IP}:${REMOTE_PORT}"
        echo "远程目录: $REMOTE_DIR"
        echo "本地目录: $LOCAL_DIR"
        echo "保留策略: 本地 ${LOCAL_KEEP} 个 / 远程 ${REMOTE_KEEP_DAYS} 天"
        echo "Telegram: $([ -n "$TG_BOT_TOKEN" ] && echo '已配置' || echo '未配置')"
        list_local_snapshots
    else
        echo -e "${RED}未配置，请运行: $0 setup${NC}"
    fi
}

#===============================================================================
# 主菜单
#===============================================================================

show_menu() {
    load_config 2>/dev/null
    print_banner
    echo -e "${GREEN}VPS: ${VPS_NAME:-未配置}${NC}\n"

    echo "1) 首次配置 / 重新配置"
    echo "2) 创建快照并同步"
    echo "3) 仅创建本地快照"
    echo "4) 查看本地快照"
    echo "5) 查看远程快照"
    echo "6) 恢复本地快照"
    echo "7) 从远程恢复快照"
    echo "8) 自定义远程恢复"
    echo "9) 一键迁移 (A→B)"
    echo "10) 修改配置"
    echo "11) 设置定时任务"
    echo "12) 查看状态"
    echo "0) 退出"
    echo ""
    read -p "请选择: " choice

    case $choice in
        1) install_dependencies; interactive_setup ;;
        2) run_backup ;;
        3) load_config && create_snapshot ;;
        4) load_config && list_local_snapshots ;;
        5) load_config && list_remote_snapshots ;;
        6) restore_local ;;
        7) restore_from_remote ;;
        8) restore_custom ;;
        9) migrate_server ;;
        10) edit_config ;;
        11) setup_cron ;;
        12) show_status ;;
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
    echo "  setup    初始配置"
    echo "  run      创建快照并同步"
    echo "  menu     交互式菜单"
    echo "  list     查看快照"
    echo "  restore  恢复本地快照"
    echo "  config   修改配置"
    echo "  cron     设置定时任务"
    echo "  status   查看状态"
}

#===============================================================================
# 入口
#===============================================================================

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
