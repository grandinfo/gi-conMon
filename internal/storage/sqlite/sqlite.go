// Package sqlite provides a modernc/sqlite-backed Store implementation.
package sqlite

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	_ "modernc.org/sqlite"

	"github.com/grandinfo/gi-conMon/internal/model"
	"github.com/grandinfo/gi-conMon/internal/storage"
)

// Store is a SQLite-backed implementation of storage.Store.
type Store struct {
	db *sql.DB
}

// Open opens (or creates) the SQLite database at path and runs migrations.
func Open(path string) (*Store, error) {
	dsn := fmt.Sprintf("file:%s?_journal_mode=WAL&_busy_timeout=30000&_foreign_keys=on", path)
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("sqlite open: %w", err)
	}
	db.SetMaxOpenConns(1) // SQLite does not support concurrent writes
	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		db.Close()
		return nil, fmt.Errorf("sqlite migrate: %w", err)
	}
	return s, nil
}

func (s *Store) Close() error { return s.db.Close() }

// ---- migrations ------------------------------------------------------

func (s *Store) migrate() error {
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS targets (
			id           TEXT PRIMARY KEY,
			name         TEXT NOT NULL,
			host         TEXT NOT NULL,
			port         INTEGER DEFAULT 0,
			protocol     TEXT NOT NULL,
			interval_sec INTEGER NOT NULL DEFAULT 30,
			timeout_ms   INTEGER NOT NULL DEFAULT 5000,
			retries      INTEGER NOT NULL DEFAULT 3,
			priority     TEXT NOT NULL DEFAULT 'normal',
			tags         TEXT DEFAULT '[]',
			dependencies TEXT DEFAULT '[]',
			probe_ids    TEXT DEFAULT '[]',
			alert_config TEXT DEFAULT '{}',
			probe_config TEXT DEFAULT '{}',
			hooks        TEXT,
			maintenance  TEXT,
			enabled      INTEGER NOT NULL DEFAULT 1,
			created_at   DATETIME NOT NULL,
			updated_at   DATETIME NOT NULL,
			created_by   TEXT DEFAULT ''
		)`,
		`CREATE TABLE IF NOT EXISTS events (
			id           TEXT PRIMARY KEY,
			target_id    TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
			probe_node_id TEXT DEFAULT '',
			type         TEXT NOT NULL,
			from_status  TEXT DEFAULT '',
			to_status    TEXT NOT NULL,
			reason       TEXT DEFAULT '',
			message      TEXT DEFAULT '',
			duration_ms  INTEGER DEFAULT 0,
			tags         TEXT DEFAULT '[]',
			meta         TEXT DEFAULT '{}',
			timestamp    DATETIME NOT NULL,
			acknowledged INTEGER NOT NULL DEFAULT 0,
			acked_by     TEXT DEFAULT '',
			acked_at     DATETIME
		)`,
		`CREATE INDEX IF NOT EXISTS idx_events_target ON events (target_id, timestamp)`,
		`CREATE TABLE IF NOT EXISTS alerts (
			id                TEXT PRIMARY KEY,
			event_id          TEXT,
			target_id         TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
			rule_name         TEXT DEFAULT '',
			severity          TEXT NOT NULL,
			status            TEXT NOT NULL DEFAULT 'firing',
			title             TEXT DEFAULT '',
			body              TEXT DEFAULT '',
			channels          TEXT DEFAULT '[]',
			sent_at           DATETIME,
			resolved_at       DATETIME,
			escalation_level  INTEGER DEFAULT 1,
			next_escalate_at  DATETIME,
			group_id          TEXT DEFAULT ''
		)`,
		`CREATE INDEX IF NOT EXISTS idx_alerts_target ON alerts (target_id, sent_at)`,
		`CREATE TABLE IF NOT EXISTS probe_nodes (
			id               TEXT PRIMARY KEY,
			name             TEXT,
			location         TEXT,
			isp              TEXT,
			tags             TEXT DEFAULT '[]',
			ip_address       TEXT,
			version          TEXT,
			status           TEXT DEFAULT 'offline',
			last_heartbeat   DATETIME,
			assigned_targets INTEGER DEFAULT 0,
			capabilities    TEXT DEFAULT '[]',
			registered_at    DATETIME NOT NULL
		)`,
	}
	for _, stmt := range stmts {
		if _, err := s.db.Exec(stmt); err != nil {
			return fmt.Errorf("exec %q: %w", stmt[:min(50, len(stmt))], err)
		}
	}
	return nil
}

// ---- Targets ---------------------------------------------------------

func (s *Store) SaveTarget(ctx context.Context, t *model.Target) error {
	tags := toJSON(t.Tags)
	deps := toJSON(t.Dependencies)
	probeIDs := toJSON(t.ProbeIDs)
	alertCfg := toJSON(t.AlertConfig)
	probeCfg := toJSON(t.ProbeConfig)
	hooks := toJSON(t.Hooks)
	maint := toJSON(t.Maintenance)

	now := time.Now()
	if t.CreatedAt.IsZero() {
		t.CreatedAt = now
	}
	t.UpdatedAt = now

	_, err := s.db.ExecContext(ctx, `
		INSERT INTO targets
			(id,name,host,port,protocol,interval_sec,timeout_ms,retries,priority,
			 tags,dependencies,probe_ids,alert_config,probe_config,hooks,maintenance,
			 enabled,created_at,updated_at,created_by)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT(id) DO UPDATE SET
			name=excluded.name, host=excluded.host, port=excluded.port,
			protocol=excluded.protocol, interval_sec=excluded.interval_sec,
			timeout_ms=excluded.timeout_ms, retries=excluded.retries,
			priority=excluded.priority, tags=excluded.tags,
			dependencies=excluded.dependencies, probe_ids=excluded.probe_ids,
			alert_config=excluded.alert_config, probe_config=excluded.probe_config,
			hooks=excluded.hooks, maintenance=excluded.maintenance,
			enabled=excluded.enabled, updated_at=excluded.updated_at`,
		t.ID, t.Name, t.Host, t.Port, t.Protocol,
		t.IntervalSec, t.TimeoutMs, t.Retries, t.Priority,
		tags, deps, probeIDs, alertCfg, probeCfg, hooks, maint,
		boolToInt(t.Enabled), t.CreatedAt, t.UpdatedAt, t.CreatedBy,
	)
	return err
}

func (s *Store) GetTarget(ctx context.Context, id string) (*model.Target, error) {
	row := s.db.QueryRowContext(ctx, `SELECT * FROM targets WHERE id=?`, id)
	return scanTarget(row)
}

func (s *Store) ListTargets(ctx context.Context, q storage.TargetQuery) ([]*model.Target, int64, error) {
	where, args := buildTargetWhere(q)
	limit := q.Limit
	if limit <= 0 {
		limit = 100
	}

	// Count
	var total int64
	countSQL := "SELECT COUNT(*) FROM targets" + where
	if err := s.db.QueryRowContext(ctx, countSQL, args...).Scan(&total); err != nil {
		return nil, 0, err
	}

	// Data
	args = append(args, limit, q.Offset)
	rows, err := s.db.QueryContext(ctx,
		"SELECT * FROM targets"+where+" ORDER BY name LIMIT ? OFFSET ?", args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	var targets []*model.Target
	for rows.Next() {
		t, err := scanTarget(rows)
		if err != nil {
			return nil, 0, err
		}
		targets = append(targets, t)
	}
	return targets, total, rows.Err()
}

func (s *Store) DeleteTarget(ctx context.Context, id string) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM targets WHERE id=?`, id)
	return err
}

// ---- Events ----------------------------------------------------------

func (s *Store) SaveEvent(ctx context.Context, e *model.Event) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT OR IGNORE INTO events
			(id,target_id,probe_node_id,type,from_status,to_status,reason,message,
			 duration_ms,tags,meta,timestamp,acknowledged,acked_by,acked_at)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
		e.ID, e.TargetID, e.ProbeNodeID, string(e.Type),
		string(e.FromStatus), string(e.ToStatus),
		e.Reason, e.Message, e.DurationMs,
		toJSON(e.Tags), toJSON(e.Meta),
		e.Timestamp,
		boolToInt(e.Acknowledged), e.AckedBy, e.AckedAt,
	)
	return err
}

func (s *Store) GetEvent(ctx context.Context, id string) (*model.Event, error) {
	row := s.db.QueryRowContext(ctx, `SELECT * FROM events WHERE id=?`, id)
	return scanEvent(row)
}

func (s *Store) ListEvents(ctx context.Context, q storage.EventQuery) ([]*model.Event, int64, error) {
	where, args := buildEventWhere(q)
	limit := q.Limit
	if limit <= 0 {
		limit = 50
	}
	var total int64
	if err := s.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM events"+where, args...).Scan(&total); err != nil {
		return nil, 0, err
	}
	args = append(args, limit, q.Offset)
	rows, err := s.db.QueryContext(ctx,
		"SELECT * FROM events"+where+" ORDER BY timestamp DESC LIMIT ? OFFSET ?", args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var events []*model.Event
	for rows.Next() {
		ev, err := scanEvent(rows)
		if err != nil {
			return nil, 0, err
		}
		events = append(events, ev)
	}
	return events, total, rows.Err()
}

func (s *Store) AckEvent(ctx context.Context, id, userID string) error {
	now := time.Now()
	_, err := s.db.ExecContext(ctx,
		`UPDATE events SET acknowledged=1,acked_by=?,acked_at=? WHERE id=?`,
		userID, now, id)
	return err
}

// ---- Alerts ----------------------------------------------------------

func (s *Store) SaveAlert(ctx context.Context, a *model.Alert) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT OR REPLACE INTO alerts
			(id,event_id,target_id,rule_name,severity,status,title,body,channels,
			 sent_at,resolved_at,escalation_level,next_escalate_at,group_id)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
		a.ID, a.EventID, a.TargetID, a.RuleName,
		string(a.Severity), string(a.Status),
		a.Title, a.Body, toJSON(a.Channels),
		a.SentAt, a.ResolvedAt, a.EscalationLevel,
		a.NextEscalateAt, a.GroupID,
	)
	return err
}

func (s *Store) GetAlert(ctx context.Context, id string) (*model.Alert, error) {
	row := s.db.QueryRowContext(ctx, `SELECT * FROM alerts WHERE id=?`, id)
	return scanAlert(row)
}

func (s *Store) ListAlerts(ctx context.Context, q storage.AlertQuery) ([]*model.Alert, int64, error) {
	var conds []string
	var args []any
	if q.TargetID != "" {
		conds = append(conds, "target_id=?")
		args = append(args, q.TargetID)
	}
	if q.Status != "" {
		conds = append(conds, "status=?")
		args = append(args, string(q.Status))
	}
	where := ""
	if len(conds) > 0 {
		where = " WHERE " + strings.Join(conds, " AND ")
	}
	limit := q.Limit
	if limit <= 0 {
		limit = 50
	}
	var total int64
	if err := s.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM alerts"+where, args...).Scan(&total); err != nil {
		return nil, 0, err
	}
	args = append(args, limit, q.Offset)
	rows, err := s.db.QueryContext(ctx,
		"SELECT * FROM alerts"+where+" ORDER BY sent_at DESC LIMIT ? OFFSET ?", args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var alerts []*model.Alert
	for rows.Next() {
		a, err := scanAlert(rows)
		if err != nil {
			return nil, 0, err
		}
		alerts = append(alerts, a)
	}
	return alerts, total, rows.Err()
}

func (s *Store) UpdateAlert(ctx context.Context, a *model.Alert) error {
	_, err := s.db.ExecContext(ctx,
		`UPDATE alerts SET status=?,resolved_at=?,escalation_level=?,next_escalate_at=? WHERE id=?`,
		string(a.Status), a.ResolvedAt, a.EscalationLevel, a.NextEscalateAt, a.ID)
	return err
}

// ---- ProbeNodes ------------------------------------------------------

func (s *Store) SaveProbeNode(ctx context.Context, n *model.ProbeNode) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT OR REPLACE INTO probe_nodes
			(id,name,location,isp,tags,ip_address,version,status,
			 last_heartbeat,assigned_targets,capabilities,registered_at)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?)`,
		n.ID, n.Name, n.Location, n.ISP,
		toJSON(n.Tags), n.IPAddress, n.Version, string(n.Status),
		n.LastHeartbeat, n.AssignedTargets, toJSON(n.Capabilities), n.RegisteredAt,
	)
	return err
}

func (s *Store) GetProbeNode(ctx context.Context, id string) (*model.ProbeNode, error) {
	row := s.db.QueryRowContext(ctx, `SELECT * FROM probe_nodes WHERE id=?`, id)
	return scanProbeNode(row)
}

func (s *Store) ListProbeNodes(ctx context.Context) ([]*model.ProbeNode, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT * FROM probe_nodes ORDER BY name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var nodes []*model.ProbeNode
	for rows.Next() {
		n, err := scanProbeNode(rows)
		if err != nil {
			return nil, err
		}
		nodes = append(nodes, n)
	}
	return nodes, rows.Err()
}

// ---- Cleanup ---------------------------------------------------------

func (s *Store) Cleanup(ctx context.Context, retentionEvents, retentionAlerts time.Duration) error {
	cutEvents := time.Now().Add(-retentionEvents)
	cutAlerts := time.Now().Add(-retentionAlerts)
	if _, err := s.db.ExecContext(ctx, `DELETE FROM events WHERE timestamp < ?`, cutEvents); err != nil {
		return err
	}
	_, err := s.db.ExecContext(ctx, `DELETE FROM alerts WHERE sent_at < ?`, cutAlerts)
	return err
}

// ---- scanner helpers -------------------------------------------------

type scanner interface {
	Scan(dest ...any) error
}

func scanTarget(row scanner) (*model.Target, error) {
	var t model.Target
	var tags, deps, probeIDs, alertCfg, probeCfg, hooks, maint string
	var enabled int
	err := row.Scan(
		&t.ID, &t.Name, &t.Host, &t.Port, &t.Protocol,
		&t.IntervalSec, &t.TimeoutMs, &t.Retries, &t.Priority,
		&tags, &deps, &probeIDs, &alertCfg, &probeCfg,
		&hooks, &maint, &enabled,
		&t.CreatedAt, &t.UpdatedAt, &t.CreatedBy,
	)
	if err != nil {
		return nil, err
	}
	t.Enabled = enabled == 1
	fromJSON(tags, &t.Tags)
	fromJSON(deps, &t.Dependencies)
	fromJSON(probeIDs, &t.ProbeIDs)
	fromJSON(alertCfg, &t.AlertConfig)
	fromJSON(probeCfg, &t.ProbeConfig)
	if hooks != "" && hooks != "null" {
		fromJSON(hooks, &t.Hooks)
	}
	if maint != "" && maint != "null" {
		fromJSON(maint, &t.Maintenance)
	}
	return &t, nil
}

func scanEvent(row scanner) (*model.Event, error) {
	var e model.Event
	var tags, meta string
	var acked int
	err := row.Scan(
		&e.ID, &e.TargetID, &e.ProbeNodeID,
		&e.Type, &e.FromStatus, &e.ToStatus,
		&e.Reason, &e.Message, &e.DurationMs,
		&tags, &meta, &e.Timestamp,
		&acked, &e.AckedBy, &e.AckedAt,
	)
	if err != nil {
		return nil, err
	}
	e.Acknowledged = acked == 1
	fromJSON(tags, &e.Tags)
	fromJSON(meta, &e.Meta)
	return &e, nil
}

func scanAlert(row scanner) (*model.Alert, error) {
	var a model.Alert
	var channels string
	err := row.Scan(
		&a.ID, &a.EventID, &a.TargetID, &a.RuleName,
		&a.Severity, &a.Status, &a.Title, &a.Body,
		&channels, &a.SentAt, &a.ResolvedAt,
		&a.EscalationLevel, &a.NextEscalateAt, &a.GroupID,
	)
	if err != nil {
		return nil, err
	}
	fromJSON(channels, &a.Channels)
	return &a, nil
}

func scanProbeNode(row scanner) (*model.ProbeNode, error) {
	var n model.ProbeNode
	var tags, caps string
	err := row.Scan(
		&n.ID, &n.Name, &n.Location, &n.ISP,
		&tags, &n.IPAddress, &n.Version, &n.Status,
		&n.LastHeartbeat, &n.AssignedTargets, &caps, &n.RegisteredAt,
	)
	if err != nil {
		return nil, err
	}
	fromJSON(tags, &n.Tags)
	fromJSON(caps, &n.Capabilities)
	return &n, nil
}

// ---- query builders --------------------------------------------------

func buildTargetWhere(q storage.TargetQuery) (string, []any) {
	var conds []string
	var args []any
	if q.Protocol != "" {
		conds = append(conds, "protocol=?")
		args = append(args, q.Protocol)
	}
	if q.Search != "" {
		conds = append(conds, "(name LIKE ? OR host LIKE ?)")
		like := "%" + q.Search + "%"
		args = append(args, like, like)
	}
	if len(conds) == 0 {
		return "", args
	}
	return " WHERE " + strings.Join(conds, " AND "), args
}

func buildEventWhere(q storage.EventQuery) (string, []any) {
	var conds []string
	var args []any
	if q.TargetID != "" {
		conds = append(conds, "target_id=?")
		args = append(args, q.TargetID)
	}
	if !q.Since.IsZero() {
		conds = append(conds, "timestamp >= ?")
		args = append(args, q.Since)
	}
	if !q.Until.IsZero() {
		conds = append(conds, "timestamp <= ?")
		args = append(args, q.Until)
	}
	if len(conds) == 0 {
		return "", args
	}
	return " WHERE " + strings.Join(conds, " AND "), args
}

// ---- json helpers ----------------------------------------------------

func toJSON(v any) string {
	if v == nil {
		return "null"
	}
	b, _ := json.Marshal(v)
	return string(b)
}

func fromJSON(s string, v any) {
	if s == "" || s == "null" {
		return
	}
	_ = json.Unmarshal([]byte(s), v)
}

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
