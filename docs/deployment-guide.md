# conMon 部署指南

**版本**：v2.0 · **日期**：2026-06-15

---

## 目录

1. [系统要求](#1-系统要求)
2. [单机部署（二进制）](#2-单机部署二进制)
3. [Docker 部署](#3-docker-部署)
4. [Docker Compose 生产部署](#4-docker-compose-生产部署)
5. [Kubernetes 部署](#5-kubernetes-部署)
6. [高可用集群部署](#6-高可用集群部署)
7. [多地域探针部署](#7-多地域探针部署)
8. [TLS/HTTPS 配置](#8-tlshttps-配置)
9. [数据库初始化](#9-数据库初始化)
10. [升级指南](#10-升级指南)

---

## 1. 系统要求

### 1.1 最低配置（单机，≤500 目标）

| 资源 | 最低 | 推荐 |
|------|------|------|
| CPU | 1 核 | 2 核 |
| 内存 | 256 MB | 512 MB |
| 磁盘 | 1 GB | 10 GB |
| 操作系统 | Linux 3.10+ / macOS 12+ / Windows Server 2019 | Linux 5.x |

### 1.2 生产配置（≤5,000 目标）

| 资源 | 控制端 | 探针节点 | 数据库 |
|------|--------|---------|--------|
| CPU | 4 核 | 2 核 | 4 核 |
| 内存 | 4 GB | 1 GB | 8 GB |
| 磁盘 | 50 GB (SSD) | 10 GB | 200 GB (SSD) |
| 网络 | 100 Mbps | 10 Mbps | 千兆内网 |

### 1.3 软件依赖

| 组件 | 版本要求 | 说明 |
|------|---------|------|
| Linux kernel | ≥ 3.10 | 或等效 OS |
| PostgreSQL | ≥ 14 | 可选，生产推荐 |
| InfluxDB | ≥ 2.x | 可选，时序数据 |
| etcd | ≥ 3.5 | 集群部署必须 |
| Docker | ≥ 20.10 | 容器化部署 |
| Kubernetes | ≥ 1.24 | K8s 部署 |

### 1.4 端口说明

| 端口 | 组件 | 说明 |
|------|------|------|
| 8080 | conmon-server | HTTP API / Web UI |
| 8443 | conmon-server | HTTPS（启用 TLS 时） |
| 9090 | conmon-server | gRPC（探针连接） |
| 9091 | conmon-probe | 探针健康检查 |

---

## 2. 单机部署（二进制）

### 2.1 下载与安装

```bash
# 下载最新版本（以 linux-amd64 为例）
VERSION="v2.0.0"
curl -LO "https://github.com/grandinfo/gi-conMon/releases/download/${VERSION}/conmon-linux-amd64.tar.gz"
curl -LO "https://github.com/grandinfo/gi-conMon/releases/download/${VERSION}/conmon-linux-amd64.tar.gz.sha256"

# 验证 SHA256
sha256sum -c conmon-linux-amd64.tar.gz.sha256

# 解压
tar -xzf conmon-linux-amd64.tar.gz -C /usr/local/bin/
chmod +x /usr/local/bin/conmon

# 验证安装
conmon version
```

### 2.2 创建配置与数据目录

```bash
sudo mkdir -p /etc/conmon /var/lib/conmon /var/log/conmon

# 创建运行用户（非 root 运行）
sudo useradd -r -s /sbin/nologin -d /var/lib/conmon conmon
sudo chown -R conmon:conmon /var/lib/conmon /var/log/conmon

# 放置配置文件
sudo cp examples/conmon.yaml /etc/conmon/conmon.yaml
sudo chown root:conmon /etc/conmon/conmon.yaml
sudo chmod 640 /etc/conmon/conmon.yaml
```

### 2.3 ICMP 权限设置

```bash
# 方式一：赋予 CAP_NET_RAW 能力（推荐）
sudo setcap cap_net_raw+ep /usr/local/bin/conmon

# 方式二：允许 setuid（不推荐）
# sudo chmod u+s /usr/local/bin/conmon
```

### 2.4 注册 systemd 服务

```bash
# 方式一：使用内置安装命令
sudo conmon server install

# 方式二：手动创建 unit 文件
sudo cat > /etc/systemd/system/conmon.service << 'EOF'
[Unit]
Description=conMon Network Connection Monitor
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=conmon
Group=conmon
ExecStart=/usr/local/bin/conmon server -c /etc/conmon/conmon.yaml
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5s
TimeoutStopSec=30s

# 安全加固
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/var/lib/conmon /var/log/conmon
NoNewPrivileges=true
AmbientCapabilities=CAP_NET_RAW

# 环境变量（敏感配置）
EnvironmentFile=-/etc/conmon/conmon.env

StandardOutput=journal
StandardError=journal
SyslogIdentifier=conmon

[Install]
WantedBy=multi-user.target
EOF

# 创建环境变量文件
sudo cat > /etc/conmon/conmon.env << 'EOF'
DB_PASSWORD=your-database-password
JWT_SECRET=your-jwt-secret-key
DINGTALK_WEBHOOK_URL=https://oapi.dingtalk.com/robot/send?access_token=xxx
EOF
sudo chmod 600 /etc/conmon/conmon.env

sudo systemctl daemon-reload
sudo systemctl enable conmon
sudo systemctl start conmon
sudo systemctl status conmon
```

### 2.5 验证启动

```bash
# 查看日志
sudo journalctl -u conmon -f

# 健康检查
curl http://localhost:8080/health

# 查看状态
conmon status
```

---

## 3. Docker 部署

### 3.1 快速启动（SQLite 单机）

```bash
docker run -d \
  --name conmon \
  --restart unless-stopped \
  -p 8080:8080 \
  -v /etc/conmon/conmon.yaml:/etc/conmon/conmon.yaml:ro \
  -v conmon-data:/data \
  --env-file /etc/conmon/conmon.env \
  conmon/conmon:latest
```

### 3.2 查看日志

```bash
docker logs -f conmon
docker exec conmon conmon status
```

### 3.3 构建自定义镜像

```bash
git clone https://github.com/grandinfo/gi-conMon.git
cd gi-conMon
docker build -t my-conmon:latest .
```

---

## 4. Docker Compose 生产部署

### 4.1 目录结构

```
deploy/
├── docker-compose.yml
├── .env                         # 环境变量（不提交到 git）
├── conmon/
│   └── conmon.yaml
├── postgres/
│   └── init.sql
├── influxdb/
│   └── config.yml
├── grafana/
│   └── dashboards/
└── nginx/
    └── conmon.conf
```

### 4.2 `.env` 文件

```bash
# .env — 环境变量（不提交到版本控制）
CONMON_VERSION=v2.0.0
DB_PASSWORD=strong-random-password
INFLUXDB_TOKEN=influxdb-admin-token
JWT_SECRET=64-char-random-secret
GRAFANA_PASSWORD=admin-password
DOMAIN=conmon.example.com
```

### 4.3 `docker-compose.yml`

```yaml
version: "3.9"

services:
  conmon-server:
    image: conmon/conmon:${CONMON_VERSION:-latest}
    container_name: conmon-server
    restart: unless-stopped
    ports:
      - "127.0.0.1:8080:8080"    # 只绑定本机，由 nginx 反代
      - "127.0.0.1:9090:9090"    # gRPC 探针端口
    volumes:
      - ./conmon/conmon.yaml:/etc/conmon/conmon.yaml:ro
      - conmon-logs:/var/log/conmon
    environment:
      - DB_PASSWORD=${DB_PASSWORD}
      - INFLUXDB_TOKEN=${INFLUXDB_TOKEN}
      - JWT_SECRET=${JWT_SECRET}
    depends_on:
      postgres:
        condition: service_healthy
      influxdb:
        condition: service_healthy
    networks:
      - conmon-net
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:8080/health"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 15s

  postgres:
    image: postgres:16-alpine
    container_name: conmon-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: conmon
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_DB: conmon
    volumes:
      - postgres-data:/var/lib/postgresql/data
      - ./postgres/init.sql:/docker-entrypoint-initdb.d/init.sql:ro
    networks:
      - conmon-net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U conmon"]
      interval: 5s
      timeout: 3s
      retries: 10

  influxdb:
    image: influxdb:2.7-alpine
    container_name: conmon-influxdb
    restart: unless-stopped
    environment:
      DOCKER_INFLUXDB_INIT_MODE: setup
      DOCKER_INFLUXDB_INIT_USERNAME: admin
      DOCKER_INFLUXDB_INIT_PASSWORD: ${DB_PASSWORD}
      DOCKER_INFLUXDB_INIT_ORG: conmon
      DOCKER_INFLUXDB_INIT_BUCKET: conmon_metrics
      DOCKER_INFLUXDB_INIT_ADMIN_TOKEN: ${INFLUXDB_TOKEN}
    volumes:
      - influxdb-data:/var/lib/influxdb2
    networks:
      - conmon-net
    healthcheck:
      test: ["CMD", "influx", "ping"]
      interval: 10s
      timeout: 5s
      retries: 10

  grafana:
    image: grafana/grafana:latest
    container_name: conmon-grafana
    restart: unless-stopped
    environment:
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_PASSWORD}
      GF_SERVER_ROOT_URL: "https://${DOMAIN}/grafana"
    volumes:
      - grafana-data:/var/lib/grafana
      - ./grafana/dashboards:/etc/grafana/provisioning/dashboards:ro
    networks:
      - conmon-net

  nginx:
    image: nginx:alpine
    container_name: conmon-nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/conmon.conf:/etc/nginx/conf.d/conmon.conf:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
      - nginx-logs:/var/log/nginx
    depends_on:
      - conmon-server
    networks:
      - conmon-net

volumes:
  postgres-data:
  influxdb-data:
  grafana-data:
  conmon-logs:
  nginx-logs:

networks:
  conmon-net:
    driver: bridge
```

### 4.4 启动命令

```bash
# 首次启动
docker compose up -d

# 查看状态
docker compose ps
docker compose logs -f conmon-server

# 停止
docker compose down

# 升级（不删除数据）
docker compose pull
docker compose up -d --no-deps conmon-server
```

---

## 5. Kubernetes 部署

### 5.1 使用 Helm 安装

```bash
# 添加 Helm 仓库
helm repo add conmon https://grandinfo.github.io/gi-conMon/charts
helm repo update

# 查看可配置选项
helm show values conmon/conmon

# 创建 values 文件
cat > conmon-values.yaml << 'EOF'
replicaCount: 3

image:
  repository: conmon/conmon
  tag: v2.0.0
  pullPolicy: IfNotPresent

server:
  externalUrl: "https://conmon.k8s.example.com"

ingress:
  enabled: true
  className: nginx
  hosts:
    - host: conmon.k8s.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: conmon-tls
      hosts:
        - conmon.k8s.example.com

postgresql:
  enabled: true
  auth:
    password: "your-db-password"

influxdb:
  enabled: true
  auth:
    adminToken: "your-influxdb-token"

resources:
  requests:
    cpu: 500m
    memory: 256Mi
  limits:
    cpu: 2000m
    memory: 1Gi

probe:
  enabled: true
  daemonset: true    # 在每个节点部署探针
EOF

# 安装
helm install conmon conmon/conmon \
  --namespace conmon-system \
  --create-namespace \
  -f conmon-values.yaml

# 查看状态
kubectl -n conmon-system get pods
kubectl -n conmon-system get svc
```

### 5.2 手动 YAML 部署

```bash
# 应用基础 YAML 配置（内置于仓库）
kubectl apply -f deployments/kubernetes/namespace.yaml
kubectl apply -f deployments/kubernetes/rbac.yaml
kubectl apply -f deployments/kubernetes/configmap.yaml
kubectl apply -f deployments/kubernetes/secret.yaml
kubectl apply -f deployments/kubernetes/deployment.yaml
kubectl apply -f deployments/kubernetes/service.yaml
kubectl apply -f deployments/kubernetes/ingress.yaml

# 查看部署状态
kubectl -n conmon-system rollout status deployment/conmon-server
```

### 5.3 使用 CRD 定义监控目标

```yaml
# monitor-target.yaml
apiVersion: conmon.io/v1
kind: MonitorTarget
metadata:
  name: my-web-service
  namespace: default
spec:
  name: "我的 Web 服务"
  host: "my-svc.default.svc.cluster.local"
  port: 8080
  protocol: http
  interval: 30s
  tags:
    - "k8s"
    - "生产"
  alertConfig:
    downThreshold: 3
    channels: ["dingtalk"]
```

```bash
kubectl apply -f monitor-target.yaml
```

---

## 6. 高可用集群部署

### 6.1 etcd 集群

```bash
# 三节点 etcd 集群（每个节点执行对应命令）
# 节点1（192.168.1.10）
etcd --name node1 \
  --initial-advertise-peer-urls http://192.168.1.10:2380 \
  --listen-peer-urls http://192.168.1.10:2380 \
  --listen-client-urls http://192.168.1.10:2379,http://127.0.0.1:2379 \
  --advertise-client-urls http://192.168.1.10:2379 \
  --initial-cluster-token conmon-etcd-cluster \
  --initial-cluster "node1=http://192.168.1.10:2380,node2=http://192.168.1.11:2380,node3=http://192.168.1.12:2380" \
  --initial-cluster-state new
```

### 6.2 控制端集群配置

```yaml
# conmon.yaml（三个控制端节点使用相同配置）
server:
  bind: "0.0.0.0:8080"
  cluster:
    enabled: true
    etcd_endpoints:
      - "http://192.168.1.10:2379"
      - "http://192.168.1.11:2379"
      - "http://192.168.1.12:2379"
    node_id: "${NODE_ID}"    # 每个节点不同：node1/node2/node3

storage:
  type: "postgresql"
  dsn: "postgres://conmon:${DB_PASSWORD}@postgres-primary:5432/conmon"
  replica_dsn: "postgres://conmon:${DB_PASSWORD}@postgres-replica:5432/conmon"
```

### 6.3 负载均衡（Nginx）

```nginx
upstream conmon_servers {
    least_conn;
    server 192.168.1.10:8080 max_fails=3 fail_timeout=30s;
    server 192.168.1.11:8080 max_fails=3 fail_timeout=30s;
    server 192.168.1.12:8080 max_fails=3 fail_timeout=30s;
    keepalive 32;
}

server {
    listen 443 ssl http2;
    server_name conmon.example.com;

    ssl_certificate     /etc/ssl/conmon.crt;
    ssl_certificate_key /etc/ssl/conmon.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    # WebSocket 支持
    location /api/v1/ws {
        proxy_pass http://conmon_servers;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
    }

    location / {
        proxy_pass http://conmon_servers;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

---

## 7. 多地域探针部署

### 7.1 探针配置

```yaml
# probe-beijing.yaml
probe:
  id: "probe-bj-01"
  name: "北京-电信"
  location: "北京"
  isp: "电信"
  tags: ["华北", "电信", "IDC-BJ"]

  # 控制端地址（多个控制端时配置多个，自动故障转移）
  server_endpoints:
    - "grpcs://conmon.example.com:9090"
    - "grpcs://conmon-backup.example.com:9090"

  # 本地缓冲（控制端不可达时最多缓存多少条结果）
  buffer_size: 100000

  # TLS 证书（由控制端 CA 签发）
  tls:
    cert_file: "/etc/conmon-probe/probe.crt"
    key_file:  "/etc/conmon-probe/probe.key"
    ca_file:   "/etc/conmon-probe/ca.crt"

  concurrency: 200
```

### 7.2 探针注册

```bash
# 在控制端生成探针证书
conmon probe cert --id probe-bj-01 --name "北京-电信" --output probe-bj-01/

# 将生成的证书文件复制到探针节点
scp probe-bj-01/probe.crt probe-bj-01/probe.key probe-bj-01/ca.crt probe@bj-01:/etc/conmon-probe/

# 在探针节点启动
conmon probe start -c /etc/conmon-probe/probe.yaml

# 在控制端查看探针注册状态
conmon probe list
```

---

## 8. TLS/HTTPS 配置

### 8.1 使用 Let's Encrypt

```bash
# 安装 certbot
apt-get install certbot

# 申请证书
certbot certonly --standalone -d conmon.example.com

# 配置自动续期
echo "0 3 * * * certbot renew --quiet && kill -HUP \$(pgrep nginx)" | crontab -
```

### 8.2 conmon-server TLS 配置

```yaml
server:
  tls:
    enabled: true
    cert_file: "/etc/letsencrypt/live/conmon.example.com/fullchain.pem"
    key_file:  "/etc/letsencrypt/live/conmon.example.com/privkey.pem"
    min_version: "TLS1.2"
    client_auth: false        # 是否要求客户端证书（探针 mTLS 在 gRPC 侧配置）
```

### 8.3 探针 mTLS 配置

```bash
# 生成内部 CA（首次部署）
conmon pki init --ca-name "conMon Internal CA" --output /etc/conmon/pki/

# 签发服务端证书
conmon pki issue-server --ca /etc/conmon/pki/ --domains "conmon.example.com" --output /etc/conmon/pki/

# 签发探针证书
conmon pki issue-probe --ca /etc/conmon/pki/ --probe-id probe-bj-01 --output /etc/conmon/pki/probes/probe-bj-01/
```

---

## 9. 数据库初始化

### 9.1 PostgreSQL 初始化

```bash
# 创建数据库和用户
psql -U postgres << 'EOF'
CREATE USER conmon WITH PASSWORD 'your-password';
CREATE DATABASE conmon OWNER conmon;
GRANT ALL PRIVILEGES ON DATABASE conmon TO conmon;
EOF

# 运行 schema 迁移（conmon 会在首次启动时自动执行）
conmon db migrate --dsn "postgres://conmon:password@localhost/conmon"

# 查看迁移状态
conmon db status --dsn "postgres://conmon:password@localhost/conmon"
```

### 9.2 InfluxDB 初始化

```bash
# 使用 Docker 运行（首次初始化）
docker run --rm influxdb:2.7 influx setup \
  --host http://localhost:8086 \
  --token admin-token \
  --org conmon \
  --bucket conmon_metrics \
  --username admin \
  --password admin-password \
  --force

# 创建保留策略（按需配置）
influx bucket update --name conmon_metrics --retention 7d
influx bucket create --name conmon_metrics_1h --retention 365d
```

---

## 10. 升级指南

### 10.1 升级前准备

```bash
# 1. 备份数据库
pg_dump -U conmon conmon > conmon_backup_$(date +%Y%m%d).sql

# 2. 备份配置文件
cp /etc/conmon/conmon.yaml /etc/conmon/conmon.yaml.backup

# 3. 查看当前版本
conmon version

# 4. 查看升级日志（Release Notes）
curl https://api.github.com/repos/grandinfo/gi-conMon/releases/latest | jq '.body'
```

### 10.2 滚动升级（无停机）

```bash
# 下载新版本
curl -LO "https://github.com/grandinfo/gi-conMon/releases/download/v2.1.0/conmon-linux-amd64.tar.gz"
tar -xzf conmon-linux-amd64.tar.gz -C /tmp/

# 执行迁移（在线执行，不停服）
/tmp/conmon db migrate --dsn "$DSN"

# 替换二进制
sudo mv /usr/local/bin/conmon /usr/local/bin/conmon.bak
sudo mv /tmp/conmon /usr/local/bin/conmon
sudo chmod +x /usr/local/bin/conmon
sudo setcap cap_net_raw+ep /usr/local/bin/conmon

# 重启服务
sudo systemctl restart conmon
sudo systemctl status conmon

# 验证新版本
conmon version
curl http://localhost:8080/health
```

### 10.3 回滚

```bash
# 恢复旧二进制
sudo mv /usr/local/bin/conmon.bak /usr/local/bin/conmon
sudo systemctl restart conmon

# 如果需要回滚数据库（谨慎操作）
psql -U conmon conmon < conmon_backup_20260615.sql
```

### 10.4 Docker Compose 升级

```bash
# 更新 .env 中的版本号
sed -i 's/CONMON_VERSION=.*/CONMON_VERSION=v2.1.0/' .env

# 拉取新镜像
docker compose pull conmon-server

# 滚动更新（无停机）
docker compose up -d --no-deps --build conmon-server

# 验证
docker compose ps
docker compose logs conmon-server | tail -20
```

---

*如需专业部署支持，请联系 ops@example.com。*
