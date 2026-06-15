# conMon 部署脚本说明

`deploy/` 目录包含 conMon 各场景的完整部署、运维自动化脚本。

---

## 脚本列表

| 脚本 | 用途 | 权限要求 |
|------|------|---------|
| `check.sh` | 部署前环境预检 | 普通用户 |
| `install.sh` | 二进制一键安装 + systemd 注册 | root |
| `docker.sh` | Docker 单机部署管理 | docker 组 |
| `compose.sh` | Docker Compose 全栈部署 | docker 组 |
| `k8s.sh` | Kubernetes 部署助手 | kubectl 权限 |
| `upgrade.sh` | 自动升级（自动检测部署方式）| 视部署方式 |
| `backup.sh` | 数据备份与恢复 | root 或数据目录权限 |
| `uninstall.sh` | 卸载 conMon | root |

---

## 快速开始

### 1. 环境检查（所有方式均建议先执行）

```bash
# 检查通用环境
bash deploy/check.sh

# 检查特定部署方式所需环境
bash deploy/check.sh --mode docker    # Docker 部署检查
bash deploy/check.sh --mode compose   # Compose 部署检查
bash deploy/check.sh --mode k8s       # Kubernetes 部署检查
bash deploy/check.sh --mode all       # 检查所有模式
```

### 2. 选择部署方式

#### 方式 A：二进制 + systemd（推荐裸机/虚拟机）

```bash
# 一键安装（最新版本）
sudo bash deploy/install.sh

# 安装指定版本
sudo bash deploy/install.sh --version v2.0.0

# 安装并使用自定义配置
sudo bash deploy/install.sh --config /my/conmon.yaml

# 启动服务
sudo systemctl start conmon
sudo systemctl status conmon
```

#### 方式 B：Docker 单机（推荐快速上手/单服务器）

```bash
# 启动
bash deploy/docker.sh start

# 查看状态
bash deploy/docker.sh status

# 实时日志
bash deploy/docker.sh logs -f

# 更新到新版本
bash deploy/docker.sh update v2.1.0

# 停止
bash deploy/docker.sh stop
```

#### 方式 C：Docker Compose 全栈（推荐中小规模生产）

```bash
# 初始化（首次执行，自动生成 .env 和随机密钥）
bash deploy/compose.sh init

# 启动（含 conmon + PostgreSQL + Grafana）
bash deploy/compose.sh up

# 查看状态
bash deploy/compose.sh status

# 实时日志
bash deploy/compose.sh logs conmon-server -f

# 升级
bash deploy/compose.sh upgrade v2.1.0

# 停止
bash deploy/compose.sh down
```

#### 方式 D：Kubernetes（推荐大规模云原生）

```bash
# 使用 Helm 安装
bash deploy/k8s.sh --version v2.0.0 install

# 不使用 Helm（kubectl apply）
bash deploy/k8s.sh --namespace monitoring apply

# 查看状态
bash deploy/k8s.sh status

# 本地端口转发（调试）
bash deploy/k8s.sh port-forward

# 升级
bash deploy/k8s.sh --version v2.1.0 upgrade

# 查看日志
bash deploy/k8s.sh logs -f
```

---

## 升级

```bash
# 自动检测部署方式并升级到最新版
bash deploy/upgrade.sh

# 升级到指定版本
bash deploy/upgrade.sh v2.1.0

# 预览升级操作（不执行）
bash deploy/upgrade.sh --dry-run v2.1.0
```

---

## 备份与恢复

```bash
# 全量备份（备份配置 + SQLite 数据库 + 最近日志）
bash deploy/backup.sh

# 指定备份目录和保留天数
bash deploy/backup.sh --dest /mnt/nas/conmon-backup --keep 60

# 列出所有可用备份
bash deploy/backup.sh --list

# 从指定备份恢复
bash deploy/backup.sh --restore 20260615_030000

# 配置定期备份（cron，每天凌晨 3 点）
echo "0 3 * * * /bin/bash $(pwd)/deploy/backup.sh --dest /backup/conmon >> /var/log/conmon-backup.log 2>&1" | crontab -
```

---

## 卸载

```bash
# 卸载但保留数据（推荐，可以随时重新安装恢复）
sudo bash deploy/uninstall.sh

# 完全卸载（删除所有数据和配置，不可恢复！）
sudo bash deploy/uninstall.sh --all

# 预览将执行的操作
sudo bash deploy/uninstall.sh --dry-run
```

---

## 脚本权限设置

首次使用前给脚本赋予执行权限：

```bash
chmod +x deploy/*.sh
```

---

## 环境变量

所有脚本均支持以下环境变量覆盖默认值：

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `CONMON_VERSION` | 镜像/二进制版本 | `latest` |
| `CONMON_HTTP_PORT` | HTTP 端口 | `11080` |
| `CONMON_CONFIG` | 配置文件路径 | `./configs/conmon.yaml` |
| `CONMON_DATA_DIR` | 数据目录 | `/var/lib/conmon` |
| `CONMON_CONFIG_DIR` | 配置目录 | `/etc/conmon` |
| `BACKUP_DEST` | 备份目录 | `/var/backups/conmon` |
| `BACKUP_KEEP_DAYS` | 备份保留天数 | `30` |
| `JWT_SECRET` | JWT 密钥 | （必须设置）|
| `DB_PASSWORD` | 数据库密码 | （PostgreSQL 模式必须设置）|

```bash
# 示例：使用环境变量定制
CONMON_HTTP_PORT=9000 JWT_SECRET="my-secret" bash deploy/docker.sh start
```

---

## 常见问题

**Q: `install.sh` 报错权限不足？**
```bash
sudo bash deploy/install.sh
```

**Q: Docker 容器启动后 `/health` 返回 503？**
```bash
bash deploy/docker.sh logs  # 查看启动日志
# 通常是 SQLite 数据目录权限问题
docker exec conmon ls -la /var/lib/conmon
```

**Q: Compose 服务启动后 conmon-server 一直 unhealthy？**
```bash
bash deploy/compose.sh logs conmon-server
# 检查 PostgreSQL 是否正常
bash deploy/compose.sh logs postgres
```

**Q: 升级后服务无法启动？**
```bash
# 使用备份回滚
bash deploy/backup.sh --list
bash deploy/backup.sh --restore <时间戳>
```

更多问题参见 [故障排查指南](../docs/troubleshooting.md)。
