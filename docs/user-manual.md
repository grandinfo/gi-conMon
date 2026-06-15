# conMon 用户手册

**版本**：v2.0 · **日期**：2026-06-15

---

## 目录

1. [快速入门](#1-快速入门)
2. [核心概念](#2-核心概念)
3. [配置说明](#3-配置说明)
4. [监控目标管理](#4-监控目标管理)
5. [告警规则配置](#5-告警规则配置)
6. [通知渠道配置](#6-通知渠道配置)
7. [Web 控制台使用](#7-web-控制台使用)
8. [CLI 命令参考](#8-cli-命令参考)
9. [REST API 快速参考](#9-rest-api-快速参考)
10. [维护窗口与静默](#10-维护窗口与静默)
11. [报表与 SLA](#11-报表与-sla)

---

## 1. 快速入门

### 1.1 五分钟上手（Docker 单机版）

```bash
# 拉取最新镜像
docker pull conmon/conmon:latest

# 创建最小配置文件
cat > conmon.yaml << 'EOF'
server:
  bind: "0.0.0.0:8080"

storage:
  type: "sqlite"
  path: "/data/conmon.db"

monitors:
  - name: "百度连通性"
    target: "www.baidu.com"
    protocol: "icmp"
    interval: "30s"

  - name: "百度 HTTPS"
    target: "www.baidu.com"
    protocol: "https"
    port: 443
    interval: "1m"
EOF

# 启动服务
docker run -d \
  --name conmon \
  -p 8080:8080 \
  -v $(pwd)/conmon.yaml:/etc/conmon/conmon.yaml \
  -v conmon-data:/data \
  conmon/conmon:latest

# 查看状态
curl http://localhost:8080/api/v1/status | jq
```

浏览器访问 `http://localhost:8080` 即可看到 Web 控制台。

### 1.2 使用二进制文件

```bash
# 下载对应平台二进制
curl -LO https://github.com/grandinfo/gi-conMon/releases/latest/download/conmon-linux-amd64.tar.gz
tar -xzf conmon-linux-amd64.tar.gz

# 验证版本
./conmon version

# 使用默认配置启动（自动扫描 ./conmon.yaml 或 /etc/conmon/conmon.yaml）
./conmon server -c conmon.yaml

# 后台以 systemd 运行
sudo ./conmon install  # 自动生成并注册 systemd unit
sudo systemctl start conmon
sudo systemctl enable conmon
```

### 1.3 状态验证

```bash
# 健康检查
curl http://localhost:8080/health

# 全局状态概览
curl http://localhost:8080/api/v1/status

# 查看所有监控目标状态
./conmon status

# 输出示例：
# NAME           HOST               PROTOCOL  STATUS    LATENCY   UPTIME_7D
# 百度连通性      www.baidu.com      icmp      UP        12ms      99.99%
# 百度 HTTPS     www.baidu.com      https     UP        89ms      99.97%
```

---

## 2. 核心概念

### 2.1 监控目标（Target）

监控目标是 conMon 的基本管理单元，代表一个需要持续探测的网络端点。每个目标包含：

- **连接信息**：主机名/IP、端口、协议
- **探测参数**：间隔、超时、重试次数
- **告警配置**：DOWN 阈值、延迟阈值、通知渠道
- **标签**：用于分组、过滤、告警规则匹配
- **依赖关系**：声明上游依赖，实现智能告警抑制

### 2.2 探针节点（Probe Node）

探针节点是部署在不同地域的探测执行器：

- **就近探测**：北京探针探测北方目标，减少额外网络延迟
- **多点验证**：同一目标由多个探针同时探测，确认是本地故障还是全局故障
- **探针自治**：探针与控制端断联后本地继续执行探测，恢复后批量同步

### 2.3 状态（Status）

| 状态 | 颜色 | 含义 |
|------|------|------|
| **UP** | 绿色 | 服务正常，响应在预期范围内 |
| **DOWN** | 红色 | 服务不可用，连续探测失败达到阈值 |
| **DEGRADED** | 黄色 | 服务可用但性能下降（高延迟/高丢包） |
| **FLAPPING** | 橙色 | 服务不稳定，频繁上下线 |
| **MAINTENANCE** | 蓝色 | 维护窗口期，暂停告警 |
| **SILENT** | 灰色 | 手动静默，持续探测但不通知 |
| **UNKNOWN** | 白色 | 初始状态，尚无探测结果 |

### 2.4 事件（Event）

每次状态变更产生一个事件记录，包含：前状态、新状态、触发原因、持续时长、探针信息。事件是告警触发的来源，也是 SLA 计算的数据基础。

### 2.5 告警（Alert）

告警是事件经过规则评估后产生的通知任务：

- 支持多渠道并发发送
- 未确认时自动升级（L1→L2→L3）
- 同根因多个告警自动关联为"事件组"
- 故障恢复时自动发送恢复通知

---

## 3. 配置说明

### 3.1 配置文件结构

```yaml
# conmon.yaml — 完整配置参考

# ===== 服务端配置 =====
server:
  bind: "0.0.0.0:8080"          # 监听地址
  external_url: "https://conmon.corp.com"  # 外部访问 URL（用于告警链接）
  tls:
    enabled: false               # 是否启用 HTTPS
    cert_file: "/etc/conmon/server.crt"
    key_file:  "/etc/conmon/server.key"
  auth:
    jwt_secret: "${JWT_SECRET}"  # JWT 签名密钥
    token_expire: "24h"         # Token 有效期

# ===== 存储配置 =====
storage:
  # SQLite（单机开发/边缘环境）
  type: "sqlite"
  path: "/data/conmon.db"

  # PostgreSQL（生产环境）
  # type: "postgresql"
  # dsn: "postgres://conmon:${DB_PASSWORD}@localhost:5432/conmon?sslmode=require"

  timeseries:
    # InfluxDB（时序数据）
    type: "influxdb"
    url: "http://localhost:8086"
    token: "${INFLUXDB_TOKEN}"
    org: "conmon"
    bucket: "conmon_metrics"

  retention:
    raw: "7d"       # 原始探测数据保留时长
    events: "90d"   # 事件记录保留时长
    alerts: "180d"  # 告警记录保留时长

# ===== 探针节点配置（probe 进程使用） =====
probe:
  id: "probe-local-01"
  name: "本地探针"
  location: "北京"
  isp: "电信"
  tags: ["华北", "电信"]
  server_endpoint: "grpc://localhost:9090"  # 控制端 gRPC 地址
  concurrency: 100                           # 最大并发探测数

# ===== 监控目标列表 =====
monitors:
  - name: "示例目标"
    target: "example.com"
    protocol: "https"
    port: 443
    interval: "1m"
    timeout: "10s"
    retries: 3
    tags: ["示例"]

# ===== 告警配置 =====
alerting:
  channels: []
  rules: []

# ===== 日志配置 =====
log:
  level: "info"          # debug/info/warn/error
  format: "json"         # json/text
  output: "stdout"       # stdout/file
  file:
    path: "/var/log/conmon/conmon.log"
    max_size_mb: 100
    max_backups: 7
```

### 3.2 探测协议特定配置

#### HTTP/HTTPS

```yaml
monitors:
  - name: "Web 服务"
    target: "api.example.com"
    protocol: "https"
    port: 443
    interval: "30s"
    probe_config:
      method: "GET"                    # HTTP 方法
      path: "/health"                  # 请求路径（默认 /）
      headers:
        Authorization: "Bearer ${API_TOKEN}"
        User-Agent: "conmon-healthcheck/2.0"
      expected_codes: [200, 204]       # 期望状态码（默认 [200]）
      body_contains: "\"status\":\"ok\""  # 响应体包含字符串（可选）
      follow_redirects: true           # 是否跟随重定向（默认 true）
      tls_skip_verify: false           # 是否跳过证书校验（不建议生产使用）
      cert_warn_days: 30               # 证书过期预警天数
```

#### TCP

```yaml
  - name: "数据库端口"
    target: "db.example.com"
    protocol: "tcp"
    port: 5432
    interval: "10s"
    probe_config:
      send_data: ""                    # 连接后发送的数据（可选）
      expect_data: ""                  # 期望收到的响应（可选）
```

#### DNS

```yaml
  - name: "DNS 解析"
    target: "8.8.8.8"
    protocol: "dns"
    port: 53
    interval: "1m"
    probe_config:
      query_type: "A"                  # A/AAAA/MX/TXT/NS/CNAME
      query_domain: "example.com"
      expected_answer: "93.184.216.34" # 期望解析结果（可选）
```

#### ICMP

```yaml
  - name: "网关连通性"
    target: "192.168.1.1"
    protocol: "icmp"
    interval: "15s"
    probe_config:
      packet_size: 56                  # ICMP 包大小（字节）
      ttl: 64                          # TTL 值
      count: 3                         # 每次探测发送的包数（取平均延迟）
```

### 3.3 环境变量支持

所有配置值均支持 `${ENV_VAR}` 语法引用环境变量，用于敏感信息注入：

```bash
export DB_PASSWORD="secret"
export JWT_SECRET="my-jwt-secret-key"
export DINGTALK_WEBHOOK_URL="https://oapi.dingtalk.com/robot/send?access_token=xxx"
```

---

## 4. 监控目标管理

### 4.1 通过配置文件管理

在 `conmon.yaml` 的 `monitors` 列表中声明目标，重载配置生效：

```bash
# 热重载（不重启服务）
kill -HUP $(pgrep conmon-server)
# 或通过 API
curl -X POST http://localhost:8080/api/v1/admin/reload
```

### 4.2 通过 CLI 管理

```bash
# 添加监控目标
conmon target add \
  --name "我的服务" \
  --host "myapp.example.com" \
  --protocol https \
  --port 443 \
  --interval 30s \
  --tags "生产,P1"

# 查看所有目标
conmon target list
conmon target list --status DOWN          # 只显示 DOWN 的目标
conmon target list --tags "生产"          # 按标签过滤

# 查看目标详情
conmon target get --id target-001
conmon target get --name "我的服务"

# 修改目标
conmon target update --id target-001 --interval 1m

# 删除目标
conmon target delete --id target-001

# 立即触发一次探测（不等待下次调度）
conmon target probe --id target-001

# 导入批量目标（YAML 文件）
conmon target import --file targets.yaml

# 导出所有目标配置
conmon target export --output targets.yaml
```

### 4.3 通过 REST API 管理

```bash
# 创建目标
curl -X POST http://localhost:8080/api/v1/targets \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "我的服务",
    "host": "myapp.example.com",
    "port": 443,
    "protocol": "https",
    "interval": "30s",
    "tags": ["生产", "P1"]
  }'

# 获取目标列表
curl http://localhost:8080/api/v1/targets?status=DOWN&tags=生产

# 更新目标
curl -X PUT http://localhost:8080/api/v1/targets/target-001 \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"interval": "1m"}'

# 删除目标
curl -X DELETE http://localhost:8080/api/v1/targets/target-001 \
  -H "Authorization: Bearer $TOKEN"
```

### 4.4 目标标签与分组

标签是组织目标的核心机制，建议使用统一的标签体系：

```yaml
# 推荐标签分类
tags:
  环境: ["生产", "预发", "测试"]
  优先级: ["P0", "P1", "P2", "P3"]
  地域: ["华北", "华东", "华南", "海外"]
  业务: ["核心链路", "支付", "用户", "推荐"]
  类型: ["数据库", "缓存", "消息队列", "网关"]
```

### 4.5 依赖关系声明

声明依赖后，当上游依赖目标 DOWN 时，下游目标的告警自动抑制：

```yaml
monitors:
  - name: "核心路由器"
    id: "router-core"
    target: "10.0.0.1"
    protocol: "icmp"

  - name: "应用服务器"
    target: "10.0.1.10"
    protocol: "tcp"
    port: 8080
    dependencies: ["router-core"]   # 路由器 DOWN → 应用服务器告警抑制
```

---

## 5. 告警规则配置

### 5.1 规则结构

```yaml
alerting:
  rules:
    - name: "规则名称"                          # 唯一标识
      condition: "CEL 表达式"                  # 触发条件
      channels: ["渠道名1", "渠道名2"]          # 通知渠道
      severity: "error"                        # critical/error/warn/info
      throttle: "5m"                           # 同目标最小告警间隔（去重）
      escalate_after: "10m"                    # 未 ACK 多久后升级
      template: ""                             # 自定义模板名（留空用默认）
```

### 5.2 条件表达式（CEL 语法）

```yaml
# 常用条件示例

# 目标变为 DOWN
condition: "event.to_status == 'DOWN'"

# P0 目标变为 DOWN
condition: "event.to_status == 'DOWN' && 'P0' in target.tags"

# 高延迟预警（延迟超过 500ms）
condition: "state.avg_latency_ms > 500"

# 证书即将过期（30 天内）
condition: "state.cert_expiry_days < 30 && state.cert_expiry_days >= 0"

# 丢包率超过 10%
condition: "state.packet_loss_pct > 0.1"

# 特定目标恢复（发送恢复通知）
condition: "event.to_status == 'UP' && event.from_status == 'DOWN'"

# HTTPS 目标的任何异常（DOWN 或 DEGRADED）
condition: "(event.to_status == 'DOWN' || event.to_status == 'DEGRADED') && target.protocol == 'https'"

# 排除测试环境
condition: "event.to_status == 'DOWN' && !('测试' in target.tags)"
```

### 5.3 内置可用变量

| 变量 | 类型 | 说明 |
|------|------|------|
| `event.type` | string | 事件类型：status_changed |
| `event.from_status` | string | 前一状态 |
| `event.to_status` | string | 新状态 |
| `event.reason` | string | 错误原因码 |
| `target.id` | string | 目标 ID |
| `target.name` | string | 目标名称 |
| `target.host` | string | 主机名/IP |
| `target.port` | int | 端口 |
| `target.protocol` | string | 协议 |
| `target.tags` | list | 标签列表 |
| `target.priority` | string | 优先级 |
| `state.status` | string | 当前状态 |
| `state.avg_latency_ms` | float | 平均延迟 |
| `state.p99_latency_ms` | float | P99 延迟 |
| `state.packet_loss_pct` | float | 丢包率 (0~1) |
| `state.cert_expiry_days` | int | 证书剩余天数 |
| `state.consecutive_fails` | int | 连续失败次数 |
| `state.availability_7d` | float | 近7天可用性 (0~1) |

---

## 6. 通知渠道配置

### 6.1 钉钉机器人

```yaml
alerting:
  channels:
    - name: "运维钉钉"
      type: "dingtalk"
      config:
        webhook: "${DINGTALK_WEBHOOK_URL}"
        secret: "${DINGTALK_SECRET}"     # 加签密钥（可选但推荐）
        at_mobiles: ["13800138000"]      # @指定手机号（可选）
        at_all: false                    # 是否@所有人（P0 故障可设 true）
```

**效果预览（DOWN 事件）**：
```
🔴【ERROR】网络事件通知
━━━━━━━━━━━━━━━━━━━━━━━━
目标：核心网关 (gateway.corp.com:443)
事件：UP → DOWN
时间：2026-06-15 14:32:05
持续：0分钟（自 14:32:05）
根因：tcp_timeout
━━━━━━━━━━━━━━━━━━━━━━━━
[查看面板] [确认告警] [创建工单]
```

### 6.2 企业微信机器人

```yaml
    - name: "企业微信"
      type: "wecom"
      config:
        webhook: "${WECOM_WEBHOOK_URL}"
        mentioned_list: ["@all"]         # DOWN 事件 @所有人
```

### 6.3 飞书机器人

```yaml
    - name: "飞书"
      type: "feishu"
      config:
        webhook: "${FEISHU_WEBHOOK_URL}"
        secret: "${FEISHU_SECRET}"
```

### 6.4 邮件（SMTP）

```yaml
    - name: "邮件告警"
      type: "email"
      config:
        host: "smtp.example.com"
        port: 465
        tls: true
        username: "conmon@example.com"
        password: "${SMTP_PASSWORD}"
        from: "conmon@example.com"
        to: ["ops@example.com", "manager@example.com"]
        cc: []
```

### 6.5 Webhook（通用）

```yaml
    - name: "自定义 Webhook"
      type: "webhook"
      config:
        url: "https://your-system.com/api/alert"
        method: "POST"
        headers:
          Content-Type: "application/json"
          X-Secret: "${WEBHOOK_SECRET}"
        timeout: "10s"
        retry: 3
        # 自定义 Body 模板（Jinja2 语法）
        body_template: |
          {
            "title": "{{ target.name }} {{ event.to_status }}",
            "level": "{{ severity }}",
            "time": "{{ timestamp }}"
          }
```

### 6.6 Slack

```yaml
    - name: "Slack 运维频道"
      type: "slack"
      config:
        webhook: "${SLACK_WEBHOOK_URL}"
        channel: "#ops-alerts"           # 覆盖 webhook 默认频道（可选）
        username: "conMon"
        icon_emoji: ":warning:"
```

### 6.7 PagerDuty

```yaml
    - name: "PagerDuty"
      type: "pagerduty"
      config:
        integration_key: "${PAGERDUTY_INTEGRATION_KEY}"
        severity_map:
          DOWN: "critical"
          DEGRADED: "warning"
          FLAPPING: "warning"
```

### 6.8 短信（阿里云）

```yaml
    - name: "短信告警"
      type: "sms_aliyun"
      config:
        access_key_id: "${ALI_ACCESS_KEY_ID}"
        access_key_secret: "${ALI_ACCESS_KEY_SECRET}"
        sign_name: "conMon监控"
        template_code: "SMS_123456789"
        phone_numbers: ["13800138000", "13900139000"]
```

---

## 7. Web 控制台使用

访问 `http://your-server:8080`（或配置的 external_url）进入 Web 控制台。

### 7.1 总览大屏（Dashboard）

- **状态卡片区**：UP / DOWN / DEGRADED / 总目标数，点击可快速过滤
- **全局拓扑图**：节点颜色表示状态，连线粗细表示流量，悬停显示延迟
- **事件时间线**：最近 24 小时所有状态变更事件
- **延迟热力图**：时间轴 × 目标矩阵，识别延迟规律与异常

### 7.2 目标列表页

- 支持按名称、标签、状态、协议实时搜索过滤
- 点击行展开查看：实时延迟曲线、近期事件、探针对比
- 批量操作：批量静默、批量添加标签、批量删除

### 7.3 告警管理页

- **当前告警**：展示 FIRING 状态的告警，支持一键 ACK、静默
- **历史告警**：按时间/目标/规则过滤，查看完整告警时间线
- **告警组**：同根因的告警聚合展示，查看影响范围

### 7.4 报表页

- 选择目标、时间范围，生成 SLA 可用性报告
- 支持导出 PDF、Excel
- 趋势图：延迟趋势、可用性趋势、故障频次分布

---

## 8. CLI 命令参考

### 全局标志

```bash
conmon [全局标志] <子命令>

全局标志：
  -c, --config string    配置文件路径（默认 ./conmon.yaml 或 /etc/conmon/conmon.yaml）
  -s, --server string    API 服务器地址（默认 http://localhost:8080）
  -t, --token string     API Token（也可通过 CONMON_TOKEN 环境变量设置）
  --output string        输出格式：table/json/yaml（默认 table）
```

### 服务管理命令

```bash
conmon server start [-c config.yaml]          # 启动控制端服务
conmon server stop                             # 停止服务
conmon server status                           # 查看服务运行状态
conmon server reload                           # 热重载配置
conmon server install                          # 注册为 systemd/Windows Service
conmon server uninstall                        # 卸载系统服务
conmon probe start [-c config.yaml]           # 启动探针进程
conmon version                                 # 查看版本信息
conmon doctor                                  # 诊断常见配置问题
```

### 目标管理命令

```bash
conmon target list [--status <status>] [--tags <tag1,tag2>]
conmon target get <id-or-name>
conmon target add --name NAME --host HOST --protocol PROTO [--port PORT] [--interval INTERVAL] [--tags TAGS]
conmon target update <id> [--name NAME] [--interval INTERVAL] ...
conmon target delete <id> [--force]
conmon target probe <id>                       # 立即执行一次探测
conmon target import --file targets.yaml
conmon target export [--output targets.yaml]
conmon target silence <id> --duration 2h [--reason "维护"]
conmon target unsilence <id>
```

### 状态与日志命令

```bash
conmon status [--watch]                        # 查看所有目标状态，--watch 实时刷新
conmon status --filter DOWN                    # 只显示 DOWN 的目标
conmon logs [--target <id>] [--since 1h] [--level ERROR]
conmon events [--target <id>] [--since 1h] [--type status_changed]
conmon alerts [--status firing] [--severity critical]
```

### 告警命令

```bash
conmon alert list [--status firing]
conmon alert ack <alert-id> [--comment "已知问题，正在处理"]
conmon alert silence <id> --duration 1h
conmon alert resolve <alert-id>
```

### 报表命令

```bash
conmon report sla --target <id> --period 30d
conmon report sla --tags "生产,P0" --period 7d --output sla-report.pdf
conmon report events --since 7d --output events.csv
```

---

## 9. REST API 快速参考

所有 API 均需 Bearer Token 认证（除 `/health`、`/metrics`）。

```bash
# 获取 Token（用户名密码换取）
curl -X POST http://localhost:8080/api/v1/auth/login \
  -d '{"username":"admin","password":"your-password"}'

# 后续请求携带 Token
export TOKEN="eyJhbGci..."
curl -H "Authorization: Bearer $TOKEN" http://localhost:8080/api/v1/targets
```

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/v1/status` | 全局状态快照 |
| GET | `/api/v1/targets` | 目标列表（支持分页/筛选） |
| POST | `/api/v1/targets` | 创建目标 |
| GET | `/api/v1/targets/:id` | 目标详情 |
| PUT | `/api/v1/targets/:id` | 更新目标 |
| DELETE | `/api/v1/targets/:id` | 删除目标 |
| GET | `/api/v1/targets/:id/status` | 目标实时状态 |
| GET | `/api/v1/targets/:id/latency` | 延迟时序数据 |
| GET | `/api/v1/targets/:id/events` | 历史事件 |
| POST | `/api/v1/targets/:id/probe` | 立即触发探测 |
| POST | `/api/v1/targets/:id/silence` | 静默目标 |
| DELETE | `/api/v1/targets/:id/silence` | 取消静默 |
| GET | `/api/v1/alerts` | 告警列表 |
| POST | `/api/v1/alerts/:id/ack` | 确认告警 |
| POST | `/api/v1/silence` | 创建静默规则 |
| GET | `/api/v1/sla` | SLA 统计 |
| GET | `/api/v1/reports` | 报表列表 |
| GET | `/metrics` | Prometheus 指标 |
| GET | `/health` | 健康检查 |
| GET | `/ready` | 就绪检查 |

---

## 10. 维护窗口与静默

### 10.1 维护窗口（Maintenance Window）

维护窗口期间，目标继续探测但不发送告警：

```yaml
monitors:
  - name: "数据库"
    target: "db.example.com"
    protocol: "tcp"
    port: 5432
    maintenance:
      # 一次性维护窗口
      start: "2026-06-16T02:00:00+08:00"
      end: "2026-06-16T04:00:00+08:00"
      reason: "数据库版本升级"

      # 每周重复（每周日 02:00-04:00）
      # recurring: "0 2 * * 0"
      # duration: "2h"
```

```bash
# 通过 CLI 临时设置维护窗口
conmon target maintenance start --id target-001 --duration 2h --reason "计划维护"
conmon target maintenance end --id target-001
```

### 10.2 静默（Silence）

静默不停止探测，只抑制告警发送：

```bash
# 静默指定目标 2 小时
conmon target silence target-001 --duration 2h --reason "已知问题"

# 静默所有包含标签"测试"的目标
conmon silence create --tags "测试" --duration 24h --reason "测试环境不告警"

# 查看所有静默规则
conmon silence list

# 取消静默
conmon silence delete <silence-id>
```

---

## 11. 报表与 SLA

### 11.1 SLA 报表生成

```bash
# 单目标月度 SLA
conmon report sla \
  --target "core-gateway" \
  --start "2026-06-01" \
  --end "2026-06-30" \
  --output sla-june.pdf

# 按标签批量 SLA 报表
conmon report sla \
  --tags "生产,P0" \
  --period "last_month" \
  --output /reports/p0-sla.xlsx

# SLA 汇总到终端
conmon report sla --tags "生产" --period "last_7d"
# NAME        AVAILABILITY  MTTR   MTBF   DOWN_EVENTS
# 核心网关    99.97%        3m     72h    3
# 支付接口    99.99%        1m     168h   1
```

### 11.2 SLA 计算规则

- **可用性**：扣除维护窗口时间后计算 `UP 时间 / 总监控时间`
- **MTTR**：所有 DOWN 事件（从 DOWN 到 UP）的平均持续时长
- **MTBF**：相邻故障间隔的平均时长
- **维护窗口**：不计入可用性计算分母，也不算故障

---

*如有问题，请提交 Issue 至 [gi-conMon](https://github.com/grandinfo/gi-conMon/issues)。*
