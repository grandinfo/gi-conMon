# conMon 故障排查指南

**版本**：v2.0 · **日期**：2026-06-15

---

## 目录

1. [快速诊断工具](#1-快速诊断工具)
2. [服务启动失败](#2-服务启动失败)
3. [探测异常问题](#3-探测异常问题)
4. [告警相关问题](#4-告警相关问题)
5. [存储与数据库问题](#5-存储与数据库问题)
6. [API 与连接问题](#6-api-与连接问题)
7. [性能问题](#7-性能问题)
8. [探针节点问题](#8-探针节点问题)
9. [状态机异常](#9-状态机异常)
10. [常见错误码参考](#10-常见错误码参考)

---

## 1. 快速诊断工具

### 1.1 内置自诊断命令

```bash
# 自动诊断常见问题（推荐首先执行）
conmon doctor

# 输出示例：
# ✓ 配置文件语法有效
# ✓ 数据库连接正常 (PostgreSQL 16.1)
# ✓ InfluxDB 连接正常 (InfluxDB 2.7.1)
# ✗ ICMP 权限缺失: 请执行 sudo setcap cap_net_raw+ep /usr/local/bin/conmon
# ⚠ 探针节点 probe-gz-01 已离线 5 分钟
# ✓ TLS 证书有效 (还有 127 天过期)
# ✓ 磁盘使用率正常 (使用 45%)
```

### 1.2 状态检查命令集

```bash
# 全套快速状态检查
echo "=== 服务状态 ===" && systemctl status conmon --no-pager
echo "=== 健康检查 ===" && curl -sf http://localhost:8080/health | jq
echo "=== 就绪检查 ===" && curl -sf http://localhost:8080/ready | jq
echo "=== 探针状态 ===" && conmon probe list
echo "=== 目标异常 ===" && conmon status --filter "DOWN,DEGRADED,FLAPPING"
echo "=== 最近告警 ===" && conmon alert list --status firing --limit 10
echo "=== 错误日志 ===" && journalctl -u conmon --since "1h" -p err --no-pager | tail -20
```

### 1.3 Prometheus 指标检查

```bash
# 查看关键指标
curl -s http://localhost:8080/metrics | grep -E "^conmon_(goroutines|targets|probe_total|storage_queue)"

# 检查写入错误率
curl -s http://localhost:8080/metrics | grep "conmon_storage_write_errors"

# 检查告警发送错误
curl -s http://localhost:8080/metrics | grep "conmon_alert_notify_errors"
```

---

## 2. 服务启动失败

### 问题：`systemctl start conmon` 失败

**诊断步骤**：

```bash
# 查看详细错误
sudo systemctl status conmon -l
sudo journalctl -u conmon -n 50 --no-pager

# 手动运行（查看完整错误输出）
sudo -u conmon /usr/local/bin/conmon server -c /etc/conmon/conmon.yaml
```

**常见原因与解决方案**：

#### 原因 1：配置文件语法错误

```
FATAL config parse error: yaml: line 23: did not find expected key
```

```bash
# 解决：验证配置文件
conmon config validate -c /etc/conmon/conmon.yaml

# 使用 YAML 校验工具
python3 -c "import yaml; yaml.safe_load(open('/etc/conmon/conmon.yaml'))"
```

#### 原因 2：端口已被占用

```
FATAL failed to listen on 0.0.0.0:8080: bind: address already in use
```

```bash
# 查看端口占用
sudo ss -tlnp | grep 8080
sudo lsof -i :8080

# 修改监听端口或停止占用进程
```

#### 原因 3：数据库连接失败

```
FATAL failed to connect to PostgreSQL: dial tcp 127.0.0.1:5432: connection refused
```

```bash
# 检查 PostgreSQL 状态
sudo systemctl status postgresql
sudo -u postgres psql -c "\l"

# 测试连接
psql "postgres://conmon:password@localhost:5432/conmon" -c "SELECT 1"

# 检查配置文件中的 DSN
grep -A3 "postgresql" /etc/conmon/conmon.yaml
```

#### 原因 4：权限不足（ICMP 模式）

```
WARN icmp prober disabled: operation not permitted (need CAP_NET_RAW)
```

```bash
# 赋予 ICMP 权限
sudo setcap cap_net_raw+ep /usr/local/bin/conmon

# 验证
getcap /usr/local/bin/conmon
# 输出应包含：cap_net_raw+ep
```

#### 原因 5：数据目录权限问题

```
FATAL failed to open database: unable to open database file: permission denied
```

```bash
sudo chown -R conmon:conmon /var/lib/conmon
sudo chmod 750 /var/lib/conmon
```

---

## 3. 探测异常问题

### 问题：目标一直显示 UNKNOWN

**原因**：探针节点未上报结果。

```bash
# 检查探针节点连接
conmon probe list  # 所有探针均 online？

# 检查目标是否有指定探针
conmon target get <id> | jq '.probe_ids'

# 手动触发探测查看结果
conmon target probe <target-id>

# 检查探针日志
ssh probe@bj-01 "journalctl -u conmon-probe -n 50"
```

### 问题：目标频繁 FLAPPING（抖动）

**症状**：目标在 UP/DOWN 之间频繁切换，产生大量告警。

```bash
# 查看目标最近事件
conmon events --target <id> --since 30m

# 分析：是探针问题还是真实网络问题？
# 查看各探针的探测结果
conmon target latency <id> --since 1h --group-by probe

# 解决方案1：增大 DOWN 判定阈值（减少误报）
conmon target update <id> --down-threshold 5  # 默认 3，改为 5

# 解决方案2：增大探测间隔
conmon target update <id> --interval 1m

# 临时解决方案：静默该目标
conmon target silence <id> --duration 1h --reason "抖动排查中"
```

### 问题：HTTP 探测成功但 conMon 报失败

```bash
# 手动模拟探测请求
curl -v -o /dev/null -w "%{http_code}" https://your-target.com/health

# 检查 expected_codes 配置是否正确
conmon target get <id> | jq '.probe_config.expected_codes'
# 如果服务返回 204，但配置只期望 200，会报失败

# 检查 TLS 证书校验问题
curl -v --cacert /path/to/ca.crt https://your-target.com/health

# 查看探测详情（DEBUG 模式）
conmon target probe <id> --verbose
```

### 问题：ICMP 延迟异常高但 TCP 正常

```bash
# 这通常是正常的：ICMP 可能被网络设备限速
# 改用 TCP 探测验证实际服务状态
conmon target add --name "TCP验证" --host <same-host> --protocol tcp --port 80

# 检查是否有 QoS 策略限制 ICMP
mtr --report-wide <target-host>
```

### 问题：DNS 探测失败

```bash
# 手动验证 DNS 查询
dig @8.8.8.8 example.com A

# 检查探测配置
conmon target get <id> | jq '.probe_config'

# 常见原因：probe_config.query_domain 未配置
# DNS 探测必须指定 query_domain
conmon target update <id> --probe-config '{"query_type":"A","query_domain":"example.com"}'
```

---

## 4. 告警相关问题

### 问题：告警规则命中但没有收到通知

**诊断步骤**：

```bash
# 1. 查看告警记录（是否已生成告警）
conmon alert list --target <id> --since 1h

# 2. 查看告警发送日志
journalctl -u conmon -n 100 | grep "alert"

# 3. 检查 Prometheus 指标
curl -s http://localhost:8080/metrics | grep "conmon_alert_notify"

# 4. 手动测试通知渠道
conmon channel test --name "运维钉钉"
```

**常见原因**：

#### 原因 1：告警被静默

```bash
conmon silence list  # 查看是否有全局或目标级静默
```

#### 原因 2：告警被依赖抑制

```bash
# 查看目标的依赖关系
conmon target get <id> | jq '.dependencies'

# 检查上游依赖状态
conmon status --target <upstream-id>
```

#### 原因 3：throttle（去重）期间

```bash
# 查看告警规则的 throttle 设置
grep -A5 "throttle" /etc/conmon/conmon.yaml

# 查看最后一次告警时间
conmon alert list --target <id> --limit 5
```

#### 原因 4：钉钉/企业微信 Webhook 失效

```bash
# 测试 Webhook
curl -X POST "https://oapi.dingtalk.com/robot/send?access_token=xxx" \
  -H "Content-Type: application/json" \
  -d '{"msgtype": "text", "text": {"content": "conMon 连通性测试"}}'

# 检查 secret 是否过期（钉钉 Webhook 密钥可能变更）
```

### 问题：收到大量重复告警

```bash
# 检查去重配置
grep "throttle" /etc/conmon/conmon.yaml

# 建议配置（避免重复告警）
# throttle: "10m"   # 同一目标同一规则 10 分钟内只发一次

# 检查是否配置了告警合并
grep "group" /etc/conmon/conmon.yaml
```

### 问题：告警恢复通知没有发出

```bash
# 检查是否配置了恢复通知规则
grep -A5 "UP" /etc/conmon/conmon.yaml

# 需要配置类似：
# - name: "服务恢复"
#   condition: "event.to_status == 'UP' && event.from_status == 'DOWN'"
#   channels: ["dingtalk"]
```

---

## 5. 存储与数据库问题

### 问题：PostgreSQL 连接数耗尽

```
ERROR pq: sorry, too many clients already
```

```bash
# 查看当前连接数
psql -U conmon -d conmon -c "SELECT count(*) FROM pg_stat_activity WHERE datname='conmon';"

# 查看最大连接数配置
psql -U conmon -d conmon -c "SHOW max_connections;"

# 临时增大连接数（需重启 PostgreSQL）
sudo vim /etc/postgresql/16/main/postgresql.conf
# max_connections = 200  （默认 100）
sudo systemctl restart postgresql

# 或减少 conmon 连接池大小
# storage.postgresql.pool_max: 20  （默认 50）
```

### 问题：InfluxDB 写入积压

```bash
# 检查队列大小
curl -s http://localhost:8080/metrics | grep conmon_storage_queue_size

# 常见原因：InfluxDB 服务异常
curl http://localhost:8086/health

# 检查 InfluxDB 日志
docker logs conmon-influxdb | tail -30

# 临时解决：重启 InfluxDB 后积压数据会自动补写
# 如队列超出 buffer_size，会丢失部分时序数据（不影响事件和状态）
```

### 问题：SQLite 锁定（WAL 模式）

```
database is locked
```

```bash
# SQLite 使用 WAL 模式，高并发场景下可能锁超时
# 解决方案1：增大 busy_timeout
# 在 storage.path 配置后添加：
# storage:
#   sqlite_options: "_busy_timeout=30000&_journal_mode=WAL"

# 解决方案2：生产环境建议切换到 PostgreSQL
```

### 问题：磁盘占用快速增长

```bash
# 检查各表大小
psql -U conmon -d conmon -c "
SELECT relname, pg_size_pretty(pg_total_relation_size(relid))
FROM pg_catalog.pg_statio_user_tables
ORDER BY pg_total_relation_size(relid) DESC LIMIT 10;"

# 通常 events 表最大，检查 retention 配置
grep "retention" /etc/conmon/conmon.yaml

# 手动触发清理
conmon db cleanup --dry-run   # 先预览会删除多少数据
conmon db cleanup             # 实际执行

# 如果 events 表过大，可减少 DEBUG 事件的保留时间
```

---

## 6. API 与连接问题

### 问题：API 返回 401 Unauthorized

```bash
# 检查 Token 是否有效
curl -v http://localhost:8080/api/v1/targets \
  -H "Authorization: Bearer $TOKEN" 2>&1 | grep "< HTTP"

# Token 可能过期，重新获取
conmon auth login --username admin

# 检查 JWT_SECRET 是否变更（会导致所有旧 Token 失效）
```

### 问题：API 返回 503 Service Unavailable

```bash
# 就绪检查查看具体失败项
curl http://localhost:8080/ready | jq

# 通常是依赖服务不可用（数据库/InfluxDB）
systemctl status postgresql
```

### 问题：WebSocket 连接断开

```bash
# 检查 Nginx 超时配置
grep "proxy_read_timeout" /etc/nginx/conf.d/conmon.conf
# 应设置为 3600s（WebSocket 需要长连接）

# 正确的 Nginx WebSocket 配置：
# location /api/v1/ws {
#     proxy_pass http://conmon_servers;
#     proxy_http_version 1.1;
#     proxy_set_header Upgrade $http_upgrade;
#     proxy_set_header Connection "upgrade";
#     proxy_read_timeout 3600s;
# }
```

### 问题：gRPC 探针连接失败

```bash
# 检查 gRPC 端口是否开放
nc -zv conmon-server 9090

# 检查 TLS 证书
openssl s_client -connect conmon-server:9090 -cert probe.crt -key probe.key

# 探针日志
journalctl -u conmon-probe -n 50
```

---

## 7. 性能问题

### 问题：CPU 使用率持续偏高

```bash
# 查看 goroutine 数量
curl -s http://localhost:8080/metrics | grep "conmon_goroutines"
# 若 goroutine 数 > 5000，可能存在泄漏

# 获取 CPU 热点
curl -s "http://localhost:6060/debug/pprof/profile?seconds=30" -o cpu.prof
go tool pprof -top cpu.prof

# 常见热点：
# - 并发数设置过高（concurrency 超过 CPU 核数 × 100）
# - 正则表达式匹配效率低（body_contains 使用复杂正则）
# - 降采样 Task 频率过高
```

### 问题：内存使用持续增长（内存泄漏）

```bash
# 采样堆内存
curl -s http://localhost:6060/debug/pprof/heap -o heap.prof
go tool pprof -top heap.prof

# 查看 goroutine 泄漏
curl -s "http://localhost:6060/debug/pprof/goroutine?debug=2" | head -100

# 常见原因：
# - event channel 积压（消费者处理太慢）
# - 状态缓存未清理（已删除的目标仍在内存中）

# 临时缓解：定期重启（不影响探测连续性，探针自治）
sudo systemctl restart conmon
```

### 问题：目标探测间隔不准确（实际比配置大）

```bash
# 检查探测队列积压
curl -s http://localhost:8080/metrics | grep "conmon_probe_queue_size"

# 如果队列积压，说明并发数不够
# 增大并发数
conmon config set probe.concurrency 300
conmon server reload

# 或减少单次探测超时（让超时请求快速失败）
# timeout: 3s（默认 5s）
```

---

## 8. 探针节点问题

### 问题：探针离线后数据中断

```bash
# 探针离线期间，任务应自动转移到其他探针
# 如果没有其他探针，目标会进入 UNKNOWN 状态（不是 DOWN）

# 检查目标配置的探针列表
conmon target get <id> | jq '.probe_ids'
# 如果 probe_ids 为空，表示使用所有可用探针

# 解决：确保关键目标指定多个探针
conmon target update <id> --probe-ids "probe-bj-01,probe-sh-01"
```

### 问题：探针节点时间不同步

```bash
# 时间偏差超过 5s 会导致探测结果时间戳异常
# 在探针节点检查时间
date
timedatectl status

# 同步时间
sudo timedatectl set-ntp true
sudo ntpdate -u pool.ntp.org

# 在 conmon 日志中查看时间偏差告警
journalctl -u conmon-probe | grep "clock skew"
```

### 问题：探针任务分配不均

```bash
# 查看各探针的任务数
conmon probe list
# 若某个探针 TARGETS 显著多于其他探针，执行均衡

conmon probe rebalance

# 如果特定目标必须由特定探针探测（如内网目标只能用内网探针）
conmon target update <id> --probe-ids "probe-internal-01"
```

---

## 9. 状态机异常

### 问题：目标已恢复但仍显示 DOWN

```bash
# 查看目标最近探测结果
conmon target probe <id>  # 手动触发一次探测

# 查看状态机状态
conmon target get <id> | jq '.state'

# 检查 recovery_threshold 配置
conmon target get <id> | jq '.alert_config.recovery_threshold'
# 如果是 5，需要连续 5 次成功才恢复

# 手动强制重置状态（慎用）
curl -X POST http://localhost:8080/api/v1/targets/<id>/reset-state \
  -H "Authorization: Bearer $ADMIN_TOKEN"
```

### 问题：维护窗口过后仍未恢复告警

```bash
# 检查维护窗口配置
conmon target get <id> | jq '.maintenance'

# 手动结束维护窗口
conmon target maintenance end --id <id>

# 如果是 recurring 维护窗口，检查 cron 表达式
# 使用在线工具验证：https://crontab.guru/
```

### 问题：FLAPPING 状态无法退出

```bash
# FLAPPING 退出条件：10 分钟内变更次数 < 阈值
# 等待 10 分钟后自动退出

# 或手动重置
curl -X POST http://localhost:8080/api/v1/targets/<id>/reset-flap \
  -H "Authorization: Bearer $ADMIN_TOKEN"

# 长期建议：增大 flap_threshold 或增大探测间隔
```

---

## 10. 常见错误码参考

| 错误码 | 说明 | 解决方向 |
|--------|------|---------|
| `tcp_timeout` | TCP 连接超时 | 检查网络连通性、防火墙规则 |
| `tcp_refused` | TCP 连接被拒绝 | 目标服务未运行或端口错误 |
| `dns_resolve_error` | DNS 解析失败 | 检查 DNS 配置和探针节点 DNS 设置 |
| `dns_no_answer` | DNS 无应答记录 | 检查域名和查询类型配置 |
| `http_timeout` | HTTP 请求超时 | 增大 timeout，或检查服务响应速度 |
| `http_unexpected_status` | HTTP 状态码不符合预期 | 检查 expected_codes 配置 |
| `tls_handshake_error` | TLS 握手失败 | 检查证书有效性和 TLS 版本 |
| `tls_cert_expired` | TLS 证书已过期 | 立即更新目标服务的 TLS 证书 |
| `tls_cert_invalid` | TLS 证书无效 | 检查证书链是否完整 |
| `icmp_no_privilege` | ICMP 权限不足 | 执行 `setcap cap_net_raw+ep` |
| `icmp_timeout` | ICMP 无响应 | 检查目标是否允许 ICMP，或改用 TCP |
| `grpc_unavailable` | gRPC 服务不可达 | 检查 gRPC 端口和服务状态 |
| `context_deadline_exceeded` | 超时（Go context） | 增大 timeout 配置 |
| `body_mismatch` | 响应体不匹配 | 检查 `body_contains` 正则是否正确 |
| `websocket_upgrade_failed` | WebSocket 升级失败 | 检查目标是否支持 WebSocket 协议 |

---

## 附录：获取支持

1. **自助排查**：运行 `conmon doctor` 自动诊断
2. **查阅文档**：[GitHub Wiki](https://github.com/grandinfo/gi-conMon/wiki)
3. **提交 Issue**：[GitHub Issues](https://github.com/grandinfo/gi-conMon/issues)
4. **收集信息**：提交 Issue 时请附带 `conmon doctor` 输出和 `conmon version`

```bash
# 一键收集诊断信息
conmon support-bundle --output support-bundle.tar.gz
# 包含：版本信息、配置（脱敏）、近期日志、Prometheus 指标快照
```
