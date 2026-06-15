# gi-conMon

> **conMon（Connection Monitor）网络连接监控工具 — 功能规格书**
>
> **版本**：v2.0 · **日期**：2026-06-15 · **状态**：完善版

---

## 目录

1. [产品概述](#1-产品概述)
2. [探测引擎](#2-探测引擎)
3. [状态机与事件检测](#3-状态机与事件检测)
4. [日志与数据持久化](#4-日志与数据持久化)
5. [告警与通知](#5-告警与通知)
6. [可视化与报表](#6-可视化与报表)
7. [API 与集成](#7-api-与集成)
8. [安全与权限](#8-安全与权限)
9. [高可用与性能](#9-高可用与性能)
10. [自动化与自愈](#10-自动化与自愈)
11. [部署与运维](#11-部署与运维)
12. [附录](#附录)

---

## 1. 产品概述

conMon（Connection Monitor）是一款面向生产环境的企业级网络连接监控工具，通过定时探测网络目标的连通性，实时捕获网络断开、重连、延迟异常等事件，并提供完整的日志记录、告警通知与可视化分析能力。

### 1.1 产品定位

| 维度 | 说明 |
|------|------|
| **目标场景** | 数据中心、云平台、混合云网络、边缘节点的连通性监控 |
| **核心能力** | 多协议探测、智能事件检测、全链路日志、多渠道告警 |
| **部署形态** | 单机二进制、容器化、Kubernetes 集群、嵌入式设备 |
| **用户角色** | SRE/运维工程师、网络管理员、DevOps 团队 |

### 1.2 功能全景

```
+------------------------------------------------------------------+
|                          conMon 架构                               |
+--------------+--------------+--------------+---------------------+
|    探测层     |    分析层     |    处理层     |       展示层         |
|              |              |              |                      |
| • ICMP Ping  | • 状态机      | • 日志存储    | • Web Dashboard      |
| • TCP/UDP    | • FLAPPING   | • 时序数据库  | • CLI 实时看板       |
| • HTTP/HTTPS | • 根因分析    | • 事件通知    | • Grafana 插件       |
| • DNS/TLS    | • 基线学习    | • Webhook    | • 报表导出           |
| • WebSocket  | • 依赖拓扑    | • 邮件/IM    | • REST API           |
| • 自定义插件  | • 批量识别    | • 自动修复    | • Prometheus Exporter|
+--------------+--------------+--------------+---------------------+
```

---

## 2. 探测引擎

### 2.1 多协议探测

| 协议 | 用途 | 可配置参数 |
|------|------|-----------|
| **ICMP** | Ping 基础连通性 | 包大小、TTL、不允许分片 |
| **TCP SYN** | 端口连通性 | 目标端口、连接超时、握手模式 |
| **TCP CONNECT** | 全连接探测 | 目标端口、发送/接收超时 |
| **UDP** | UDP 服务探测 | 目标端口、发送载荷、期望响应 |
| **HTTP** | Web 服务健康检查 | URL、Method、Headers、Body、期望状态码 |
| **HTTPS** | 加密 Web 服务 | TLS 版本、证书校验、SNI、证书过期阈值 |
| **DNS** | DNS 解析服务 | 查询类型(A/AAAA/MX/TXT/NS)、目标 DNS 服务器 |
| **TLS** | 证书与加密层 | 端口、证书过期预警天数、OCSP 校验 |
| **WebSocket** | 实时通信服务 | 子协议、自定义握手 Headers |
| **gRPC** | 微服务健康检查 | Service 名称、方法、元数据 |

### 2.2 探测方式

| 方式 | 说明 |
|------|------|
| **直连探测** | 直接从探针节点向目标发起探测，最常用 |
| **代理探测** | 通过 HTTP/SOCKS5 代理连接目标，适用于内网穿透场景 |
| **跳板机探测** | 通过 SSH Bastion 跳转至目标网络再探测 |
| **双向探测** | 两端部署 Agent 互相探测，用于 VPN/专线质量评估 |

### 2.3 探测调度

| 调度模式 | 说明 |
|---------|------|
| **固定间隔** | 按秒/分/小时周期探测，如 `interval: 30s` |
| **Cron 表达式** | 复杂调度，如 `0 */6 * * *`（每6小时） |
| **智能动态间隔** | 目标正常时按默认间隔，DOWN 时自动缩短至 5s 加速检测恢复 |

### 2.4 探测控制

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `timeout` | 5s | 单次探测超时时间 |
| `retries` | 3 | 失败重试次数 |
| `retry_interval` | 指数退避 | 重试间隔策略（固定/线性退避/指数退避） |
| `concurrency` | 100 | 全局并发探测数限制 |
| `priority` | normal | 探测队列优先级（high/normal/low） |

### 2.5 链路诊断

| 功能 | 说明 |
|------|------|
| **MTR 集成** | 目标 DOWN 时自动执行路由追踪，定位故障节点 |
| **地理位置感知** | 多地域探针部署，对比不同运营商（电信/联通/移动/海外）的连通性差异 |
| **探测包定制** | 自定义 HTTP Header（User-Agent、Authorization）、自定义 ICMP 包大小 |

---

## 3. 状态机与事件检测

### 3.1 状态定义

```
                    +---------+
          +-------->| UNKNOWN |<--------+
          |         +----+----+         |
          |              |              |
          | 首次探测成功  | 首次探测      |
          |              v              |
          |         +----+----+         |
          +---------|    UP     |---------+
          恢复成功   +----+----+   连续失败
                     |         |
          连续成功    |         | 连续失败 N 次
                     v         v
                  +----+----+----+
                  |    DOWN      |
                  +----+----+----+
                       |
                       | 频繁变更
                       v
                  +----+----+
                  | FLAPPING |
                  +----------+
```

| 状态 | 说明 |
|------|------|
| **UNKNOWN** | 初始状态，尚未获取到探测结果 |
| **UP** | 目标正常响应，服务可用 |
| **DOWN** | 目标连续探测失败，判定为不可用 |
| **FLAPPING** | 短时间内频繁上下线，网络不稳定 |
| **DEGRADED** | 响应正常但延迟过高或丢包严重，服务降级 |
| **MAINTENANCE** | 进入维护窗口，暂停告警 |
| **SILENT** | 手动静默，持续探测但不通知 |

### 3.2 事件类型

| 事件 | 触发条件 | 处理策略 |
|------|---------|---------|
| **UP → DOWN** | 连续 N 次探测失败（默认 3 次） | 立即告警，启动加速探测模式 |
| **DOWN → UP** | 连续 N 次探测成功（默认 2 次） | 发送恢复通知，记录故障持续时间 |
| **→ DEGRADED** | 响应成功但延迟 > 阈值 或丢包率 > 阈值 | 黄色预警，不标记为 DOWN |
| **→ FLAPPING** | 10 分钟内状态变更 ≥ 5 次 | 进入抖动抑制模式，合并告警 |
| **→ MAINTENANCE** | 到达预设维护窗口 | 暂停告警，仅记录日志 |
| **→ SILENT** | 管理员手动静默 | 持续探测，抑制所有通知 |

### 3.3 智能降噪

| 策略 | 说明 |
|------|------|
| **依赖抑制** | 若上游路由器 DOWN，下游所有目标自动抑制告警，避免告警风暴 |
| **批量故障识别** | 当 >30% 目标同时 DOWN，判定为全局网络故障，发送单次汇总告警 |
| **告警去重** | 相同问题 5 分钟内不重复发送，仅追加更新时间戳 |
| **Flapping 抑制** | FLAPPING 状态下告警间隔延长至 15 分钟，减少噪音 |

---

## 4. 日志与数据持久化

### 4.1 日志分级

| 级别 | 说明 | 保留策略 |
|------|------|---------|
| **CRITICAL** | 核心服务不可用、存储满、配置严重错误 | 立即持久化 + 实时告警，保留 180 天 |
| **ERROR** | 目标 DOWN 事件、探测异常、通知发送失败 | 持久化 90 天 |
| **WARN** | 高延迟、丢包、证书即将过期、FLAPPING | 持久化 30 天 |
| **INFO** | 状态变更、配置重载、服务启停 | 持久化 14 天 |
| **DEBUG** | 单次探测详情、HTTP 响应码、TCP 握手细节 | 内存缓冲，不默认持久化 |

### 4.2 结构化日志格式

```json
{
  "ts": "2026-06-15T14:32:05.123+08:00",
  "level": "ERROR",
  "event": "status_changed",
  "target": {
    "id": "target-001",
    "name": "核心网关",
    "host": "gateway.corp.com",
    "port": 443,
    "protocol": "https"
  },
  "from": "UP",
  "to": "DOWN",
  "reason": "tcp_timeout",
  "duration_ms": 5000,
  "probe": {
    "seq": 1523,
    "location": "北京-电信",
    "node_id": "probe-bj-01"
  },
  "tags": ["生产环境", "核心链路", "支付网关"],
  "meta": {
    "consecutive_failures": 3,
    "last_success": "2026-06-15T14:30:45.000+08:00",
    "mtr_summary": "丢包始于 192.168.3.1 (核心路由器)"
  }
}
```

### 4.3 存储后端

| 后端 | 适用场景 | 数据类型 | 保留策略 |
|------|---------|---------|---------|
| **本地日志文件** | 文本审计、快速 grep 排查 | 文本日志 | 自动轮转，保留 30 天 |
| **SQLite** | 轻量级单机部署 | 事件、配置 | 可选按大小清理 |
| **InfluxDB / TDengine** | 时序数据趋势分析 | 延迟、丢包率、探测结果 | 原始精度 7 天，1h 精度 1 年 |
| **PostgreSQL / MySQL** | 企业级事件记录、SLA 报表 | 事件、告警、审计 | 热数据 90 天，冷数据归档 |
| **Prometheus Remote Write** | 云原生环境指标对接 | 指标数据 | 对接现有监控体系 |
| **对象存储 (S3/OSS)** | 冷数据归档、月度报告导出 | 压缩日志、报表文件 | 永久保留 |

### 4.4 日志轮转

| 策略 | 说明 |
|------|------|
| **按时间轮转** | 每日/每周自动生成新日志文件 |
| **按大小轮转** | 单文件达到指定大小（如 100MB）后切割 |
| **自动压缩** | 历史日志自动 gzip 压缩，节省磁盘空间 |
| **磁盘保护** | 磁盘使用率 >85% 时自动删除最旧日志，防止占满 |

---

## 5. 告警与通知

### 5.1 通知渠道

| 渠道 | 能力 | 消息格式 |
|------|------|---------|
| **Webhook** | 自定义 HTTP 回调，支持签名验证 | JSON Payload，模板变量替换 |
| **邮件 (SMTP)** | HTML/纯文本、附件支持 | 含状态变更摘要和趋势图 |
| **企业微信** | Markdown 消息、@指定成员 | 红色（DOWN）/绿色（UP）状态卡片 |
| **钉钉** | Markdown、ActionCard | 一键确认/静默按钮 |
| **飞书** | 富文本、交互式卡片 | 内嵌延迟趋势图 |
| **Slack** | Block Kit 富媒体消息 | 含 Grafana 面板链接 |
| **短信 (SMS)** | 仅关键告警 | 精简文本，70 字以内 |
| **电话 (语音)** | P0 级故障语音通知 | TTS 合成故障描述 |
| **PagerDuty** | 专业告警编排 | 自动分级、值班表、升级策略 |
| **OpsGenie** | 企业告警管理 | 调度、升级、报告 |

### 5.2 告警模板引擎

支持 Jinja2 模板语法，内置变量：

```jinja2
【{{ severity }}】网络事件通知
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
目标：{{ target.name }} ({{ target.host }}:{{ target.port }})
事件：{{ from }} → {{ to }}
时间：{{ timestamp }}
持续：{{ duration }} (自 {{ since }})
探针：{{ probe.location }}
根因：{{ reason }}
标签：{{ tags | join(', ') }}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[查看面板] {{ grafana_url }}
[确认告警] {{ ack_url }}
[创建工单] {{ jira_url }}
```

### 5.3 告警行为

| 功能 | 说明 |
|------|------|
| **告警升级** | L1(5 分钟未 ACK) → L2(15 分钟) → L3(30 分钟 + 电话通知) |
| **告警合并** | 同一目标多次事件合并为线程式通知，附完整时间线 |
| **告警抑制** | 全局静默、目标级静默、维护窗口、依赖链抑制 |
| **告警确认 (ACK)** | 用户确认后暂停升级，记录处理人和处理时间 |
| **告警关联** | 同一根因引发的多个告警自动关联为"事件组" |

### 5.4 通知策略配置示例

```yaml
alerting:
  rules:
    - name: "核心服务 DOWN"
      condition: "status == DOWN and target.priority == critical"
      channels: [webhook, dingtalk, sms]
      escalate_after: "5m"

    - name: "高延迟预警"
      condition: "latency_p99 > 500ms"
      channels: [email]
      throttle: "15m"

    - name: "证书即将过期"
      condition: "tls_cert_expiry_days < 30"
      channels: [email, slack]
      schedule: "daily 09:00"
```

---

## 6. 可视化与报表

### 6.1 实时监控看板

| 视图 | 内容描述 |
|------|---------|
| **全局拓扑图** | 网络拓扑可视化，节点颜色标识状态（绿/黄/红），连线显示延迟 |
| **状态总览** | 健康/告警/故障目标数量统计，整体可用性百分比 |
| **延迟热力图** | 时间轴 × 目标矩阵，颜色深浅表示延迟高低 |
| **事件时间线** | 瀑布式展示近期所有状态变更事件，支持筛选 |
| **地域对比** | 多探针延迟对比雷达图，识别地域性网络问题 |
| **终端 CLI** | `conmon status` 实时刷新表格，支持搜索/过滤/排序 |

### 6.2 报表系统

| 报表类型 | 内容 | 导出格式 |
|---------|------|---------|
| **SLA 可用性报告** | 各目标月度/季度可用性百分比、MTTR、MTBF | PDF、Excel |
| **故障分析报告** | 故障频次、持续时间分布、根因分类 TOP10 | PDF、HTML |
| **趋势分析报告** | 延迟趋势、丢包趋势、容量规划建议 | PDF、PNG 图表 |
| **合规审计报告** | 完整探测日志、告警记录、操作审计追踪 | PDF、CSV |
| **自定义报表** | 拖拽选择指标、时间范围、目标分组 | Excel、PDF |

### 6.3 SLA 指标计算

| 指标 | 计算公式 |
|------|---------|
| **可用性 (Availability)** | `UP 时间 / (UP 时间 + DOWN 时间) × 100%` |
| **MTTR**（平均修复时间） | 所有故障恢复时间的平均值 |
| **MTBF**（平均故障间隔） | 总运行时间 / 故障次数 |
| **MTTF**（平均无故障时间） | 故障间隔时间的平均值 |

---

## 7. API 与集成

### 7.1 RESTful API

| 方法 | 路径 | 说明 |
|------|------|------|
| `GET` | `/api/v1/status` | 全局状态快照 |
| `GET` | `/api/v1/targets` | 目标列表（支持分页/筛选/标签过滤） |
| `POST` | `/api/v1/targets` | 动态添加监控目标 |
| `GET` | `/api/v1/targets/{id}` | 目标详情 |
| `PUT` | `/api/v1/targets/{id}` | 修改目标配置 |
| `DELETE` | `/api/v1/targets/{id}` | 删除目标 |
| `GET` | `/api/v1/targets/{id}/status` | 单个目标实时状态 |
| `GET` | `/api/v1/targets/{id}/logs` | 历史事件查询 |
| `GET` | `/api/v1/targets/{id}/latency` | 延迟时序数据 |
| `POST` | `/api/v1/ack/{alert_id}` | 确认告警 |
| `POST` | `/api/v1/silence` | 创建静默规则 |
| `GET` | `/api/v1/sla` | SLA 统计查询 |
| `GET` | `/api/v1/reports` | 报表列表与下载 |
| `GET` | `/metrics` | Prometheus Exporter 格式 |
| `GET` | `/health` | 健康检查端点 |
| `GET` | `/ready` | 就绪检查（K8s） |

### 7.2 插件系统

| 扩展点 | 说明 |
|-------|------|
| **自定义探测器** | Go/Python 插件接口，实现特殊协议探测（MQTT、Redis、Kafka、JDBC） |
| **自定义通知器** | 接入企业内部 IM、工单系统 |
| **自定义存储** | 对接企业内部时序数据库 |
| **自定义决策器** | 替换内置状态机逻辑 |
| **Hook 脚本** | 事件触发时执行本地脚本（如自动切换 DNS、重启服务） |

### 7.3 第三方生态集成

| 系统 | 集成方式 |
|------|---------|
| **Prometheus** | `/metrics` 端点 + Alertmanager 联动 |
| **Grafana** | 官方 Dashboard 模板，数据源直连 |
| **Zabbix** | Zabbix Sender / Trapper 协议兼容 |
| **Nagios** | NRPE / NSCA 兼容模式 |
| **ELK Stack** | Filebeat 采集 JSON 日志，自动解析 |
| **Kubernetes** | CRD 定义监控目标，Operator 部署，Sidecar 模式 |
| **Terraform** | Provider 管理监控目标与配置 |
| **Ansible** | Role 批量部署探针、下发配置 |

---

## 8. 安全与权限

### 8.1 访问控制

| 功能 | 说明 |
|------|------|
| **RBAC 权限模型** | 管理员 / 运维 / 只读 三级角色分离 |
| **API Token** | 细粒度 Token 授权，支持按资源、操作类型限定权限 |
| **IP 白名单** | API 访问 IP 限制，探针注册 IP 校验 |
| **审计日志** | 所有配置变更、手动操作、登录行为完整记录 |

### 8.2 传输与存储安全

| 功能 | 说明 |
|------|------|
| **TLS 全链路加密** | 探针↔控制端、通知 Webhook、存储连接均强制 TLS 1.2+ |
| **敏感信息加密** | 密码、Token、证书私钥 AES-256-GCM 加密存储 |
| **证书管理** | 内置 CA，自动签发探针证书，支持证书自动轮换 |
| **国密支持** | 可选 SM2/SM3/SM4 算法套件 |

---

## 9. 高可用与性能

### 9.1 架构特性

| 特性 | 说明 |
|------|------|
| **集群模式** | 控制端多活部署，PostgreSQL/etcd 共享状态 |
| **探针自治** | 探针与控制端断联时，本地缓存配置继续探测，恢复后批量上报 |
| **水平扩展** | 目标数量增长时，自动分片到多个探针节点 |
| **配置热同步** | etcd / Consul 配置中心，变更秒级同步全集群 |
| **无单点故障** | 控制端、存储、通知通道均可配置主备 |

### 9.2 性能指标

| 指标 | 数值 |
|------|------|
| **单机目标承载** | 5,000+ 监控目标 |
| **探测吞吐** | 100,000 QPS |
| **状态变更检测延迟** | P99 < 10ms |
| **配置同步延迟** | < 1s 全局生效 |
| **日志写入吞吐** | 50,000 条/秒 |

---

## 10. 自动化与自愈

### 10.1 自动化能力

| 功能 | 说明 |
|------|------|
| **Hook 脚本** | 事件触发自动执行本地脚本：重启服务、切换 VIP、通知云平台换 IP |
| **工作流引擎** | 可视化编排：检测 DOWN → 执行诊断 → 尝试修复 → 人工确认 |
| **DNS 自动切换** | 探测到服务 DOWN 时，自动修改 DNS 记录指向备用节点 |
| **云厂商联动** | 集成 AWS/Azure/阿里云 API，自动重启实例、切换负载均衡 |

### 10.2 智能能力

| 功能 | 说明 |
|------|------|
| **故障注入测试** | 内置混沌测试：模拟丢包、延迟、断开，验证告警灵敏度 |
| **基线学习** | 自动学习正常延迟/丢包基线，动态调整告警阈值 |
| **根因分析** | 基于依赖拓扑和批量故障模式，自动推断故障根因 |
| **预测性告警** | 基于趋势预测，在故障发生前提前预警 |

---

## 11. 部署与运维

### 11.1 部署模式

| 模式 | 说明 | 适用场景 |
|------|------|---------|
| **二进制单文件** | 单 `conmon` 二进制，零依赖，`./conmon -c config.yml` 启动 | 边缘节点、嵌入式设备 |
| **Docker** | `docker run conmon/conmon:latest`，内置健康检查 | 开发测试、小型部署 |
| **Docker Compose** | 一键部署 conMon + PostgreSQL + Grafana | 中小型生产环境 |
| **Kubernetes** | Helm Chart 安装，支持 HPA 自动扩缩容探针 | 大型云原生环境 |
| **systemd** | 自动生成 systemd unit 文件 | Linux 服务器 |
| **Windows Service** | 原生 Windows 服务注册 | Windows 服务器 |
| **嵌入式 ARM** | ARM64 架构支持，树莓派/边缘网关 | IoT、边缘计算 |

### 11.2 运维工具

| 工具 | 说明 |
|------|------|
| **CLI 管理工具** | `conmon` 命令行：目标管理、配置查看、日志查询、状态检查 |
| **配置热重载** | `kill -HUP` 或 API 调用，配置修改无需重启 |
| **健康检查** | `/health` 存活检查，`/ready` 就绪检查 |
| **性能剖析** | 内置 pprof，支持 CPU/内存/协程分析 |
| **故障排查** | `conmon doctor` 自动诊断常见配置和运行问题 |

### 11.3 配置文件示例

```yaml
# conmon.yaml 主配置文件
server:
  bind: "0.0.0.0:8080"
  tls:
    enabled: true
    cert_file: "/etc/conmon/server.crt"
    key_file: "/etc/conmon/server.key"

storage:
  type: "postgresql"
  dsn: "postgres://conmon:${DB_PASSWORD}@localhost/conmon"
  retention:
    hot: "90d"
    cold: "1y"

probes:
  - name: "北京-电信"
    id: "probe-bj-01"
    location: "北京"
    isp: "电信"
    tags: ["华北", "电信"]
  - name: "上海-联通"
    id: "probe-sh-01"
    location: "上海"
    isp: "联通"
    tags: ["华东", "联通"]

monitors:
  - name: "核心网关"
    target: "gateway.corp.com"
    protocol: "https"
    port: 443
    interval: "30s"
    timeout: "5s"
    retries: 3
    probes: ["probe-bj-01", "probe-sh-01"]
    alert_when:
      down: true
      latency_gt: "200ms"
      packet_loss_gt: "10%"
    tags: ["生产环境", "核心链路", "P0"]
    dependencies: ["核心路由器"]

  - name: "DNS 服务"
    target: "8.8.8.8"
    protocol: "dns"
    port: 53
    dns_query:
      type: "A"
      domain: "example.com"
    interval: "1m"
    tags: ["基础设施"]

  - name: "数据库主节点"
    target: "db-master.internal"
    protocol: "tcp"
    port: 5432
    interval: "10s"
    tags: ["生产环境", "数据库"]
    hooks:
      on_down: "/usr/local/bin/failover.sh"

alerting:
  channels:
    - name: "运维钉钉"
      type: "dingtalk"
      webhook: "${DINGTALK_WEBHOOK_URL}"
      secret: "${DINGTALK_SECRET}"
    - name: "企业微信"
      type: "wecom"
      webhook: "${WECOM_WEBHOOK_URL}"
    - name: "PagerDuty"
      type: "pagerduty"
      integration_key: "${PD_KEY}"

  rules:
    - name: "P0 故障"
      condition: "target.tags contains 'P0' and status == DOWN"
      channels: ["运维钉钉", "企业微信", "PagerDuty"]
      escalate_after: "5m"

    - name: "证书过期"
      condition: "tls_cert_expiry_days < 30"
      channels: ["企业微信"]
      throttle: "24h"

webhook_templates:
  - name: "自定义工单"
    url: "https://jira.corp.com/api/issue"
    headers:
      Authorization: "Bearer ${JIRA_TOKEN}"
    body: |
      {
        "project": "NET",
        "summary": "[conMon] {{ target.name }} {{ to }}",
        "description": "目标：{{ target.host }}:{{ target.port }}\n事件：{{ from }} -> {{ to }}\n时间：{{ timestamp }}",
        "priority": "{{ 'High' if to == 'DOWN' else 'Medium' }}"
      }
```

---

## 附录

### A. 术语表

| 术语 | 说明 |
|------|------|
| **Probe（探针）** | 部署在目标网络的探测节点，负责实际执行探测任务 |
| **Target（目标）** | 被监控的网络端点，如 IP、域名、URL |
| **SLA** | Service Level Agreement，服务等级协议，通常以可用性百分比衡量 |
| **MTTR** | Mean Time To Repair，平均修复时间 |
| **MTBF** | Mean Time Between Failures，平均故障间隔 |
| **FLAPPING** | 网络抖动，指目标在短时间内频繁上下线 |
| **ACK** | Acknowledgment，告警确认 |

### B. 版本历史

| 版本 | 日期 | 变更内容 |
|------|------|---------|
| v1.0 | 2026-05-01 | 初始版本，基础探测与日志功能 |
| v2.0 | 2026-06-15 | 新增状态机、多协议探测、告警通知、可视化、API、插件系统 |

---

*本文档由 conMon 产品团队维护，如有问题请联系运维团队。*
