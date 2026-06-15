# conMon 维护指南

**版本**：v2.0 · **日期**：2026-06-15

---

## 目录

1. [日常运维操作](#1-日常运维操作)
2. [配置管理](#2-配置管理)
3. [数据库维护](#3-数据库维护)
4. [日志管理](#4-日志管理)
5. [性能调优](#5-性能调优)
6. [备份与恢复](#6-备份与恢复)
7. [监控 conMon 自身](#7-监控-conmon-自身)
8. [探针节点维护](#8-探针节点维护)
9. [安全维护](#9-安全维护)
10. [容量规划](#10-容量规划)

---

## 1. 日常运维操作

### 1.1 服务状态检查

```bash
# 服务进程状态
sudo systemctl status conmon

# 健康检查端点
curl -s http://localhost:8080/health | jq

# 就绪检查（检查所有依赖）
curl -s http://localhost:8080/ready | jq

# 查看当前监控目标状态汇总
conmon status
```

### 1.2 服务启停操作

```bash
# 启动
sudo systemctl start conmon

# 停止（优雅关闭，等待进行中的探测完成）
sudo systemctl stop conmon

# 重启
sudo systemctl restart conmon

# 热重载配置（不重启进程，不中断探测）
sudo systemctl reload conmon
# 或
conmon server reload

# 查看最近 100 行日志
sudo journalctl -u conmon -n 100
sudo journalctl -u conmon -f  # 实时跟踪
```

### 1.3 探针节点管理

```bash
# 查看所有探针节点状态
conmon probe list

# 输出示例：
# ID               NAME        LOCATION  STATUS   TARGETS  LAST_SEEN
# probe-bj-01      北京-电信   北京       online   1250     2s ago
# probe-sh-01      上海-联通   上海       online   1250     1s ago
# probe-gz-01      广州-移动   广州       offline  0        5m ago

# 查看探针详情
conmon probe get probe-bj-01

# 强制重新分配任务（探针恢复后）
conmon probe rebalance

# 从集群移除探针
conmon probe remove probe-old-01
```

### 1.4 告警确认与处理

```bash
# 查看当前 FIRING 的告警
conmon alert list --status firing

# 确认告警
conmon alert ack alert-001 --comment "已定位，正在处理"

# 批量确认某目标的所有告警
conmon alert ack-all --target target-001

# 创建全局静默（紧急情况用）
conmon silence create --duration 30m --reason "全局升级"

# 恢复静默
conmon silence delete <silence-id>
```

---

## 2. 配置管理

### 2.1 配置变更流程

```
1. 修改配置文件  →  2. 验证配置  →  3. 热重载  →  4. 验证生效
```

```bash
# 步骤 2：验证配置语法和语义
conmon config validate -c /etc/conmon/conmon.yaml

# 步骤 3：热重载（服务不中断）
conmon server reload

# 步骤 4：查看目标列表确认变更生效
conmon target list | grep "新目标名称"
```

### 2.2 动态添加目标（无需重启）

```bash
# 通过 API 动态添加，立即生效
curl -X POST http://localhost:8080/api/v1/targets \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "新添加的服务",
    "host": "new-service.example.com",
    "port": 443,
    "protocol": "https",
    "interval": "30s",
    "tags": ["生产"]
  }'
```

### 2.3 配置版本管理

建议将配置文件纳入 Git 版本控制：

```bash
cd /etc/conmon
git init
echo "*.env" >> .gitignore        # 排除敏感环境变量文件
echo "*.key" >> .gitignore
echo "*.pem" >> .gitignore
git add conmon.yaml
git commit -m "init: 初始配置"

# 每次变更后提交
git add conmon.yaml
git commit -m "feat: 新增支付网关监控"
git push origin main
```

---

## 3. 数据库维护

### 3.1 PostgreSQL 日常维护

```bash
# 查看数据库大小
psql -U conmon -d conmon -c "
SELECT
  table_name,
  pg_size_pretty(pg_total_relation_size(quote_ident(table_name))) AS total_size
FROM information_schema.tables
WHERE table_schema = 'public'
ORDER BY pg_total_relation_size(quote_ident(table_name)) DESC;"

# 查看死元组（需要 VACUUM）
psql -U conmon -d conmon -c "
SELECT relname, n_dead_tup, n_live_tup,
       round(n_dead_tup::numeric/nullif(n_live_tup+n_dead_tup, 0)*100, 2) AS dead_pct
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC;"

# 手动 VACUUM（通常 autovacuum 会自动处理）
psql -U conmon -d conmon -c "VACUUM ANALYZE events;"
psql -U conmon -d conmon -c "VACUUM ANALYZE alerts;"

# 重建索引（解决索引膨胀）
psql -U conmon -d conmon -c "REINDEX TABLE CONCURRENTLY events;"
```

### 3.2 数据清理（过期数据）

conMon 内置自动清理任务，也可手动触发：

```bash
# 触发数据清理（按配置的 retention 策略清理过期数据）
conmon db cleanup

# 查看各表行数与占用
conmon db stats

# 手动清理 30 天前的 DEBUG 级别日志
psql -U conmon -d conmon -c "
DELETE FROM events
WHERE timestamp < NOW() - INTERVAL '30 days'
  AND type = 'debug';"
```

### 3.3 InfluxDB 维护

```bash
# 查看 bucket 使用量
influx bucket list --org conmon

# 手动触发降采样（通常由 Task 自动执行）
influx task list --org conmon
influx task run --id <task-id>

# 删除某个目标的所有历史数据（目标删除后清理）
influx delete \
  --org conmon \
  --bucket conmon_metrics \
  --start '2020-01-01T00:00:00Z' \
  --stop '2030-01-01T00:00:00Z' \
  --predicate '_measurement="probe_result" AND target_id="target-001"'
```

### 3.4 数据库连接池监控

```bash
# 查看当前连接数
psql -U conmon -d conmon -c "
SELECT count(*), state, wait_event_type, wait_event
FROM pg_stat_activity
WHERE datname = 'conmon'
GROUP BY state, wait_event_type, wait_event;"

# 如果连接数过多，查看 conmon 配置
grep -A5 "pool" /etc/conmon/conmon.yaml
```

---

## 4. 日志管理

### 4.1 日志查看

```bash
# systemd journal 查看
sudo journalctl -u conmon --since "1 hour ago"
sudo journalctl -u conmon --since "2026-06-15" --until "2026-06-16"
sudo journalctl -u conmon -p err  # 只显示错误级别

# 文件日志查看（如配置了文件输出）
tail -f /var/log/conmon/conmon.log | jq -r '.ts + " " + .level + " " + .msg'

# 过滤特定目标的日志
cat /var/log/conmon/conmon.log | jq 'select(.target_id == "target-001")'

# 过滤 ERROR 级别
cat /var/log/conmon/conmon.log | jq 'select(.level == "ERROR")'
```

### 4.2 日志级别动态调整

```bash
# 临时提升日志级别到 DEBUG（排查问题时使用）
curl -X PUT http://localhost:8080/api/v1/admin/log-level \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -d '{"level": "debug"}'

# 排查完毕后恢复 INFO
curl -X PUT http://localhost:8080/api/v1/admin/log-level \
  -d '{"level": "info"}'
```

### 4.3 日志轮转配置

如使用 logrotate（文件日志）：

```bash
cat > /etc/logrotate.d/conmon << 'EOF'
/var/log/conmon/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    postrotate
        systemctl reload conmon 2>/dev/null || true
    endscript
}
EOF
```

### 4.4 日志导出与审计

```bash
# 导出审计日志（某时间段内所有操作）
conmon audit export \
  --since "2026-06-01" \
  --until "2026-06-30" \
  --output audit-june.csv

# 查看特定用户的操作记录
conmon audit query --user admin --since "24h"

# 查看配置变更记录
conmon audit query --action "create_target,update_target,delete_target" --since "7d"
```

---

## 5. 性能调优

### 5.1 探测并发调优

```yaml
# conmon.yaml 性能相关配置
probe:
  concurrency: 200          # 增大并发数（默认 100）
  # 建议：目标数 / 平均探测间隔(s) × 2
  # 例如：5000 目标，平均间隔 30s → 5000/30*2 ≈ 333

  queue_size:
    high: 2000              # 高优先级队列容量
    normal: 20000           # 普通队列容量
    low: 100000             # 低优先级队列容量

  batch_report_size: 500    # 批量上报结果数（减少网络 RPC 次数）
  batch_report_interval: "200ms"
```

### 5.2 存储写入调优

```yaml
storage:
  timeseries:
    batch_size: 2000          # 批量写入 InfluxDB 的条数（增大以提升吞吐）
    flush_interval: "1s"      # 最长等待时间
    max_retry: 3              # 写入失败重试次数

  postgresql:
    pool_max: 30              # 连接池最大连接数
    pool_min: 5               # 最小保活连接数
    conn_max_lifetime: "1h"
    conn_max_idle_time: "10m"
    statement_timeout: "30s"  # 单条 SQL 超时
```

### 5.3 内存调优

```bash
# 查看内存使用（Prometheus 指标）
curl -s http://localhost:8080/metrics | grep conmon_memory

# 如果内存持续增长，检查状态缓存配置
# 每个目标状态约占 2KB 内存
# 5000 目标 × 2KB ≈ 10MB（状态缓存）

# 调整 GC 频率（Go 运行时参数）
# 在 /etc/conmon/conmon.env 中添加：
GOGC=80    # 降低 GC 触发阈值（默认 100），减少峰值内存
```

### 5.4 查询性能调优

```bash
# 检查慢查询（PostgreSQL）
psql -U conmon -d conmon -c "
SELECT query, calls, mean_exec_time, total_exec_time
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 20;"

# 添加缺失索引（根据慢查询分析）
psql -U conmon -d conmon -c "
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_events_target_ts
ON events (target_id, timestamp DESC)
WHERE type = 'status_changed';"
```

### 5.5 pprof 性能分析

```bash
# 开启 pprof（在配置中启用）
# debug.pprof: true

# CPU 剖析（采样 30 秒）
go tool pprof http://localhost:6060/debug/pprof/profile?seconds=30

# 内存分配分析
go tool pprof http://localhost:6060/debug/pprof/heap

# goroutine 泄漏检测
curl http://localhost:6060/debug/pprof/goroutine?debug=1 | head -50

# 可视化（需要安装 graphviz）
go tool pprof -http=:8888 http://localhost:6060/debug/pprof/profile
```

---

## 6. 备份与恢复

### 6.1 自动备份脚本

```bash
cat > /usr/local/bin/conmon-backup.sh << 'SCRIPT'
#!/bin/bash
set -euo pipefail

BACKUP_DIR="/backup/conmon"
DATE=$(date +%Y%m%d_%H%M%S)
RETENTION_DAYS=30

mkdir -p "$BACKUP_DIR"

# 备份 PostgreSQL
echo "[$(date)] 备份 PostgreSQL..."
pg_dump -U conmon -Fc conmon > "$BACKUP_DIR/postgres_$DATE.dump"
gzip "$BACKUP_DIR/postgres_$DATE.dump"

# 备份配置文件
echo "[$(date)] 备份配置文件..."
tar -czf "$BACKUP_DIR/config_$DATE.tar.gz" /etc/conmon/

# 备份 InfluxDB（可选，数据量大时考虑增量备份）
# influx backup "$BACKUP_DIR/influxdb_$DATE" --org conmon

# 清理旧备份
find "$BACKUP_DIR" -name "*.gz" -mtime +$RETENTION_DAYS -delete

echo "[$(date)] 备份完成: $BACKUP_DIR"
ls -lh "$BACKUP_DIR" | tail -5
SCRIPT

chmod +x /usr/local/bin/conmon-backup.sh

# 每天凌晨 3 点自动备份
echo "0 3 * * * /usr/local/bin/conmon-backup.sh >> /var/log/conmon-backup.log 2>&1" | crontab -
```

### 6.2 恢复 PostgreSQL

```bash
# 停止 conmon 服务
sudo systemctl stop conmon

# 恢复数据库（覆盖恢复）
dropdb -U postgres conmon
createdb -U postgres -O conmon conmon
pg_restore -U conmon -d conmon /backup/conmon/postgres_20260615_030000.dump.gz

# 验证数据完整性
psql -U conmon -d conmon -c "SELECT COUNT(*) FROM targets;"
psql -U conmon -d conmon -c "SELECT COUNT(*) FROM events;"

# 重启服务
sudo systemctl start conmon
```

### 6.3 恢复配置文件

```bash
tar -xzf /backup/conmon/config_20260615_030000.tar.gz -C /

# 验证配置
conmon config validate -c /etc/conmon/conmon.yaml

# 重载
sudo systemctl reload conmon
```

---

## 7. 监控 conMon 自身

### 7.1 Prometheus 采集配置

```yaml
# prometheus.yml
scrape_configs:
  - job_name: 'conmon'
    scrape_interval: 15s
    static_configs:
      - targets: ['conmon-server:8080']
    metrics_path: /metrics
    bearer_token: "your-prometheus-token"
```

### 7.2 关键告警规则

```yaml
# conmon-alert-rules.yaml（Prometheus AlertManager）
groups:
  - name: conmon-self
    rules:
      # conmon 服务不可用
      - alert: ConmonDown
        expr: up{job="conmon"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "conMon 服务不可用"

      # 探针节点离线
      - alert: ConmonProbeOffline
        expr: conmon_probe_nodes_online < conmon_probe_nodes_total * 0.8
        for: 5m
        labels:
          severity: error
        annotations:
          summary: "超过 20% 的探针节点离线"

      # 写入积压
      - alert: ConmonStorageBacklog
        expr: conmon_storage_queue_size{backend="influxdb"} > 10000
        for: 2m
        labels:
          severity: warn
        annotations:
          summary: "InfluxDB 写入队列积压超过 1 万条"

      # goroutine 泄漏
      - alert: ConmonGoroutineLeak
        expr: conmon_goroutines_current > 10000
        for: 5m
        labels:
          severity: warn

      # 高延迟告警发送
      - alert: ConmonAlertNotifyHigh
        expr: histogram_quantile(0.99, conmon_alert_notify_duration_ms_bucket) > 5000
        for: 3m
        labels:
          severity: warn
        annotations:
          summary: "告警通知发送 P99 延迟超过 5 秒"
```

### 7.3 Grafana Dashboard

导入内置 Dashboard（Dashboard ID 可在 Grafana.com 搜索 "conmon"）：

```bash
# 通过 Grafana API 导入
curl -X POST http://grafana:3000/api/dashboards/import \
  -H "Content-Type: application/json" \
  -u admin:password \
  -d @deployments/grafana/conmon-overview.json
```

---

## 8. 探针节点维护

### 8.1 探针升级

```bash
# 在探针节点上
# 停止探针（任务会自动转移到其他探针）
sudo systemctl stop conmon-probe

# 升级二进制
curl -LO ".../conmon-probe-linux-amd64.tar.gz"
sudo tar -xzf conmon-probe-linux-amd64.tar.gz -C /usr/local/bin/

# 重启
sudo systemctl start conmon-probe

# 在控制端验证探针重新上线
conmon probe list
```

### 8.2 探针证书更新

探针证书默认有效期 1 年，到期前 30 天自动告警：

```bash
# 查看探针证书到期时间
conmon probe cert-expiry

# 手动更新探针证书
conmon pki renew-probe --probe-id probe-bj-01 --output /tmp/probe-bj-01/
# 将新证书分发到探针节点
scp /tmp/probe-bj-01/probe.crt probe@bj-01:/etc/conmon-probe/
# 探针热重载证书（无需重启）
ssh probe@bj-01 "sudo kill -HUP \$(pgrep conmon-probe)"
```

### 8.3 探针节点扩容

```bash
# 在控制端预生成探针证书
conmon pki issue-probe --ca /etc/conmon/pki/ --probe-id probe-cd-01 \
  --name "成都-电信" --output /tmp/probe-cd-01/

# 在新探针节点安装 conmon-probe
# （参考部署指南 7.1）

# 验证探针注册
conmon probe list | grep probe-cd-01

# 手动均衡任务分配
conmon probe rebalance
```

---

## 9. 安全维护

### 9.1 定期安全检查清单

```bash
# 每月执行
□ 检查并轮换 API Token（超过 90 天的 Token）
□ 检查账号权限（是否存在不需要的管理员账号）
□ 检查 TLS 证书有效期
□ 检查探针证书有效期
□ 查看登录失败日志（暴力破解尝试）
□ 更新 conmon 到最新安全版本
□ 检查数据库账号权限是否最小化

# 查看 90 天未使用的 Token
conmon token list --unused-since 90d

# 查看登录失败记录
conmon audit query --action "login_failed" --since "30d"
```

### 9.2 TLS 证书更新

```bash
# 查看所有证书到期时间
conmon tls status

# Let's Encrypt 自动续期
certbot renew --dry-run   # 先演练
certbot renew             # 实际续期
sudo systemctl reload conmon

# 自签证书手动更新
conmon pki renew-server --ca /etc/conmon/pki/ --output /etc/conmon/pki/server/
sudo systemctl reload conmon
```

### 9.3 账号与权限管理

```bash
# 创建用户
conmon user create --username ops-user --role operator --email ops@example.com

# 修改角色
conmon user update ops-user --role reader

# 禁用账号（临时）
conmon user disable ops-user

# 删除账号
conmon user delete ops-user

# 列出所有 API Token
conmon token list

# 创建只读 Token（给 Prometheus 使用）
conmon token create --name "prometheus-readonly" --role reader --expire 365d

# 撤销 Token
conmon token revoke <token-id>
```

---

## 10. 容量规划

### 10.1 资源使用估算

| 监控目标数 | CPU | 内存 | PostgreSQL | InfluxDB | 日志磁盘/天 |
|-----------|-----|------|-----------|---------|------------|
| 500       | 0.5 核 | 256 MB | 2 GB | 5 GB | 100 MB |
| 2,000     | 1 核 | 512 MB | 8 GB | 20 GB | 400 MB |
| 5,000     | 2 核 | 1 GB | 20 GB | 50 GB | 1 GB |
| 20,000    | 8 核 | 4 GB | 80 GB | 200 GB | 4 GB |

> 以上估算基于：平均探测间隔 30s，7 天原始数据保留，90 天事件保留。

### 10.2 监控磁盘使用

```bash
# 查看各存储占用
conmon db stats

# 查看 PostgreSQL 表大小增长趋势
psql -U conmon -d conmon -c "
SELECT
  relname,
  pg_size_pretty(pg_total_relation_size(relid)) AS size,
  pg_size_pretty(pg_relation_size(relid)) AS table_size,
  pg_size_pretty(pg_indexes_size(relid)) AS index_size
FROM pg_catalog.pg_statio_user_tables
ORDER BY pg_total_relation_size(relid) DESC;"
```

### 10.3 预警阈值建议

| 指标 | 警告 | 严重 |
|------|------|------|
| CPU 使用率 | >70% | >90% |
| 内存使用率 | >75% | >90% |
| 磁盘使用率 | >70% | >85% |
| PostgreSQL 连接数 | >80% pool | >95% pool |
| InfluxDB 写入队列 | >5,000 | >20,000 |
| goroutine 数 | >5,000 | >10,000 |
| 探针离线比例 | >10% | >30% |

---

*运维遇到问题请参阅《故障排查指南》或提交 Issue。*
