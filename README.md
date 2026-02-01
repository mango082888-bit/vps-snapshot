# VPS 快照备份脚本

一键备份 VPS 系统到远程服务器，支持 Telegram 通知。

## 功能

- ✅ 支持 Ubuntu/Debian/CentOS/Alpine
- ✅ SSH 密钥认证（推荐）或密码认证
- ✅ 自动生成并配置 SSH 密钥
- ✅ rsync 增量同步到远程
- ✅ Telegram Bot 通知
- ✅ 本地保留指定数量快照
- ✅ 远程自动清理过期快照
- ✅ 定时任务支持

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/mango082888-bit/vps-snapshot/main/vps-snapshot.sh -o vps-snapshot.sh
chmod +x vps-snapshot.sh
```

## 使用

```bash
# 交互式配置
sudo ./vps-snapshot.sh setup

# 执行备份
sudo ./vps-snapshot.sh run

# 设置定时任务
sudo ./vps-snapshot.sh cron

# 查看状态
sudo ./vps-snapshot.sh status
```

## 配置说明

运行 `setup` 时会询问：

1. **远程服务器信息**：IP、端口、用户名
2. **认证方式**：SSH 密钥（自动生成）或密码
3. **备份目录**：本地和远程存储路径
4. **保留策略**：本地保留数量、远程保留天数
5. **Telegram 通知**：Bot Token 和 Chat ID
6. **备份内容**：完整系统或指定目录

## License

MIT
