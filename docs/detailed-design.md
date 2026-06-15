# conMon 详细设计文档

**版本**：v2.0 · **日期**：2026-06-15 · **状态**：正式版

---

## 目录

1. [数据模型设计](#1-数据模型设计)
2. [探测引擎详细设计](#2-探测引擎详细设计)
3. [状态机详细设计](#3-状态机详细设计)
4. [告警引擎详细设计](#4-告警引擎详细设计)
5. [存储层详细设计](#5-存储层详细设计)
6. [API 层详细设计](#6-api-层详细设计)
7. [配置管理详细设计](#7-配置管理详细设计)
8. [插件系统详细设计](#8-插件系统详细设计)
9. [自动化与自愈详细设计](#9-自动化与自愈详细设计)
10. [错误处理与可观测性](#10-错误处理与可观测性)

---

## 1. 数据模型设计

### 1.1 核心领域模型

#### Target（监控目标）

```go
// Target 代表一个被监控的网络端点
type Target struct {
    ID           string            `json:"id"`           // 全局唯一ID，格式: target-<uuid>
    Name         string            `json:"name"`         // 人类可读名称
    Host         string            `json:"host"`         // IP 或 域名
    Port         int               `json:"port"`         // 目标端口（ICMP 可为 0）
    Protocol     Protocol          `json:"protocol"`     // 探测协议
    Interval     Duration          `json:"interval"`     // 探测间隔
    Timeout      Duration          `json:"timeout"`      // 单次超时
    Retries      int               `json:"retries"`      // 失败重试次数
    Priority     Priority          `json:"priority"`     // 优先级 high/normal/low
    Tags         []string          `json:"tags"`         // 自定义标签
    Dependencies []string          `json:"dependencies"` // 依赖目标 ID 列表
    ProbeIDs     []string          `json:"probe_ids"`    // 指定探针节点
    AlertConfig  *AlertConfig      `json:"alert_config"` // 告警配置
    ProbeConfig  map[string]any    `json:"probe_config"` // 协议特定配置
    Hooks        *HookConfig       `json:"hooks"`        // 事件钩子
    Maintenance  *MaintenanceWindow `json:"maintenance"` // 维护窗口
    CreatedAt    time.Time         `json:"created_at"`
    UpdatedAt    time.Time         `json:"updated_at"`
    CreatedBy    string            `json:"created_by"`
}

// AlertConfig 告警触发条件
type AlertConfig struct {
    DownThreshold      int      `json:"down_threshold"`       // 判定 DOWN 的连续失败次数，默认 3
    RecoveryThreshold  int      `json:"recovery_threshold"`   // 判定恢复的连续成功次数，默认 2
    LatencyWarnMs      int64    `json:"latency_warn_ms"`      // 延迟预警阈值（ms）
    PacketLossWarnPct  float64  `json:"packet_loss_warn_pct"` // 丢包率预警阈值（0~1）
    AlertChannels      []string `json:"alert_channels"`       // 告警渠道名称列表
    SilenceUntil       *time.Time `json:"silence_until"`      // 静默截止时间
}

// MaintenanceWindow 维护窗口
type MaintenanceWindow struct {
    Start    time.Time `json:"start"`
    End      time.Time `json:"end"`
    Recurring string   `json:"recurring"` // cron 表达式，留空表示一次性
    Reason   string    `json:"reason"`
}
```

#### ProbeResult（探测结果）

```go
// ProbeResult 单次探测的原始结果
type ProbeResult struct {
    TargetID    string        `json:"target_id"`
    ProbeNodeID string        `json:"probe_node_id"`
    Seq         int64         `json:"seq"`          // 探测序列号（单调递增）
    Timestamp   time.Time     `json:"timestamp"`
    Success     bool          `json:"success"`
    LatencyMs   float64       `json:"latency_ms"`
    StatusCode  int           `json:"status_code"`  // HTTP 状态码，TCP 连接成功=1
    ErrorCode   string        `json:"error_code"`   // tcp_timeout / dns_error / tls_error 等
    ErrorMsg    string        `json:"error_msg"`
    Detail      map[string]any `json:"detail"`      // 协议特定详情（TLS证书信息、DNS 解析记录等）
}
```

#### TargetState（目标状态）

```go
// TargetState 目标当前状态（内存热数据）
type TargetState struct {
    TargetID           string      `json:"target_id"`
    Status             Status      `json:"status"`             // UP/DOWN/DEGRADED/FLAPPING/UNKNOWN/MAINTENANCE/SILENT
    LastStatus         Status      `json:"last_status"`
    StatusChangedAt    time.Time   `json:"status_changed_at"`
    LastProbeAt        time.Time   `json:"last_probe_at"`
    LastSuccessAt      time.Time   `json:"last_success_at"`
    ConsecutiveFails   int         `json:"consecutive_fails"`
    ConsecutiveSuccess int         `json:"consecutive_success"`
    AvgLatencyMs       float64     `json:"avg_latency_ms"`     // 近 5 分钟平均延迟
    P99LatencyMs       float64     `json:"p99_latency_ms"`
    PacketLossPct      float64     `json:"packet_loss_pct"`    // 近 5 分钟丢包率
    CertExpiryDays     int         `json:"cert_expiry_days"`   // TLS 证书剩余天数，-1 表示不适用
    Availability7d     float64     `json:"availability_7d"`    // 近 7 天可用性
    FlapCount10m       int         `json:"flap_count_10m"`     // 近 10 分钟状态变更次数
    SuppressedBy       string      `json:"suppressed_by"`      // 被哪个上游依赖抑制
}
```

#### Event（事件记录）

```go
// Event 状态变更事件，持久化到数据库
type Event struct {
    ID          string         `json:"id"`            // event-<uuid>
    TargetID    string         `json:"target_id"`
    ProbeNodeID string         `json:"probe_node_id"`
    Type        EventType      `json:"type"`          // status_changed / degraded / flapping / cert_expiry
    FromStatus  Status         `json:"from_status"`
    ToStatus    Status         `json:"to_status"`
    Reason      string         `json:"reason"`        // 机器可读的原因码
    Message     string         `json:"message"`       // 人类可读描述
    DurationMs  int64          `json:"duration_ms"`   // 上一状态持续时长
    Tags        []string       `json:"tags"`
    Meta        map[string]any `json:"meta"`          // 额外上下文（连续失败次数、MTR 摘要等）
    Timestamp   time.Time      `json:"timestamp"`
    Acknowledged bool          `json:"acknowledged"`
    AckedBy     string         `json:"acked_by"`
    AckedAt     *time.Time     `json:"acked_at"`
    AlertIDs    []string       `json:"alert_ids"`     // 关联的告警 ID
}
```

#### Alert（告警记录）

```go
// Alert 一次告警的完整记录
type Alert struct {
    ID          string        `json:"id"`            // alert-<uuid>
    EventID     string        `json:"event_id"`
    TargetID    string        `json:"target_id"`
    RuleName    string        `json:"rule_name"`
    Severity    Severity      `json:"severity"`      // critical/error/warn/info
    Status      AlertStatus   `json:"status"`        // firing/resolved/acknowledged/silenced
    Title       string        `json:"title"`
    Body        string        `json:"body"`          // 渲染后的通知正文
    Channels    []string      `json:"channels"`      // 已发送的渠道
    SentAt      time.Time     `json:"sent_at"`
    ResolvedAt  *time.Time    `json:"resolved_at"`
    EscalationLevel int       `json:"escalation_level"` // 当前升级层级 1/2/3
    NextEscalateAt  *time.Time `json:"next_escalate_at"`
    GroupID     string        `json:"group_id"`      // 同根因告警组 ID
}
```

#### ProbeNode（探针节点）

```go
// ProbeNode 注册在系统中的探针节点信息
type ProbeNode struct {
    ID          string            `json:"id"`           // probe-<uuid> 或自定义
    Name        string            `json:"name"`
    Location    string            `json:"location"`
    ISP         string            `json:"isp"`
    Tags        []string          `json:"tags"`
    IPAddress   string            `json:"ip_address"`
    Version     string            `json:"version"`      // conmon-probe 版本
    Status      ProbeNodeStatus   `json:"status"`       // online/offline/degraded
    LastHeartbeat time.Time       `json:"last_heartbeat"`
    AssignedTargets int           `json:"assigned_targets"` // 当前分配的目标数
    Capabilities []string         `json:"capabilities"` // 支持的协议列表
    RegisteredAt time.Time        `json:"registered_at"`
}
```

### 1.2 数据库 Schema

#### PostgreSQL 核心表

```sql
-- 监控目标表
CREATE TABLE targets (
    id              VARCHAR(64)  PRIMARY KEY,
    name            VARCHAR(255) NOT NULL,
    host            VARCHAR(255) NOT NULL,
    port            INTEGER,
    protocol        VARCHAR(32)  NOT NULL,
    interval_sec    INTEGER      NOT NULL DEFAULT 30,
    timeout_ms      INTEGER      NOT NULL DEFAULT 5000,
    retries         INTEGER      NOT NULL DEFAULT 3,
    priority        VARCHAR(16)  NOT NULL DEFAULT 'normal',
    tags            TEXT[]       DEFAULT '{}',
    dependencies    TEXT[]       DEFAULT '{}',
    probe_ids       TEXT[]       DEFAULT '{}',
    alert_config    JSONB,
    probe_config    JSONB,
    hooks           JSONB,
    maintenance     JSONB,
    enabled         BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    created_by      VARCHAR(128)
);

-- 标签索引（GIN 支持 @> 操作符快速查询）
CREATE INDEX idx_targets_tags  ON targets USING GIN (tags);
CREATE INDEX idx_targets_host  ON targets (host);
CREATE INDEX idx_targets_proto ON targets (protocol);

-- 事件表
CREATE TABLE events (
    id              VARCHAR(64)   PRIMARY KEY,
    target_id       VARCHAR(64)   NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
    probe_node_id   VARCHAR(64),
    type            VARCHAR(32)   NOT NULL,
    from_status     VARCHAR(32),
    to_status       VARCHAR(32)   NOT NULL,
    reason          VARCHAR(128),
    message         TEXT,
    duration_ms     BIGINT,
    tags            TEXT[]        DEFAULT '{}',
    meta            JSONB,
    timestamp       TIMESTAMPTZ   NOT NULL,
    acknowledged    BOOLEAN       NOT NULL DEFAULT FALSE,
    acked_by        VARCHAR(128),
    acked_at        TIMESTAMPTZ
);

CREATE INDEX idx_events_target   ON events (target_id, timestamp DESC);
CREATE INDEX idx_events_type     ON events (type, timestamp DESC);
CREATE INDEX idx_events_ts       ON events (timestamp DESC);

-- 告警表
CREATE TABLE alerts (
    id                  VARCHAR(64)  PRIMARY KEY,
    event_id            VARCHAR(64)  REFERENCES events(id),
    target_id           VARCHAR(64)  NOT NULL REFERENCES targets(id),
    rule_name           VARCHAR(255),
    severity            VARCHAR(32)  NOT NULL,
    status              VARCHAR(32)  NOT NULL DEFAULT 'firing',
    title               VARCHAR(512),
    body                TEXT,
    channels            TEXT[]       DEFAULT '{}',
    sent_at             TIMESTAMPTZ,
    resolved_at         TIMESTAMPTZ,
    escalation_level    INTEGER      NOT NULL DEFAULT 1,
    next_escalate_at    TIMESTAMPTZ,
    group_id            VARCHAR(64)
);

CREATE INDEX idx_alerts_target  ON alerts (target_id, sent_at DESC);
CREATE INDEX idx_alerts_status  ON alerts (status);
CREATE INDEX idx_alerts_group   ON alerts (group_id);

-- 探针节点表
CREATE TABLE probe_nodes (
    id                  VARCHAR(64)  PRIMARY KEY,
    name                VARCHAR(255),
    location            VARCHAR(128),
    isp                 VARCHAR(64),
    tags                TEXT[]       DEFAULT '{}',
    ip_address          INET,
    version             VARCHAR(32),
    status              VARCHAR(32)  NOT NULL DEFAULT 'offline',
    last_heartbeat      TIMESTAMPTZ,
    assigned_targets    INTEGER      DEFAULT 0,
    capabilities        TEXT[]       DEFAULT '{}',
    registered_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- 审计日志表
CREATE TABLE audit_logs (
    id          BIGSERIAL    PRIMARY KEY,
    timestamp   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    user_id     VARCHAR(128),
    action      VARCHAR(64)  NOT NULL, -- create_target / delete_target / ack_alert / ...
    resource    VARCHAR(64),           -- targets / alerts / probes
    resource_id VARCHAR(64),
    ip_address  INET,
    user_agent  TEXT,
    request     JSONB,
    response_code INTEGER
);

CREATE INDEX idx_audit_ts   ON audit_logs (timestamp DESC);
CREATE INDEX idx_audit_user ON audit_logs (user_id, timestamp DESC);

-- SLA 日统计预聚合表（加速报表查询）
CREATE TABLE sla_daily (
    target_id       VARCHAR(64)  NOT NULL,
    date            DATE         NOT NULL,
    total_seconds   INTEGER      NOT NULL,
    up_seconds      INTEGER      NOT NULL DEFAULT 0,
    down_seconds    INTEGER      NOT NULL DEFAULT 0,
    event_count     INTEGER      NOT NULL DEFAULT 0,
    avg_latency_ms  FLOAT,
    p99_latency_ms  FLOAT,
    PRIMARY KEY (target_id, date)
);
```

#### InfluxDB Measurements

```
# 探测原始指标（高频写入，保留 7 天）
measurement: probe_result
tags:
  - target_id
  - probe_node_id
  - protocol
  - location
  - status (success/failure)
fields:
  - latency_ms (float)
  - status_code (int)
  - cert_expiry_days (int, nullable)
  - packet_loss_pct (float, UDP/ICMP)
  - dns_resolve_ms (float, DNS)
timestamp: nanosecond precision

# 目标状态指标（保留 1 年，1h 降采样）
measurement: target_status
tags:
  - target_id
  - status (UP/DOWN/DEGRADED/FLAPPING)
fields:
  - value (int, 1=UP 0=DOWN)
  - consecutive_fails (int)
  - availability (float, 0-1)

# 聚合统计（保留 1 年，1h 精度）
measurement: target_metrics_1h
tags:
  - target_id
  - probe_node_id
fields:
  - latency_mean_ms (float)
  - latency_p50_ms (float)
  - latency_p95_ms (float)
  - latency_p99_ms (float)
  - latency_max_ms (float)
  - success_rate (float, 0-1)
  - probe_count (int)
```

---

## 2. 探测引擎详细设计

### 2.1 探测器接口

```go
// Prober 所有探测器必须实现的接口
type Prober interface {
    // Protocol 返回协议标识符，如 "icmp", "tcp", "http"
    Protocol() string

    // Probe 执行一次探测，ctx 携带超时控制
    Probe(ctx context.Context, target *Target) (*ProbeResult, error)

    // Validate 在目标注册时验证 probe_config 的合法性
    Validate(config map[string]any) error
}

// ProberRegistry 探测器注册表（全局单例）
type ProberRegistry struct {
    mu      sync.RWMutex
    probers map[string]Prober
}

func (r *ProberRegistry) Register(p Prober) {
    r.mu.Lock()
    defer r.mu.Unlock()
    r.probers[p.Protocol()] = p
}

func (r *ProberRegistry) Get(protocol string) (Prober, bool) {
    r.mu.RLock()
    defer r.mu.RUnlock()
    p, ok := r.probers[protocol]
    return p, ok
}
```

### 2.2 HTTP/HTTPS 探测器设计

```
HTTP 探测流程：

  构建 Request
    ├── Method: GET/POST/HEAD（可配置）
    ├── Headers: 自定义 + User-Agent: conmon/2.0
    ├── Body: 可选请求体
    └── TLS Config: 证书校验 / SNI / 指定 CA

  执行请求（with context deadline）
    ├── DNS 解析计时
    ├── TCP 连接计时
    ├── TLS 握手计时（HTTPS）
    └── 首字节响应计时

  校验响应
    ├── 状态码：是否在 expected_codes 列表中（默认 [200]）
    ├── 响应体：可选正则匹配 body_contains
    └── 响应时间：计算总延迟

  TLS 证书检查（HTTPS）
    ├── 解析证书链
    ├── 计算距过期天数
    └── 可选 OCSP 校验

返回 ProbeResult {
    success: bool,
    latency_ms: 总延迟（含 DNS+TCP+TLS+HTTP）,
    status_code: HTTP 响应码,
    detail: {
        dns_ms, tcp_ms, tls_ms, transfer_ms,
        cert_expiry_days, tls_version, tls_cipher
    }
}
```

### 2.3 调度器设计

```
调度器状态机：

  New ──────► Running
                │
                ├─ 加载所有 Target 配置
                ├─ 为每个 Target 创建计时器
                │
                ▼
           ticker goroutine（每个 Target 独立 ticker）
                │
                │ ticker.C 触发
                ▼
           任务入优先队列
                │
                ▼
           执行池 goroutine 消费队列
                │
                ├─ 调用 Prober.Probe()
                ├─ 结果写入 ResultBuffer
                └─ 根据结果动态调整下次间隔：
                   - SUCCESS → 使用配置的 interval
                   - FAIL    → 使用 min(5s, interval/2) 加速探测

配置热更新：
  ConfigWatcher goroutine 监听 etcd 变更事件
    ├─ 新增 Target → 创建新 ticker
    ├─ 修改 Target → 停止旧 ticker，创建新 ticker（携带新配置）
    └─ 删除 Target → 停止并移除 ticker
```

### 2.4 并发控制

```go
// Executor 探测执行池，通过信号量控制并发
type Executor struct {
    sem     chan struct{}   // 信号量，大小 = concurrency 配置
    wg      sync.WaitGroup
    results chan *ProbeResult
}

func (e *Executor) Submit(ctx context.Context, task ProbeTask) {
    e.wg.Add(1)
    go func() {
        defer e.wg.Done()

        // 获取信号量，若满则阻塞等待（优先队列已在入队时处理优先级）
        select {
        case e.sem <- struct{}{}:
            defer func() { <-e.sem }()
        case <-ctx.Done():
            return
        }

        result, err := task.Prober.Probe(ctx, task.Target)
        if err != nil {
            result = &ProbeResult{Success: false, ErrorMsg: err.Error()}
        }
        e.results <- result
    }()
}
```

### 2.5 重试机制

```
重试策略（指数退避）：

首次探测失败
    │
    ├── 等待 retry_interval_base（默认 1s）
    ├── 第2次重试
    ├── 失败 → 等待 retry_interval_base × 2（2s）
    ├── 第3次重试
    └── 失败 → 等待 retry_interval_base × 4（4s）... 上限 30s

Jitter：每次等待时间加入 ±20% 随机抖动，避免惊群效应

重试后结果聚合：
  - 所有重试均失败 → 报告为失败，延迟取最后一次
  - 任一重试成功  → 报告为成功，延迟取成功那次
  - consecutive_fails 计数 += 1（成功不重置，直到下次成功探测）
```

---

## 3. 状态机详细设计

### 3.1 状态转移规则

```go
// FSM 目标状态机
type FSM struct {
    mu     sync.Mutex
    states map[string]*TargetState  // targetID → state
    cfg    *FSMConfig
}

type FSMConfig struct {
    DownThreshold      int           // 连续失败 N 次 → DOWN（默认 3）
    RecoveryThreshold  int           // 连续成功 N 次 → UP（默认 2）
    FlapWindow         time.Duration // FLAPPING 检测窗口（默认 10min）
    FlapThreshold      int           // 窗口内变更次数 ≥ N → FLAPPING（默认 5）
    DegradedLatencyMs  int64         // 延迟超过此值 → DEGRADED
    DegradedLossPct    float64       // 丢包超过此比例 → DEGRADED
}

// Process 处理一次探测结果，返回是否发生了状态变更
func (f *FSM) Process(result *ProbeResult, target *Target) (changed bool, event *Event) {
    f.mu.Lock()
    defer f.mu.Unlock()

    state := f.getOrCreate(result.TargetID)
    prevStatus := state.Status

    // 更新连续计数
    if result.Success {
        state.ConsecutiveFails = 0
        state.ConsecutiveSuccess++
        state.LastSuccessAt = result.Timestamp
    } else {
        state.ConsecutiveSuccess = 0
        state.ConsecutiveFails++
    }

    // 维护窗口：强制 MAINTENANCE，不更新状态
    if f.isInMaintenance(target, result.Timestamp) {
        state.Status = StatusMaintenance
        return false, nil
    }

    // 手动 SILENT：继续探测但不改变状态
    if state.Status == StatusSilent {
        return false, nil
    }

    // 计算新状态
    newStatus := f.computeStatus(state, result, target)

    // FLAPPING 检测
    if newStatus != prevStatus {
        state.FlapCount10m = f.countFlaps(result.TargetID, result.Timestamp)
        if state.FlapCount10m >= f.cfg.FlapThreshold {
            newStatus = StatusFlapping
        }
    }

    if newStatus == prevStatus {
        return false, nil
    }

    // 发生状态变更
    state.Status = newStatus
    state.StatusChangedAt = result.Timestamp
    event = f.buildEvent(state, prevStatus, newStatus, result)
    return true, event
}

func (f *FSM) computeStatus(state *TargetState, result *ProbeResult, target *Target) Status {
    cfg := target.AlertConfig

    switch state.Status {
    case StatusUnknown:
        if result.Success {
            return StatusUp
        }
        return StatusUnknown

    case StatusUp, StatusDegraded:
        if state.ConsecutiveFails >= cfg.DownThreshold {
            return StatusDown
        }
        if f.isDegraded(result, cfg) {
            return StatusDegraded
        }
        return StatusUp

    case StatusDown, StatusFlapping:
        if state.ConsecutiveSuccess >= cfg.RecoveryThreshold {
            return StatusUp
        }
        return StatusDown
    }

    return state.Status
}
```

### 3.2 FLAPPING 检测算法

```go
// 滑动窗口计数：记录近 flapWindow 内的状态变更时间点
type FlapTracker struct {
    mu      sync.Mutex
    history map[string][]time.Time // targetID → 变更时间列表
    window  time.Duration
}

func (ft *FlapTracker) RecordChange(targetID string, t time.Time) {
    ft.mu.Lock()
    defer ft.mu.Unlock()

    ts := ft.history[targetID]
    // 清理窗口外的旧记录
    cutoff := t.Add(-ft.window)
    i := 0
    for i < len(ts) && ts[i].Before(cutoff) {
        i++
    }
    ts = append(ts[i:], t)
    ft.history[targetID] = ts
}

func (ft *FlapTracker) Count(targetID string, now time.Time) int {
    ft.mu.Lock()
    defer ft.mu.Unlock()

    cutoff := now.Add(-ft.window)
    ts := ft.history[targetID]
    count := 0
    for _, t := range ts {
        if t.After(cutoff) {
            count++
        }
    }
    return count
}
```

### 3.3 依赖拓扑检查

```go
// DependencyGraph 基于 DAG 的依赖拓扑，用于告警抑制
type DependencyGraph struct {
    mu       sync.RWMutex
    edges    map[string][]string // targetID → 直接依赖的 targetID 列表
    reverseEdges map[string][]string // targetID → 依赖它的 targetID 列表
}

// IsAffectedByUpstream 检查 targetID 是否有上游依赖处于 DOWN 状态
func (g *DependencyGraph) IsAffectedByUpstream(
    targetID string,
    getStatus func(string) Status,
) (suppressed bool, reason string) {
    g.mu.RLock()
    defer g.mu.RUnlock()

    // BFS 遍历依赖链
    visited := make(map[string]bool)
    queue := g.edges[targetID]

    for len(queue) > 0 {
        dep := queue[0]
        queue = queue[1:]

        if visited[dep] {
            continue
        }
        visited[dep] = true

        if getStatus(dep) == StatusDown {
            return true, fmt.Sprintf("上游依赖 %s 处于 DOWN 状态", dep)
        }

        queue = append(queue, g.edges[dep]...)
    }
    return false, ""
}
```

---

## 4. 告警引擎详细设计

### 4.1 规则评估

```go
// AlertRule 告警规则定义
type AlertRule struct {
    Name          string        `yaml:"name"`
    Condition     string        `yaml:"condition"`     // CEL 表达式
    Channels      []string      `yaml:"channels"`
    Throttle      Duration      `yaml:"throttle"`      // 同目标同规则最小告警间隔
    EscalateAfter Duration      `yaml:"escalate_after"`
    Severity      Severity      `yaml:"severity"`
    Template      string        `yaml:"template"`      // 自定义消息模板名称
}

// RuleEvaluator CEL 规则评估器
type RuleEvaluator struct {
    program map[string]cel.Program // ruleName → compiled CEL program
}

// Evaluate 评估规则是否命中
// activation 包含 target, event, state 等上下文变量
func (e *RuleEvaluator) Evaluate(rule *AlertRule, activation map[string]any) (bool, error) {
    prog, ok := e.program[rule.Name]
    if !ok {
        return false, fmt.Errorf("rule %s not compiled", rule.Name)
    }
    out, _, err := prog.Eval(activation)
    if err != nil {
        return false, err
    }
    b, ok := out.Value().(bool)
    return b && ok, nil
}

// 典型 CEL 规则示例：
// "status == 'DOWN' && 'P0' in target.tags"
// "latency_p99_ms > 500 && target.protocol == 'http'"
// "cert_expiry_days < 30 && target.protocol == 'https'"
```

### 4.2 告警生命周期

```
                    ┌──────────────────────────────┐
                    │     告警生命周期状态机          │
                    └──────────────────────────────┘

  事件触发
    │
    ▼
  [PENDING]  ──检查去重──► 已存在同类告警？
    │                         ├─YES─► 合并到已有告警（追加时间线）
    │                         └─NO──► 继续
    │
    ▼
  [FIRING]  ──发送通知──► 所有配置渠道
    │
    ├── 启动升级计时器
    │   5min 未 ACK → 升级到 L2
    │   15min 未 ACK → 升级到 L3（+电话通知）
    │
    ├── 用户 ACK ──────────────────────────────► [ACKNOWLEDGED]
    │                                                │
    │                                           故障恢复 → [RESOLVED]
    │
    └── 故障自动恢复 ──────────────────────────► [RESOLVED]
         （status 变为 UP 时）                   记录 resolved_at, duration

  静默操作 ──────────────────────────────────► [SILENCED]
  （任何状态均可静默）                          到期后恢复原状态
```

### 4.3 消息模板渲染

```go
// TemplateRenderer Jinja2 兼容模板渲染器（基于 Pongo2）
type TemplateRenderer struct {
    templates map[string]*pongo2.Template
    defaults  map[string]*pongo2.Template // 内置默认模板
}

// 模板上下文变量定义
type TemplateContext struct {
    Severity   string            `pongo2:"severity"`    // CRITICAL/ERROR/WARN
    Target     *Target           `pongo2:"target"`      // 目标完整信息
    State      *TargetState      `pongo2:"state"`       // 当前状态
    Event      *Event            `pongo2:"event"`       // 触发事件
    From       string            `pongo2:"from"`        // 前一状态
    To         string            `pongo2:"to"`          // 新状态
    Timestamp  string            `pongo2:"timestamp"`   // 格式化时间
    Duration   string            `pongo2:"duration"`    // 故障持续时长
    Since      string            `pongo2:"since"`       // 故障开始时间
    Probe      *ProbeNode        `pongo2:"probe"`       // 探针节点信息
    Reason     string            `pongo2:"reason"`      // 错误原因码
    GrafanaURL string            `pongo2:"grafana_url"` // Grafana 面板链接
    AckURL     string            `pongo2:"ack_url"`     // 一键确认链接
    JiraURL    string            `pongo2:"jira_url"`    // 创建工单链接
    Tags       []string          `pongo2:"tags"`
    Meta       map[string]any    `pongo2:"meta"`
}
```

### 4.4 通知渠道实现规范

```go
// Notifier 通知渠道接口
type Notifier interface {
    Name() string
    Type() string // dingtalk / wecom / email / webhook ...

    // Send 发送通知，ctx 携带超时控制（默认 10s）
    Send(ctx context.Context, msg *NotifyMessage, cfg map[string]any) error
}

// NotifyMessage 渠道无关的通知内容
type NotifyMessage struct {
    Title    string            // 标题
    Body     string            // 正文（已渲染）
    Severity Severity          // 严重级别（用于着色）
    Alert    *Alert            // 原始告警对象
    Event    *Event            // 原始事件对象
    Target   *Target           // 监控目标
    Extra    map[string]any    // 渠道特定扩展字段
}

// 钉钉通知器示例实现要点：
//   1. 构建 Markdown 消息体，DOWN 用 🔴，UP 用 🟢
//   2. HMAC-SHA256 签名（secret 不为空时）
//   3. POST 到 webhook URL
//   4. 解析响应 {"errcode": 0, "errmsg": "ok"}
//   5. errcode != 0 时返回 error，触发重试
//   6. 限流：同一 webhook 每分钟最多 20 条（内置令牌桶）

// 告警升级链
type EscalationChain struct {
    Level1 EscalationStep // 初次通知
    Level2 EscalationStep // 5min 未 ACK
    Level3 EscalationStep // 15min 未 ACK
}

type EscalationStep struct {
    After    Duration
    Channels []string
    Message  string // 升级时附加的说明文本
}
```

---

## 5. 存储层详细设计

### 5.1 存储层接口

```go
// StorageManager 统一存储接口，屏蔽底层实现
type StorageManager interface {
    // 事件存储（PostgreSQL / SQLite）
    SaveEvent(ctx context.Context, e *Event) error
    ListEvents(ctx context.Context, q EventQuery) ([]*Event, int64, error)
    GetEvent(ctx context.Context, id string) (*Event, error)
    AckEvent(ctx context.Context, id, userID string) error

    // 指标存储（InfluxDB / TDengine）
    WriteMetric(ctx context.Context, r *ProbeResult) error
    QueryLatency(ctx context.Context, q MetricQuery) ([]*LatencyPoint, error)
    QueryAvailability(ctx context.Context, q MetricQuery) (*AvailabilityStats, error)

    // 目标配置（PostgreSQL / etcd）
    SaveTarget(ctx context.Context, t *Target) error
    GetTarget(ctx context.Context, id string) (*Target, error)
    ListTargets(ctx context.Context, q TargetQuery) ([]*Target, int64, error)
    DeleteTarget(ctx context.Context, id string) error

    // SLA 计算（PostgreSQL sla_daily 表）
    GetSLA(ctx context.Context, q SLAQuery) (*SLAReport, error)
}
```

### 5.2 写入优化：批量异步写入

```go
// BatchWriter 探测结果批量写入器，减少 InfluxDB 写入次数
type BatchWriter struct {
    client  influxdb2.Client
    writeAPI api.WriteAPI
    batchSize  int           // 默认 1000
    flushInterval time.Duration // 默认 500ms
    buf     []*ProbeResult
    mu      sync.Mutex
    ticker  *time.Ticker
}

// Add 将探测结果加入缓冲区，满 batchSize 自动触发 flush
func (w *BatchWriter) Add(r *ProbeResult) {
    w.mu.Lock()
    w.buf = append(w.buf, r)
    shouldFlush := len(w.buf) >= w.batchSize
    w.mu.Unlock()

    if shouldFlush {
        w.Flush()
    }
}

// Flush 批量写入 InfluxDB
func (w *BatchWriter) Flush() {
    w.mu.Lock()
    if len(w.buf) == 0 {
        w.mu.Unlock()
        return
    }
    batch := w.buf
    w.buf = make([]*ProbeResult, 0, w.batchSize)
    w.mu.Unlock()

    for _, r := range batch {
        p := influxdb2.NewPoint("probe_result",
            map[string]string{
                "target_id":    r.TargetID,
                "probe_node_id": r.ProbeNodeID,
                "protocol":     r.TargetProtocol,
                "status":       boolToStatus(r.Success),
            },
            map[string]interface{}{
                "latency_ms":      r.LatencyMs,
                "status_code":     r.StatusCode,
                "cert_expiry_days": r.Detail["cert_expiry_days"],
            },
            r.Timestamp,
        )
        w.writeAPI.WritePoint(p)
    }
    w.writeAPI.Flush()
}
```

### 5.3 数据分层存储

```
探测结果数据生命周期：

  写入时           原始精度（每次探测结果）
  ────────────────────────────────────────────
  Day 1~7          InfluxDB: probe_result（纳秒精度）
  Day 8~30         InfluxDB: probe_result_1min（1分钟聚合，保留 P50/P95/P99）
  Day 31~365       InfluxDB: probe_result_1h（1小时聚合）
  Day 366+         S3/OSS: 压缩归档（Parquet 格式，按月分区）

  降采样任务（InfluxDB Task）：
  // 每小时执行，将 1min 精度降为 1h
  option task = {name: "downsample_1h", every: 1h, offset: 5m}
  from(bucket: "conmon_raw")
    |> range(start: -1h)
    |> filter(fn: (r) => r._measurement == "probe_result_1min")
    |> aggregateWindow(every: 1h, fn: mean, createEmpty: false)
    |> to(bucket: "conmon_1h")
```

---

## 6. API 层详细设计

### 6.1 鉴权设计

```
API 鉴权流程：

  HTTP Request
    │
    ├── 路径匹配免鉴权白名单？
    │   /health, /ready, /metrics
    │   └─YES─► 直接放行
    │
    ├── 提取 Token
    │   Authorization: Bearer <token>
    │   │
    │   ├── token = "jwt_" 开头 → JWT 鉴权
    │   │   解析 JWT Payload，验证签名、有效期
    │   │   提取 user_id, roles, permissions
    │   │
    │   └── 其他 → API Token 鉴权
    │       查询 api_tokens 表（bcrypt 比对）
    │       提取 token 绑定的 user_id, scopes
    │
    ├── RBAC 权限检查
    │   Permission = "<resource>:<action>"
    │   如 "targets:write", "alerts:ack", "reports:read"
    │   检查当前用户角色是否包含所需权限
    │
    └── 写入 Request Context（用于审计日志）

API Token 数据结构：
  api_tokens 表：
    id, name, prefix(前8位明文), hash(bcrypt), user_id,
    scopes(text[]), last_used_at, expires_at, created_at
```

### 6.2 限流设计

```go
// RateLimiter 基于令牌桶的限流器
type RateLimiter struct {
    global  *rate.Limiter // 全局限流
    perUser map[string]*rate.Limiter // 按用户/IP 限流
    mu      sync.Mutex
}

// 限流配置（可通过配置文件调整）
type RateLimitConfig struct {
    GlobalRPS      int // 全局每秒请求数，默认 10000
    PerUserRPS     int // 单用户每秒请求数，默认 100
    WriteRPS       int // 写接口限流（单用户），默认 20
    BurstMultiplier int // 突发系数，默认 5
}

// 中间件实现
func RateLimitMiddleware(rl *RateLimiter) gin.HandlerFunc {
    return func(c *gin.Context) {
        userID := c.GetString("user_id")
        if userID == "" {
            userID = c.ClientIP()
        }

        if !rl.Allow(userID) {
            c.JSON(429, gin.H{
                "code":    "RATE_LIMITED",
                "message": "请求过于频繁，请稍后重试",
                "retry_after": "1",
            })
            c.Abort()
            return
        }
        c.Next()
    }
}
```

### 6.3 关键 API 设计

#### GET /api/v1/targets（目标列表）

```
请求参数：
  ?page=1&size=20
  &tags=生产环境,P0          （AND 关系）
  &status=DOWN,DEGRADED      （OR 关系）
  &protocol=https
  &host=gateway              （模糊匹配）
  &sort=status_changed_at    （排序字段）
  &order=desc

响应结构：
{
  "total": 1523,
  "page": 1,
  "size": 20,
  "data": [
    {
      "id": "target-001",
      "name": "核心网关",
      "host": "gateway.corp.com",
      "port": 443,
      "protocol": "https",
      "status": {           // 嵌入当前状态（JOIN 自内存缓存）
        "status": "DOWN",
        "status_changed_at": "2026-06-15T14:32:05Z",
        "avg_latency_ms": 0,
        "availability_7d": 0.9987
      },
      "tags": ["生产环境", "P0", "核心链路"],
      ...
    }
  ]
}
```

#### WebSocket /api/v1/ws/status（实时状态推送）

```
连接建立后服务端推送格式：

// 初始全量快照
{
  "type": "snapshot",
  "data": [ ...所有目标的当前状态... ]
}

// 增量状态变更
{
  "type": "status_changed",
  "target_id": "target-001",
  "from": "UP",
  "to": "DOWN",
  "timestamp": "2026-06-15T14:32:05Z"
}

// 心跳
{
  "type": "ping",
  "ts": 1718456325000
}

客户端 filter 支持（连接时发送）：
{
  "type": "subscribe",
  "filter": {
    "tags": ["生产环境"],
    "status": ["DOWN", "DEGRADED"]
  }
}
```

### 6.4 错误响应规范

```json
// 统一错误响应格式
{
  "code": "TARGET_NOT_FOUND",          // 机器可读错误码
  "message": "目标 target-999 不存在", // 人类可读描述
  "details": {                          // 可选，额外错误上下文
    "target_id": "target-999"
  },
  "request_id": "req-abc123",           // 用于日志追踪
  "timestamp": "2026-06-15T14:32:05Z"
}

// HTTP 状态码映射：
// 400 → INVALID_PARAMS / VALIDATION_ERROR
// 401 → UNAUTHORIZED
// 403 → FORBIDDEN
// 404 → NOT_FOUND
// 409 → CONFLICT（如目标 ID 已存在）
// 422 → UNPROCESSABLE（如 probe_config 语义错误）
// 429 → RATE_LIMITED
// 500 → INTERNAL_ERROR
// 503 → SERVICE_UNAVAILABLE（存储不可用）
```

---

## 7. 配置管理详细设计

### 7.1 配置分层

```
配置优先级（高 → 低）：

  1. 环境变量           CONMON_SERVER_BIND=0.0.0.0:9090
  2. 命令行参数         --bind 0.0.0.0:9090
  3. 配置文件           conmon.yaml
  4. 远程配置（etcd）   /conmon/config/server
  5. 内置默认值         timeout: 5s, retries: 3, concurrency: 100

配置项命名规则：
  文件：snake_case          server.tls.enabled: true
  环境变量：UPPER_SNAKE     CONMON_SERVER_TLS_ENABLED=true
  命令行：kebab-case        --server-tls-enabled
```

### 7.2 动态配置热重载

```go
// ConfigWatcher 监听配置变化并热更新
type ConfigWatcher struct {
    etcdClient  *clientv3.Client
    localCache  *sync.Map     // path → value
    handlers    map[string][]ChangeHandler
}

// 热重载范围：
// ✓ 监控目标（增/删/改）→ 调度器实时更新
// ✓ 告警规则（增/删/改）→ 规则引擎实时更新
// ✓ 通知渠道配置        → 渠道重新初始化
// ✓ 日志级别            → 运行时调整日志详细度
// ✗ 服务绑定地址         → 需要重启
// ✗ 数据库 DSN          → 需要重启
// ✗ TLS 证书路径        → 需要重启（证书内容可热更）

// SIGHUP 信号触发本地文件配置重载
signal.Notify(sighupCh, syscall.SIGHUP)
go func() {
    for range sighupCh {
        if err := config.Reload(); err != nil {
            log.Error("配置热重载失败", "error", err)
        } else {
            log.Info("配置热重载成功")
        }
    }
}()
```

### 7.3 配置验证

```go
// 配置验证规则（注册在字段 tag 上）
type MonitorConfig struct {
    Name     string   `yaml:"name"     validate:"required,min=1,max=255"`
    Host     string   `yaml:"host"     validate:"required,hostname_rfc1123|ip"`
    Port     int      `yaml:"port"     validate:"min=0,max=65535"`
    Protocol string   `yaml:"protocol" validate:"required,oneof=icmp tcp tcp-syn udp http https dns tls websocket grpc"`
    Interval Duration `yaml:"interval" validate:"required,min=5s,max=24h"`
    Timeout  Duration `yaml:"timeout"  validate:"required,min=100ms,max=60s"`
    Retries  int      `yaml:"retries"  validate:"min=0,max=10"`
}

// 语义校验（超出 tag 范围的业务规则）
func ValidateTarget(t *Target) []ValidationError {
    errs := []ValidationError{}

    // 超时不能大于探测间隔
    if t.Timeout >= t.Interval {
        errs = append(errs, ValidationError{
            Field:   "timeout",
            Message: "timeout 必须小于 interval",
        })
    }

    // ICMP 需要 CAP_NET_RAW 权限提示
    if t.Protocol == "icmp" && !hasCapNetRaw() {
        errs = append(errs, ValidationError{
            Field:   "protocol",
            Message: "ICMP 探测需要 CAP_NET_RAW 权限，请以 root 运行或设置 setcap",
            Severity: "warning",
        })
    }

    // 依赖环检测（DFS）
    if cycle := detectCycle(t.ID, t.Dependencies); cycle != nil {
        errs = append(errs, ValidationError{
            Field:   "dependencies",
            Message: fmt.Sprintf("检测到依赖环: %v", cycle),
        })
    }

    return errs
}
```

---

## 8. 插件系统详细设计

### 8.1 子进程插件协议

```
子进程插件通过 stdin/stdout 通信：

主进程启动子进程：
  conmon-probe --plugin /usr/local/lib/conmon/mqtt-prober.py

握手（启动后 3s 内完成）：
  主→子: {"type":"handshake","version":"2.0","protocol":"mqtt"}
  子→主: {"type":"handshake_ack","name":"MQTT Prober","version":"1.0",
          "capabilities":["probe","validate"]}

探测请求：
  主→子: {
    "type": "probe",
    "id": "req-001",
    "target": { ...Target JSON... },
    "timeout_ms": 5000
  }
  子→主: {
    "type": "probe_result",
    "id": "req-001",
    "success": true,
    "latency_ms": 42.3,
    "status_code": 0,
    "detail": {"mqtt_connack_rc": 0}
  }

配置验证请求：
  主→子: {"type":"validate","id":"req-002","config":{ ...probe_config... }}
  子→主: {"type":"validate_result","id":"req-002","valid":true,"errors":[]}

心跳（每 30s）：
  主→子: {"type":"ping","ts":1718456325000}
  子→主: {"type":"pong","ts":1718456325000}

子进程异常退出：主进程等待 5s 后重启，最多重启 3 次，超过则标记插件为不可用
```

### 8.2 Webhook 插件协议

```yaml
# 注册 Webhook 插件
plugins:
  - name: "redis-prober"
    type: "webhook"
    endpoint: "http://127.0.0.1:9201/probe"
    timeout: "5s"
    auth:
      type: "bearer"
      token: "${REDIS_PROBER_TOKEN}"
```

```
POST http://127.0.0.1:9201/probe
Content-Type: application/json
Authorization: Bearer <token>

Request Body:
{
  "target": { ...Target JSON... },
  "timeout_ms": 5000
}

Response Body (200 OK):
{
  "success": true,
  "latency_ms": 1.2,
  "status_code": 0,
  "error_code": "",
  "detail": {
    "redis_version": "7.0.5",
    "connected_clients": 42
  }
}

Response Body (失败示例):
{
  "success": false,
  "latency_ms": 5001,
  "error_code": "connection_refused",
  "error_msg": "dial tcp 127.0.0.1:6379: connect: connection refused"
}
```

---

## 9. 自动化与自愈详细设计

### 9.1 Hook 脚本执行模型

```go
// HookConfig 钩子配置
type HookConfig struct {
    OnDown       string   `yaml:"on_down"`        // 目标变为 DOWN 时执行
    OnUp         string   `yaml:"on_up"`          // 目标恢复 UP 时执行
    OnDegraded   string   `yaml:"on_degraded"`    // 目标进入 DEGRADED 时执行
    OnFlapping   string   `yaml:"on_flapping"`    // 目标进入 FLAPPING 时执行
    Timeout      Duration `yaml:"timeout"`        // 脚本执行超时，默认 30s
    MaxRetries   int      `yaml:"max_retries"`    // 失败重试次数，默认 0
    RunAsUser    string   `yaml:"run_as_user"`    // 执行用户（安全隔离）
}

// HookExecutor 钩子执行器
type HookExecutor struct {
    allowed []string // 允许执行的脚本路径前缀（白名单）
}

func (e *HookExecutor) Execute(hook string, env map[string]string) error {
    // 安全检查：脚本路径必须在白名单目录内
    if !e.isAllowed(hook) {
        return fmt.Errorf("hook 脚本 %s 不在允许目录内", hook)
    }

    // 构建环境变量（向脚本传递事件上下文）
    // CONMON_TARGET_ID=target-001
    // CONMON_TARGET_NAME=核心网关
    // CONMON_TARGET_HOST=gateway.corp.com
    // CONMON_EVENT=DOWN
    // CONMON_PREV_STATUS=UP
    // CONMON_TIMESTAMP=2026-06-15T14:32:05Z
    // CONMON_DURATION_MS=5000
    // CONMON_REASON=tcp_timeout

    ctx, cancel := context.WithTimeout(context.Background(), hook.Timeout)
    defer cancel()

    cmd := exec.CommandContext(ctx, "/bin/sh", "-c", hook)
    cmd.Env = buildEnv(env)
    out, err := cmd.CombinedOutput()

    log.Info("hook 执行完成", "script", hook, "output", string(out), "err", err)
    return err
}
```

### 9.2 工作流引擎设计

```
工作流定义（YAML）：

workflows:
  - name: "自动故障处理"
    trigger:
      event: status_changed
      condition: "to == 'DOWN' and 'P0' in target.tags"
    steps:
      - name: "执行链路诊断"
        type: exec
        script: "/opt/conmon/scripts/mtr-check.sh"
        timeout: "30s"
        continue_on_error: true

      - name: "尝试重启服务"
        type: exec
        script: "/opt/conmon/scripts/restart-service.sh"
        timeout: "60s"
        retry: 2

      - name: "等待恢复"
        type: wait_for_status
        status: UP
        timeout: "3m"

      - name: "通知结果"
        type: notify
        channel: "运维钉钉"
        template: "auto_remediation_result"
        condition: "steps['尝试重启服务'].success == true"

      - name: "人工确认"
        type: human_approval
        notify_channel: "运维钉钉"
        timeout: "15m"   # 超时则升级告警
        skip_if: "steps['等待恢复'].success == true"
```

### 9.3 基线学习算法

```
延迟基线学习（滑动统计）：

  数据收集：
    收集近 7 天同一目标同一时段（按小时分组）的延迟数据
    排除故障时段（status=DOWN 期间的数据）

  基线计算：
    base_p50[hour] = percentile(latencies_by_hour[hour], 50)
    base_p95[hour] = percentile(latencies_by_hour[hour], 95)
    base_stddev[hour] = stddev(latencies_by_hour[hour])

  动态阈值：
    warn_threshold = base_p95 + 3 × base_stddev
    // 当前延迟超过 warn_threshold → 触发 DEGRADED

  更新策略：
    每天凌晨 2:00 重新计算基线（使用滑动 7 天窗口）
    新目标：使用全局平均值作为初始基线，7 天后切换到个性化基线

  异常值过滤：
    使用 IQR 方法过滤离群点
    Q1 = 25th percentile, Q3 = 75th percentile
    IQR = Q3 - Q1
    过滤范围：[Q1 - 1.5×IQR, Q3 + 1.5×IQR] 以外的值不纳入基线计算
```

---

## 10. 错误处理与可观测性

### 10.1 结构化日志规范

```go
// 所有日志统一使用 slog（Go 1.21+ 标准库）
// 禁止使用 fmt.Printf 或未结构化的 log.Printf

// 正确用法：
slog.ErrorContext(ctx, "探测失败",
    "target_id", target.ID,
    "target_host", target.Host,
    "probe_node", probeNodeID,
    "error_code", errCode,
    "latency_ms", latencyMs,
    "consecutive_fails", state.ConsecutiveFails,
)

// 日志字段标准化：
// target_id      : 监控目标 ID
// probe_node_id  : 探针节点 ID
// request_id     : HTTP 请求 ID（链路追踪）
// user_id        : 操作用户 ID
// event_id       : 事件 ID
// alert_id       : 告警 ID
// error_code     : 机器可读错误码
// duration_ms    : 操作耗时（毫秒）
// component      : 组件名（scheduler/prober/alerter/api）
```

### 10.2 Prometheus 自监控指标

```
# 探测相关
conmon_probe_total{target_id, protocol, status, probe_node}  counter
conmon_probe_duration_ms{target_id, protocol, probe_node}    histogram (buckets: 1,5,10,50,100,500,1000,5000)
conmon_probe_queue_size{priority}                            gauge
conmon_probe_concurrent_current                              gauge

# 状态机相关
conmon_targets_by_status{status}                             gauge
conmon_status_changes_total{target_id, from, to}             counter
conmon_flapping_targets_current                              gauge

# 告警相关
conmon_alerts_fired_total{rule_name, severity}               counter
conmon_alerts_firing_current{severity}                       gauge
conmon_alert_notify_duration_ms{channel, status}             histogram
conmon_alert_notify_errors_total{channel, error_code}        counter

# 存储相关
conmon_storage_write_duration_ms{backend}                    histogram
conmon_storage_write_errors_total{backend, error_code}       counter
conmon_storage_queue_size{backend}                           gauge

# 系统资源
conmon_goroutines_current                                    gauge
conmon_memory_bytes{type}                                    gauge
conmon_uptime_seconds                                        counter
```

### 10.3 分布式链路追踪

```go
// 所有跨组件调用注入 OpenTelemetry Trace
// 支持 Jaeger / Zipkin / OTLP 导出

// Span 命名规范：
// <component>.<operation>
// 例：
//   prober.http.probe
//   fsm.process
//   alerter.rule.evaluate
//   alerter.notify.dingtalk
//   storage.event.save
//   api.targets.list

// 关键 Span Attributes：
//   target.id
//   target.protocol
//   probe.node_id
//   alert.rule_name
//   alert.channel
//   db.system (postgresql/influxdb)
//   http.status_code
```

### 10.4 健康检查端点

```
GET /health  (存活检查, Liveness)
  → 200: {"status":"ok","uptime_sec":3600}
  → 500: {"status":"error","reason":"goroutine_leak"} (当 goroutine 数超过阈值)

GET /ready   (就绪检查, Readiness，K8s 使用)
  检查以下依赖：
  ├── PostgreSQL 连接池可用
  ├── InfluxDB 可写入
  ├── etcd 连接正常
  └── 探针注册数量 > 0
  → 200: {"status":"ready","checks":{...各组件状态...}}
  → 503: {"status":"not_ready","checks":{...失败项...}}

GET /metrics  (Prometheus 格式)
  → 200: # HELP conmon_probe_total ...（标准 Prometheus text format）
```

---

## 附录

### A. 关键算法复杂度

| 算法 | 时间复杂度 | 空间复杂度 | 说明 |
|------|-----------|-----------|------|
| 状态机处理 | O(1) | O(N) | N 为目标数量 |
| FLAPPING 检测 | O(W) | O(N×W) | W 为窗口内最大事件数 |
| 依赖拓扑检查 | O(V+E) | O(V) | V 目标数，E 依赖边数 |
| 批量故障识别 | O(N) | O(1) | N 为目标数量 |
| 告警去重 | O(1) | O(A) | A 为活跃告警数量（哈希表） |
| CEL 规则评估 | O(R) | O(R) | R 为规则数量，编译期优化 |

### B. 接口版本兼容性约定

- API 路径以 `/api/v1/` 为前缀，主版本号变更时升级为 `/api/v2/`
- gRPC 接口使用 `proto3`，字段废弃时保留编号，使用 `deprecated` 注释
- 插件协议主版本变更时，握手阶段进行版本协商降级
- 配置文件字段废弃时，保留解析但写入警告日志，下一个大版本移除

### C. 已知限制

| 限制 | 说明 | 计划解决版本 |
|------|------|------------|
| ICMP 需要 root 权限 | 使用原始套接字 | v2.1 使用 unprivileged ICMP（ping via UDP） |
| 探针仅支持 Go/Python 插件 | 子进程模型 | v2.2 支持 WASM 插件 |
| Grafana 模板仅支持 InfluxDB 数据源 | 模板硬编码 | v2.1 支持 Prometheus 数据源 |
| 工作流引擎不支持条件分支循环 | 简单串行 | v3.0 引入 DAG 工作流 |

---

*本文档由 conMon 研发团队维护。*
