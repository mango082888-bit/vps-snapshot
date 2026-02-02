#!/bin/bash

#===============================================================================
# VPS 快照备份脚本 v3.6
# 支持: Ubuntu, Debian, CentOS, Alpine
# 功能: 智能识别应用 + Docker迁移 + 数据备份 + Telegram通知
#===============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

CONFIG_FILE="/etc/vps-snapshot.conf"
LOG_FILE="/var/log/vps-snapshot.log"

print_banner() {
    echo -e "${BLUE}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║           VPS 快照备份脚本 v3.6                           ║"
    echo "║       智能识别 + Docker迁移 + 数据备份                    ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log() { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >> "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
info() { echo -e "${CYAN}[INFO] $1${NC}"; }

#===============================================================================
# 系统检测
#===============================================================================

detect_os() {
    if [ -f /etc/os-release ]; then . /etc/os-release; echo "$ID"
    elif [ -f /etc/redhat-release ]; then echo "centos"
    else echo "unknown"; fi
}

install_deps() {
    local os=$(detect_os)
    log "检测系统: $os"
    case $os in
        ubuntu|debian) apt-get update -qq && apt-get install -y -qq rsync sshpass curl tar gzip jq ;;
        centos|rhel|fedora) yum install -y -q rsync sshpass curl tar gzip jq ;;
        alpine) apk add --no-cache rsync sshpass curl tar gzip jq ;;
        *) error "不支持的系统: $os"; exit 1 ;;
    esac
}

check_deps() {
    local missing=""
    command -v rsync &>/dev/null || missing+=" rsync"
    command -v sshpass &>/dev/null || missing+=" sshpass"
    command -v jq &>/dev/null || missing+=" jq"
    
    if [ -n "$missing" ]; then
        warn "缺少依赖:$missing，正在安装..."
        install_deps
    fi
}

#===============================================================================
# 智能识别应用
#===============================================================================

detect_apps() {
    info "🔍 扫描已安装的应用..."
    echo ""
    
    local apps=()
    
    # Docker
    if command -v docker &>/dev/null && docker info &>/dev/null; then
        local containers=$(docker ps -q | wc -l)
        local images=$(docker images -q | wc -l)
        echo -e "  ${GREEN}✓${NC} Docker: $containers 个运行中容器, $images 个镜像"
        apps+=("docker")
    fi
    
    # Docker Compose
    if command -v docker-compose &>/dev/null || docker compose version &>/dev/null 2>&1; then
        local compose_files=$(find /opt /root /home -name "docker-compose*.yml" -o -name "compose*.yml" 2>/dev/null | wc -l)
        echo -e "  ${GREEN}✓${NC} Docker Compose: $compose_files 个配置文件"
        apps+=("compose")
    fi
    
    # Nginx
    if command -v nginx &>/dev/null || [ -d /etc/nginx ]; then
        echo -e "  ${GREEN}✓${NC} Nginx"
        apps+=("nginx")
    fi
    
    # MySQL/MariaDB
    if command -v mysql &>/dev/null || [ -d /var/lib/mysql ]; then
        echo -e "  ${GREEN}✓${NC} MySQL/MariaDB"
        apps+=("mysql")
    fi
    
    # PostgreSQL
    if command -v psql &>/dev/null || [ -d /var/lib/postgresql ]; then
        echo -e "  ${GREEN}✓${NC} PostgreSQL"
        apps+=("postgresql")
    fi
    
    # Redis
    if command -v redis-cli &>/dev/null || [ -d /var/lib/redis ]; then
        echo -e "  ${GREEN}✓${NC} Redis"
        apps+=("redis")
    fi
    
    # MongoDB
    if command -v mongod &>/dev/null || [ -d /var/lib/mongodb ]; then
        echo -e "  ${GREEN}✓${NC} MongoDB"
        apps+=("mongodb")
    fi
    
    # Node.js/NPM
    if command -v node &>/dev/null; then
        local node_ver=$(node -v 2>/dev/null || echo "unknown")
        local npm_global=$(npm list -g --depth=0 2>/dev/null | wc -l)
        echo -e "  ${GREEN}✓${NC} Node.js $node_ver ($npm_global 个全局包)"
        apps+=("nodejs")
    fi
    
    # PM2
    if command -v pm2 &>/dev/null; then
        local pm2_apps=$(pm2 jlist 2>/dev/null | jq length 2>/dev/null || echo "0")
        echo -e "  ${GREEN}✓${NC} PM2: $pm2_apps 个应用"
        apps+=("pm2")
    fi
    
    # Python/Pip
    if command -v python3 &>/dev/null; then
        local py_ver=$(python3 --version 2>/dev/null | cut -d' ' -f2)
        echo -e "  ${GREEN}✓${NC} Python $py_ver"
        apps+=("python")
    fi
    
    # PHP
    if command -v php &>/dev/null; then
        local php_ver=$(php -v 2>/dev/null | head -1 | cut -d' ' -f2)
        echo -e "  ${GREEN}✓${NC} PHP $php_ver"
        apps+=("php")
    fi
    
    # 1Panel
    if [ -d /opt/1panel ] || command -v 1pctl &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} 1Panel"
        apps+=("1panel")
    fi
    
    # 宝塔
    if [ -d /www/server/panel ]; then
        echo -e "  ${GREEN}✓${NC} 宝塔面板"
        apps+=("bt")
    fi
    
    echo ""
    echo "${apps[@]}"
}

#===============================================================================
# Docker 专用迁移
#===============================================================================

docker_export() {
    local output_dir="${1:-/var/snapshots}"
    mkdir -p "$output_dir"
    
    log "📦 导出 Docker 数据..."
    
    # 导出所有镜像
    local images=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep -v "<none>")
    if [ -n "$images" ]; then
        log "导出镜像..."
        docker save $images | gzip > "$output_dir/docker-images.tar.gz"
        info "镜像已保存: docker-images.tar.gz"
    fi
    
    # 导出容器配置
    log "导出容器配置..."
    docker ps -a --format '{{json .}}' > "$output_dir/docker-containers.json"
    
    # 导出 volumes
    local volumes=$(docker volume ls -q)
    if [ -n "$volumes" ]; then
        log "导出 Volumes..."
        mkdir -p "$output_dir/volumes"
        for vol in $volumes; do
            docker run --rm -v "$vol:/data" -v "$output_dir/volumes:/backup" \
                alpine tar czf "/backup/${vol}.tar.gz" -C /data . 2>/dev/null || true
        done
        info "Volumes 已保存"
    fi
    
    # 导出 docker-compose 文件
    log "查找 docker-compose 文件..."
    find /opt /root /home -name "docker-compose*.yml" -o -name "compose*.yml" 2>/dev/null | while read f; do
        local dir=$(dirname "$f")
        local name=$(echo "$dir" | tr '/' '_')
        mkdir -p "$output_dir/compose"
        cp -r "$dir" "$output_dir/compose/$name" 2>/dev/null || true
    done
    
    log "Docker 数据导出完成"
}

docker_import() {
    local input_dir="${1:-/var/snapshots}"
    
    log "📥 导入 Docker 数据..."
    
    # 检查 Docker 是否安装
    if ! command -v docker &>/dev/null; then
        warn "Docker 未安装，正在安装..."
        curl -fsSL https://get.docker.com | sh
        systemctl start docker
        systemctl enable docker
    fi
    
    # 导入镜像
    if [ -f "$input_dir/docker-images.tar.gz" ]; then
        log "导入镜像..."
        gunzip -c "$input_dir/docker-images.tar.gz" | docker load
        info "镜像导入完成"
    fi
    
    # 恢复 volumes
    if [ -d "$input_dir/volumes" ]; then
        log "恢复 Volumes..."
        for vol_file in "$input_dir/volumes"/*.tar.gz; do
            [ -f "$vol_file" ] || continue
            local vol_name=$(basename "$vol_file" .tar.gz)
            docker volume create "$vol_name" 2>/dev/null || true
            docker run --rm -v "$vol_name:/data" -v "$input_dir/volumes:/backup" \
                alpine tar xzf "/backup/${vol_name}.tar.gz" -C /data 2>/dev/null || true
        done
        info "Volumes 恢复完成"
    fi
    
    # 恢复 compose 项目
    if [ -d "$input_dir/compose" ]; then
        log "恢复 Compose 项目..."
        for proj in "$input_dir/compose"/*; do
            [ -d "$proj" ] || continue
            local name=$(basename "$proj")
            local target="/opt/${name//_//}"
            mkdir -p "$(dirname "$target")"
            cp -r "$proj" "$target" 2>/dev/null || true
        done
        info "Compose 项目已恢复到 /opt"
    fi
    
    log "Docker 数据导入完成"
}

#===============================================================================
# 应用数据备份
#===============================================================================

backup_app_data() {
    local output_dir="${1:-/var/snapshots}"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_file="$output_dir/app-data_${timestamp}.tar.gz"
    
    mkdir -p "$output_dir"
    log "📦 备份应用数据..."
    
    local backup_paths=""
    
    # Nginx
    [ -d /etc/nginx ] && backup_paths+=" /etc/nginx"
    [ -d /var/www ] && backup_paths+=" /var/www"
    
    # MySQL
    if [ -d /var/lib/mysql ]; then
        log "导出 MySQL 数据库..."
        mkdir -p "$output_dir/mysql"
        if command -v mysqldump &>/dev/null; then
            mysqldump --all-databases > "$output_dir/mysql/all-databases.sql" 2>/dev/null || true
        fi
    fi
    
    # PostgreSQL
    if [ -d /var/lib/postgresql ]; then
        log "导出 PostgreSQL 数据库..."
        mkdir -p "$output_dir/postgresql"
        if command -v pg_dumpall &>/dev/null; then
            sudo -u postgres pg_dumpall > "$output_dir/postgresql/all-databases.sql" 2>/dev/null || true
        fi
    fi
    
    # Redis
    [ -d /var/lib/redis ] && backup_paths+=" /var/lib/redis"
    
    # MongoDB
    if [ -d /var/lib/mongodb ]; then
        log "导出 MongoDB..."
        mkdir -p "$output_dir/mongodb"
        if command -v mongodump &>/dev/null; then
            mongodump --out "$output_dir/mongodb" 2>/dev/null || true
        fi
    fi
    
    # Node.js/NPM 全局包
    if command -v npm &>/dev/null; then
        log "导出 NPM 全局包列表..."
        npm list -g --depth=0 --json > "$output_dir/npm-global.json" 2>/dev/null || true
    fi
    
    # PM2 应用
    if command -v pm2 &>/dev/null; then
        log "导出 PM2 配置..."
        pm2 save 2>/dev/null || true
        [ -f ~/.pm2/dump.pm2 ] && cp ~/.pm2/dump.pm2 "$output_dir/pm2-dump.json"
    fi
    
    # Python pip
    if command -v pip3 &>/dev/null; then
        log "导出 pip 包列表..."
        pip3 freeze > "$output_dir/pip-requirements.txt" 2>/dev/null || true
    fi
    
    # 1Panel
    [ -d /opt/1panel ] && backup_paths+=" /opt/1panel"
    
    # 宝塔
    [ -d /www ] && backup_paths+=" /www"
    
    # 通用数据目录
    [ -d /opt ] && backup_paths+=" /opt"
    [ -d /home ] && backup_paths+=" /home"
    [ -d /root/.config ] && backup_paths+=" /root/.config"
    
    # 打包（排除快照目录）
    local snap_dir="${LOCAL_DIR:-/var/snapshots}"
    if [ -n "$backup_paths" ]; then
        log "打包数据目录..."
        tar --exclude='*.sock' --exclude='*.pid' --exclude='node_modules' \
            --exclude='.npm' --exclude='.cache' --exclude='__pycache__' \
            --exclude="$snap_dir" --exclude='/var/snapshots' \
            -czf "$backup_file" $backup_paths 2>/dev/null || true
        info "数据已保存: $backup_file"
    fi
    
    echo "$backup_file"
}

#===============================================================================
# 一键迁移
#===============================================================================

do_migrate() {
    print_banner
    info "🚀 一键迁移向导"
    echo ""
    
    # 检测应用
    local apps_output=$(detect_apps)
    local apps=$(echo "$apps_output" | tail -1)
    
    echo ""
    read -p "输入目标服务器 IP: " target_ip
    read -p "输入目标服务器端口 [22]: " target_port
    target_port=${target_port:-22}
    read -p "输入目标服务器用户 [root]: " target_user
    target_user=${target_user:-root}
    read -s -p "输入目标服务器密码: " target_pass
    echo ""
    
    # 测试连接
    log "测试连接..."
    if ! sshpass -p "$target_pass" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p "$target_port" "$target_user@$target_ip" "echo ok" &>/dev/null; then
        error "无法连接到目标服务器"
        return 1
    fi
    info "连接成功"
    
    local tmp_dir="/tmp/migrate_$$"
    mkdir -p "$tmp_dir"
    
    # Docker 迁移
    if [[ " $apps " =~ " docker " ]]; then
        log "检测到 Docker，开始导出..."
        docker_export "$tmp_dir"
    fi
    
    # 应用数据备份
    log "备份应用数据..."
    backup_app_data "$tmp_dir"
    
    # 打包所有数据
    log "打包迁移数据..."
    local migrate_file="/tmp/migrate_data.tar.gz"
    tar -czf "$migrate_file" -C "$tmp_dir" . 2>/dev/null
    local size=$(du -h "$migrate_file" | cut -f1)
    info "迁移包大小: $size"
    
    # 传输到目标服务器
    log "传输到目标服务器..."
    sshpass -p "$target_pass" rsync -avz --progress \
        -e "ssh -o StrictHostKeyChecking=no -p $target_port" \
        "$migrate_file" "$target_user@$target_ip:/tmp/"
    
    # 在目标服务器上恢复
    log "在目标服务器上恢复..."
    sshpass -p "$target_pass" ssh -o StrictHostKeyChecking=no \
        -p "$target_port" "$target_user@$target_ip" bash << 'REMOTE_SCRIPT'
set -e
cd /tmp
mkdir -p /tmp/restore_data
tar -xzf migrate_data.tar.gz -C /tmp/restore_data

# 安装 Docker
if [ -f /tmp/restore_data/docker-images.tar.gz ]; then
    if ! command -v docker &>/dev/null; then
        echo "安装 Docker..."
        curl -fsSL https://get.docker.com | sh
        systemctl start docker
        systemctl enable docker
    fi
    echo "导入 Docker 镜像..."
    gunzip -c /tmp/restore_data/docker-images.tar.gz | docker load
fi

# 恢复 volumes
if [ -d /tmp/restore_data/volumes ]; then
    echo "恢复 Docker Volumes..."
    for vol_file in /tmp/restore_data/volumes/*.tar.gz; do
        [ -f "$vol_file" ] || continue
        vol_name=$(basename "$vol_file" .tar.gz)
        docker volume create "$vol_name" 2>/dev/null || true
        docker run --rm -v "$vol_name:/data" -v "/tmp/restore_data/volumes:/backup" \
            alpine tar xzf "/backup/${vol_name}.tar.gz" -C /data 2>/dev/null || true
    done
fi

# 恢复应用数据
if ls /tmp/restore_data/app-data_*.tar.gz &>/dev/null; then
    echo "恢复应用数据..."
    tar -xzf /tmp/restore_data/app-data_*.tar.gz -C / 2>/dev/null || true
fi

# 恢复 NPM 全局包
if [ -f /tmp/restore_data/npm-global.json ] && command -v npm &>/dev/null; then
    echo "恢复 NPM 全局包..."
    cat /tmp/restore_data/npm-global.json | jq -r '.dependencies | keys[]' | \
        xargs -I {} npm install -g {} 2>/dev/null || true
fi

# 恢复 pip 包
if [ -f /tmp/restore_data/pip-requirements.txt ] && command -v pip3 &>/dev/null; then
    echo "恢复 pip 包..."
    pip3 install -r /tmp/restore_data/pip-requirements.txt 2>/dev/null || true
fi

# 清理
rm -rf /tmp/restore_data /tmp/migrate_data.tar.gz

echo "✅ 迁移完成"
REMOTE_SCRIPT

    # 清理本地临时文件
    rm -rf "$tmp_dir" "$migrate_file"
    
    log "🎉 迁移完成！"
    echo ""
    info "请登录目标服务器检查服务状态"
    
    read -p "是否关闭当前服务器? (输入 '确认关闭' 执行): " confirm
    if [ "$confirm" = "确认关闭" ]; then
        warn "服务器将在 10 秒后关机..."
        sleep 10
        shutdown -h now
    fi
}

#===============================================================================
# 快照备份
#===============================================================================

create_snapshot() {
    local output_dir="${1:-/var/snapshots}"
    local name="${2:-snapshot}"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local snapshot_file="$output_dir/${name}_${timestamp}.tar.gz"
    
    mkdir -p "$output_dir"
    log "📸 创建快照..."
    
    # TG通知 - 开始
    send_tg "🔄 *开始创建系统快照*
🖥️ 本机: ${VPS_NAME:-$(hostname)}
⏰ 时间: $(date '+%Y-%m-%d %H:%M:%S')"
    
    # 检测应用并备份
    detect_apps > /dev/null
    
    # Docker 数据
    if command -v docker &>/dev/null && docker info &>/dev/null; then
        docker_export "$output_dir/docker_$timestamp"
    fi
    
    # 应用数据
    backup_app_data "$output_dir"
    
    # 打包
    tar -czf "$snapshot_file" -C "$output_dir" . --exclude="*.tar.gz" 2>/dev/null || true
    
    # 清理临时文件
    rm -rf "$output_dir/docker_$timestamp" "$output_dir/mysql" "$output_dir/postgresql" "$output_dir/mongodb"
    
    local size=$(du -h "$snapshot_file" | cut -f1)
    log "快照已创建: $snapshot_file ($size)"
    
    # TG通知 - 快照完成
    send_tg "📸 *系统快照创建成功*
🖥️ 本机: ${VPS_NAME:-$(hostname)}
📦 文件: $(basename $snapshot_file)
📏 大小: $size
🕒 时间: $(date '+%Y-%m-%d %H:%M:%S')"
    
    # 清理本地旧快照
    cleanup_local
    
    echo "$snapshot_file"
}

#===============================================================================
# 清理旧快照
#===============================================================================

cleanup_local() {
    local snap_dir="${LOCAL_DIR:-/var/snapshots}"
    local keep=${LOCAL_KEEP:-3}
    local vps_name="${VPS_NAME:-snapshot}"
    
    # 删除临时的app-data文件
    rm -f "$snap_dir"/app-data_*.tar.gz 2>/dev/null
    
    # 只统计VPS名称开头的快照
    local count=$(ls -1 "$snap_dir"/${vps_name}_*.tar.gz 2>/dev/null | wc -l)
    if [ "$count" -gt "$keep" ]; then
        log "🧹 清理本地旧快照 (保留$keep个)..."
        ls -t "$snap_dir"/${vps_name}_*.tar.gz | tail -n +$((keep+1)) | xargs rm -f
    fi
}

cleanup_remote() {
    [ -z "$REMOTE_IP" ] && return
    local days=${REMOTE_KEEP_DAYS:-30}
    local remote_path="${REMOTE_DIR:-/backup}/${VPS_NAME:-$(hostname)}"
    
    log "🧹 清理远程旧快照 (保留${days}天)..."
    sshpass -p "$REMOTE_PASS" ssh -o StrictHostKeyChecking=no \
        -p "${REMOTE_PORT:-22}" "${REMOTE_USER:-root}@$REMOTE_IP" \
        "find $remote_path -name '*.tar.gz' -mtime +$days -delete 2>/dev/null" || true
}

#===============================================================================
# 本地恢复
#===============================================================================

do_restore_local() {
    load_config 2>/dev/null || true
    local snap_dir="${LOCAL_DIR:-/var/snapshots}"
    
    echo ""
    info "📂 本地快照列表:"
    ls -lh "$snap_dir"/*.tar.gz 2>/dev/null || { error "无快照"; return 1; }
    echo ""
    read -p "输入快照文件名: " snap_file
    
    [ ! -f "$snap_dir/$snap_file" ] && { error "文件不存在"; return 1; }
    
    log "🔄 恢复快照: $snap_file"
    
    # 解压到临时目录
    local tmp_dir="/tmp/restore_$$"
    mkdir -p "$tmp_dir"
    tar -xzf "$snap_dir/$snap_file" -C "$tmp_dir"
    
    # 导入Docker
    if [ -f "$tmp_dir/docker-images.tar.gz" ]; then
        log "导入 Docker 镜像..."
        gunzip -c "$tmp_dir/docker-images.tar.gz" | docker load
    fi
    
    # 恢复应用数据
    if ls "$tmp_dir"/app-data_*.tar.gz &>/dev/null; then
        log "恢复应用数据..."
        tar -xzf "$tmp_dir"/app-data_*.tar.gz -C / 2>/dev/null || true
    fi
    
    rm -rf "$tmp_dir"
    log "✅ 恢复完成"
}

#===============================================================================
# 从配置的远程恢复
#===============================================================================

do_restore_config_remote() {
    load_config 2>/dev/null || true
    
    if [ -z "$REMOTE_IP" ]; then
        error "未配置远程服务器，请先运行配置"
        return 1
    fi
    
    local remote_path="${REMOTE_DIR:-/backup}/${VPS_NAME:-$(hostname)}"
    
    info "📡 从配置的远程服务器恢复: $REMOTE_IP:$remote_path"
    echo ""
    
    # 获取远程快照列表
    local snap_list=$(sshpass -p "$REMOTE_PASS" ssh -o StrictHostKeyChecking=no \
        -p "${REMOTE_PORT:-22}" "${REMOTE_USER:-root}@$REMOTE_IP" \
        "ls -t $remote_path/*.tar.gz 2>/dev/null")
    
    [ -z "$snap_list" ] && { error "无远程快照"; return 1; }
    
    # 显示编号列表
    info "远程快照列表:"
    local i=1
    local snaps=()
    while read -r snap; do
        local name=$(basename "$snap")
        local size=$(sshpass -p "$REMOTE_PASS" ssh -o StrictHostKeyChecking=no \
            -p "${REMOTE_PORT:-22}" "${REMOTE_USER:-root}@$REMOTE_IP" \
            "ls -lh '$snap' 2>/dev/null | awk '{print \$5}'" 2>/dev/null)
        echo "  $i) $name ($size)"
        snaps+=("$snap")
        ((i++))
    done <<< "$snap_list"
    
    echo ""
    read -p "请选择 [1-$((i-1))]: " choice
    
    # 验证选择
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt $((i-1)) ]; then
        error "无效选择"
        return 1
    fi
    
    local selected="${snaps[$((choice-1))]}"
    
    log "下载快照: $(basename "$selected")"
    local local_file="/tmp/remote_snapshot_$$.tar.gz"
    sshpass -p "$REMOTE_PASS" scp -o StrictHostKeyChecking=no \
        -P "${REMOTE_PORT:-22}" "${REMOTE_USER:-root}@$REMOTE_IP:$selected" "$local_file"
    
    [ ! -f "$local_file" ] && { error "下载失败"; return 1; }
    
    log "🔄 恢复快照..."
    local tmp_dir="/tmp/restore_$$"
    mkdir -p "$tmp_dir"
    tar -xzf "$local_file" -C "$tmp_dir"
    
    # 导入Docker
    if [ -f "$tmp_dir/docker-images.tar.gz" ]; then
        log "导入 Docker 镜像..."
        gunzip -c "$tmp_dir/docker-images.tar.gz" | docker load
    fi
    
    # 恢复应用数据
    if ls "$tmp_dir"/app-data_*.tar.gz &>/dev/null; then
        log "恢复应用数据..."
        tar -xzf "$tmp_dir"/app-data_*.tar.gz -C / 2>/dev/null || true
    fi
    
    rm -rf "$tmp_dir" "$local_file"
    log "✅ 恢复完成"
}

#===============================================================================
# 远程恢复
#===============================================================================

do_restore_remote() {
    echo ""
    info "📡 从远程服务器拉取快照"
    read -p "远程服务器 IP: " remote_ip
    read -p "远程端口 [22]: " remote_port
    remote_port=${remote_port:-22}
    read -p "远程用户 [root]: " remote_user
    remote_user=${remote_user:-root}
    read -s -p "远程密码: " remote_pass
    echo ""
    read -p "远程快照路径 (如 /var/snapshots/xxx.tar.gz): " remote_path
    
    [ -z "$remote_ip" ] || [ -z "$remote_path" ] && { error "参数不完整"; return 1; }
    
    log "下载快照..."
    local local_file="/tmp/remote_snapshot_$$.tar.gz"
    sshpass -p "$remote_pass" scp -o StrictHostKeyChecking=no \
        -P "$remote_port" "$remote_user@$remote_ip:$remote_path" "$local_file"
    
    [ ! -f "$local_file" ] && { error "下载失败"; return 1; }
    
    log "🔄 恢复快照..."
    local tmp_dir="/tmp/restore_$$"
    mkdir -p "$tmp_dir"
    tar -xzf "$local_file" -C "$tmp_dir"
    
    # 导入Docker
    if [ -f "$tmp_dir/docker-images.tar.gz" ]; then
        log "导入 Docker 镜像..."
        gunzip -c "$tmp_dir/docker-images.tar.gz" | docker load
    fi
    
    # 恢复应用数据
    if ls "$tmp_dir"/app-data_*.tar.gz &>/dev/null; then
        log "恢复应用数据..."
        tar -xzf "$tmp_dir"/app-data_*.tar.gz -C / 2>/dev/null || true
    fi
    
    rm -rf "$tmp_dir" "$local_file"
    log "✅ 恢复完成"
}

#===============================================================================
# 同步到远程
#===============================================================================

do_sync_remote() {
    load_config 2>/dev/null || true
    
    if [ -z "$REMOTE_IP" ]; then
        error "未配置远程服务器，请先运行配置"
        return 1
    fi
    
    local snap_dir="${LOCAL_DIR:-/var/snapshots}"
    local latest=$(ls -t "$snap_dir"/*.tar.gz 2>/dev/null | head -1)
    
    [ -z "$latest" ] && { error "无本地快照"; return 1; }
    
    # 远程目录：基础目录/VPS名称
    local remote_base="${REMOTE_DIR:-/backup}"
    local remote_path="${remote_base}/${VPS_NAME:-$(hostname)}"
    
    log "📤 同步到远程: $REMOTE_IP:$remote_path"
    
    # 创建远程目录（以VPS名称命名）
    sshpass -p "$REMOTE_PASS" ssh -o StrictHostKeyChecking=no \
        -p "${REMOTE_PORT:-22}" "${REMOTE_USER:-root}@$REMOTE_IP" \
        "mkdir -p $remote_path"
    
    # 同步到VPS专属目录
    sshpass -p "$REMOTE_PASS" rsync -avz --progress \
        -e "ssh -o StrictHostKeyChecking=no -p ${REMOTE_PORT:-22}" \
        "$latest" "${REMOTE_USER:-root}@$REMOTE_IP:$remote_path/"
    
    # 清理远程旧快照
    cleanup_remote
    
    log "✅ 同步完成"
    
    # TG通知 - 上传成功
    send_tg "☁️ *快照上传成功*
🖥️ 本机: ${VPS_NAME:-$(hostname)}
📁 远程: $REMOTE_IP:$remote_path
🕒 时间: $(date '+%Y-%m-%d %H:%M:%S')"
}

#===============================================================================
# Telegram 通知
#===============================================================================

send_tg() {
    [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ] && return
    local msg="$1"
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d chat_id="$TG_CHAT_ID" -d text="$msg" -d parse_mode="Markdown" > /dev/null
}

#===============================================================================
# 定时快照
#===============================================================================

setup_cron() {
    local script_path=$(readlink -f "$0")
    
    echo ""
    info "⏰ 设置定时快照"
    echo ""
    echo "  1) 每天一次"
    echo "  2) 每12小时"
    echo "  3) 每6小时"
    echo "  4) 每小时"
    echo "  5) 自定义cron表达式"
    echo "  6) 查看当前定时任务"
    echo "  7) 删除定时任务"
    echo "  0) 返回"
    echo ""
    read -p "请选择: " cron_choice
    
    local cron_expr=""
    case $cron_choice in
        1) cron_expr="0 2 * * *" ;;
        2) cron_expr="0 */12 * * *" ;;
        3) cron_expr="0 */6 * * *" ;;
        4) cron_expr="0 * * * *" ;;
        5) read -p "输入cron表达式: " cron_expr ;;
        6) 
            echo ""
            crontab -l 2>/dev/null | grep -E "vps-snapshot|快照" || echo "无定时任务"
            return
            ;;
        7)
            crontab -l 2>/dev/null | grep -v "vps-snapshot" | crontab -
            log "定时任务已删除"
            return
            ;;
        0) return ;;
        *) error "无效选项"; return ;;
    esac
    
    [ -z "$cron_expr" ] && return
    
    # 选择快照类型
    echo ""
    echo "  1) 仅本地快照"
    echo "  2) 快照并同步远程"
    read -p "请选择: " snap_type
    
    local cmd=""
    case $snap_type in
        1) cmd="$script_path snapshot" ;;
        2) cmd="$script_path snapshot-sync" ;;
        *) error "无效选项"; return ;;
    esac
    
    # 添加到crontab
    (crontab -l 2>/dev/null | grep -v "vps-snapshot"; echo "$cron_expr $cmd # vps-snapshot") | crontab -
    
    log "✅ 定时任务已设置: $cron_expr"
    send_tg "⏰ *${VPS_NAME}* 定时快照已设置\n$cron_expr"
}

#===============================================================================
# 更新脚本
#===============================================================================

update_script() {
    local script_path=$(readlink -f "$0")
    local url="https://raw.githubusercontent.com/mango082888-bit/vps-snapshot/main/vps-snapshot.sh"
    
    log "🔄 检查更新..."
    
    curl -sL "$url" -o "${script_path}.new"
    
    if [ -f "${script_path}.new" ]; then
        mv "${script_path}.new" "$script_path"
        chmod +x "$script_path"
        log "✅ 更新完成，请重新运行脚本"
        exit 0
    else
        error "更新失败"
    fi
}

#===============================================================================
# 配置管理
#===============================================================================

load_config() {
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
}

save_config() {
    cat > "$CONFIG_FILE" << EOF
VPS_NAME="$VPS_NAME"
LOCAL_DIR="$LOCAL_DIR"
LOCAL_KEEP="$LOCAL_KEEP"
REMOTE_IP="$REMOTE_IP"
REMOTE_PORT="$REMOTE_PORT"
REMOTE_USER="$REMOTE_USER"
REMOTE_PASS="$REMOTE_PASS"
REMOTE_DIR="$REMOTE_DIR"
REMOTE_KEEP_DAYS="$REMOTE_KEEP_DAYS"
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
EOF
    chmod 600 "$CONFIG_FILE"
}

do_setup() {
    print_banner
    info "⚙️ 配置向导"
    echo ""
    
    read -p "VPS 名称 [$(hostname)]: " VPS_NAME
    VPS_NAME=${VPS_NAME:-$(hostname)}
    
    read -p "本地快照目录 [/var/snapshots]: " LOCAL_DIR
    LOCAL_DIR=${LOCAL_DIR:-/var/snapshots}
    
    read -p "本地保留快照数量 [3]: " LOCAL_KEEP
    LOCAL_KEEP=${LOCAL_KEEP:-3}
    
    echo ""
    info "远程备份配置 (可选，留空跳过)"
    read -p "远程服务器 IP: " REMOTE_IP
    if [ -n "$REMOTE_IP" ]; then
        read -p "远程端口 [22]: " REMOTE_PORT
        REMOTE_PORT=${REMOTE_PORT:-22}
        read -p "远程用户 [root]: " REMOTE_USER
        REMOTE_USER=${REMOTE_USER:-root}
        read -s -p "远程密码: " REMOTE_PASS
        echo ""
        read -p "远程目录 [/backup]: " REMOTE_DIR
        REMOTE_DIR=${REMOTE_DIR:-/backup}
        read -p "远程保留天数 [30]: " REMOTE_KEEP_DAYS
        REMOTE_KEEP_DAYS=${REMOTE_KEEP_DAYS:-30}
    fi
    
    echo ""
    info "Telegram 通知 (可选，留空跳过)"
    read -p "Bot Token: " TG_BOT_TOKEN
    [ -n "$TG_BOT_TOKEN" ] && read -p "Chat ID: " TG_CHAT_ID
    
    save_config
    log "配置已保存到 $CONFIG_FILE"
}

#===============================================================================
# 主菜单
#===============================================================================

show_menu() {
    # 自动检测并安装依赖
    check_deps
    
    print_banner
    load_config 2>/dev/null || true
    
    echo -e "${CYAN}当前配置:${NC} ${VPS_NAME:-未配置}"
    echo ""
    echo "  1) 首次配置 / 重新配置"
    echo "  2) 扫描已安装应用"
    echo "  3) 创建本地快照"
    echo "  4) 创建快照并同步远程"
    echo "  5) 从本地快照恢复"
    echo "  6) 从配置的远程恢复"
    echo "  7) 自定义远程恢复 (输入任意服务器)"
    echo "  8) 一键迁移到新服务器"
    echo "  9) 导出 Docker 数据"
    echo " 10) 导入 Docker 数据"
    echo " 11) 查看本地快照"
    echo " 12) 同步到远程"
    echo " 13) 设置定时快照"
    echo " 14) 更新脚本"
    echo " 15) 安装依赖"
    echo "  0) 退出"
    echo ""
    read -p "请选择 [0-15]: " choice
    
    case $choice in
        1) do_setup ;;
        2) detect_apps ;;
        3) 
            load_config 2>/dev/null || true
            create_snapshot "${LOCAL_DIR:-/var/snapshots}" "${VPS_NAME:-snapshot}"
            ;;
        4) 
            load_config 2>/dev/null || true
            create_snapshot "${LOCAL_DIR:-/var/snapshots}" "${VPS_NAME:-snapshot}"
            do_sync_remote
            ;;
        5) do_restore_local ;;
        6) do_restore_config_remote ;;
        7) do_restore_remote ;;
        8) do_migrate ;;
        9) 
            read -p "输出目录 [/var/snapshots]: " dir
            docker_export "${dir:-/var/snapshots}"
            ;;
        10)
            read -p "输入目录 [/var/snapshots]: " dir
            docker_import "${dir:-/var/snapshots}"
            ;;
        11)
            load_config 2>/dev/null || true
            echo ""
            ls -lh "${LOCAL_DIR:-/var/snapshots}" 2>/dev/null || echo "无快照"
            ;;
        12) do_sync_remote ;;
        13) setup_cron ;;
        14) update_script ;;
        15) install_deps ;;
        0) exit 0 ;;
        *) error "无效选项" ;;
    esac
    
    echo ""
    read -p "按回车继续..."
    show_menu
}

#===============================================================================
# 入口
#===============================================================================

case "${1:-}" in
    setup) do_setup ;;
    scan) detect_apps ;;
    snapshot) 
        load_config 2>/dev/null || true
        create_snapshot "${LOCAL_DIR:-/var/snapshots}" "${VPS_NAME:-snapshot}" 
        ;;
    snapshot-sync)
        load_config 2>/dev/null || true
        create_snapshot "${LOCAL_DIR:-/var/snapshots}" "${VPS_NAME:-snapshot}"
        do_sync_remote
        ;;
    migrate) do_migrate ;;
    docker-export) docker_export "${2:-/var/snapshots}" ;;
    docker-import) docker_import "${2:-/var/snapshots}" ;;
    help|--help|-h)
        echo "用法: $0 [命令]"
        echo ""
        echo "命令:"
        echo "  setup         配置向导"
        echo "  scan          扫描已安装应用"
        echo "  snapshot      创建本地快照"
        echo "  snapshot-sync 创建快照并同步远程"
        echo "  migrate       一键迁移"
        echo "  docker-export 导出 Docker"
        echo "  docker-import 导入 Docker"
        echo ""
        echo "无参数运行显示交互菜单"
        ;;
    "") show_menu ;;
    *) error "未知命令: $1"; exit 1 ;;
esac
