// Package model defines the core domain types used across conMon.
package model

import "time"

// Status represents a monitor target's operational state.
type Status string

const (
	StatusUnknown     Status = "UNKNOWN"
	StatusUp          Status = "UP"
	StatusDown        Status = "DOWN"
	StatusDegraded    Status = "DEGRADED"
	StatusFlapping    Status = "FLAPPING"
	StatusMaintenance Status = "MAINTENANCE"
	StatusSilent      Status = "SILENT"
)

// Protocol is the probe protocol identifier.
type Protocol string

const (
	ProtoICMP      Protocol = "icmp"
	ProtoTCP       Protocol = "tcp"
	ProtoTCPSYN    Protocol = "tcp-syn"
	ProtoUDP       Protocol = "udp"
	ProtoHTTP      Protocol = "http"
	ProtoHTTPS     Protocol = "https"
	ProtoDNS       Protocol = "dns"
	ProtoTLS       Protocol = "tls"
	ProtoWebSocket Protocol = "websocket"
	ProtoGRPC      Protocol = "grpc"
)

// Priority controls the probe scheduler queue selection.
type Priority string

const (
	PriorityHigh   Priority = "high"
	PriorityNormal Priority = "normal"
	PriorityLow    Priority = "low"
)

// EventType classifies a monitoring event.
type EventType string

const (
	EventStatusChanged EventType = "status_changed"
	EventDegraded      EventType = "degraded"
	EventFlapping      EventType = "flapping"
	EventCertExpiry    EventType = "cert_expiry"
	EventMaintenance   EventType = "maintenance"
)

// AlertStatus is the lifecycle state of a single alert.
type AlertStatus string

const (
	AlertFiring      AlertStatus = "firing"
	AlertResolved    AlertStatus = "resolved"
	AlertAcknowledged AlertStatus = "acknowledged"
	AlertSilenced    AlertStatus = "silenced"
)

// Severity is the notification urgency level.
type Severity string

const (
	SeverityCritical Severity = "critical"
	SeverityError    Severity = "error"
	SeverityWarn     Severity = "warn"
	SeverityInfo     Severity = "info"
)

// ---------------------------------------------------------------------
// Target
// ---------------------------------------------------------------------

// Target is the primary monitored network endpoint.
type Target struct {
	ID           string            `json:"id"`
	Name         string            `json:"name"`
	Host         string            `json:"host"`
	Port         int               `json:"port"`
	Protocol     Protocol          `json:"protocol"`
	IntervalSec  int               `json:"interval_sec"`
	TimeoutMs    int               `json:"timeout_ms"`
	Retries      int               `json:"retries"`
	Priority     Priority          `json:"priority"`
	Tags         []string          `json:"tags"`
	Dependencies []string          `json:"dependencies"`
	ProbeIDs     []string          `json:"probe_ids"`
	AlertConfig  AlertConfig       `json:"alert_config"`
	ProbeConfig  map[string]any    `json:"probe_config"`
	Hooks        *HookConfig       `json:"hooks,omitempty"`
	Maintenance  *MaintenanceWindow `json:"maintenance,omitempty"`
	Enabled      bool              `json:"enabled"`
	CreatedAt    time.Time         `json:"created_at"`
	UpdatedAt    time.Time         `json:"updated_at"`
	CreatedBy    string            `json:"created_by"`
}

// AlertConfig holds per-target alert thresholds and channel references.
type AlertConfig struct {
	DownThreshold     int      `json:"down_threshold"`
	RecoveryThreshold int      `json:"recovery_threshold"`
	LatencyWarnMs     int64    `json:"latency_warn_ms"`
	PacketLossWarnPct float64  `json:"packet_loss_warn_pct"`
	AlertChannels     []string `json:"alert_channels"`
	CertWarnDays      int      `json:"cert_warn_days"`
}

// HookConfig holds shell scripts to execute on state transitions.
type HookConfig struct {
	OnDown     string `json:"on_down"`
	OnUp       string `json:"on_up"`
	OnDegraded string `json:"on_degraded"`
	TimeoutSec int    `json:"timeout_sec"`
}

// MaintenanceWindow suppresses alerts during a scheduled window.
type MaintenanceWindow struct {
	Start     time.Time `json:"start"`
	End       time.Time `json:"end"`
	Recurring string    `json:"recurring"` // cron expression; empty = one-shot
	Reason    string    `json:"reason"`
}

// IsActive returns true if the window is currently in effect.
func (m *MaintenanceWindow) IsActive(now time.Time) bool {
	if m == nil {
		return false
	}
	return now.After(m.Start) && now.Before(m.End)
}

// DefaultTarget returns a Target populated with sensible defaults.
func DefaultTarget() Target {
	return Target{
		IntervalSec: 30,
		TimeoutMs:   5000,
		Retries:     3,
		Priority:    PriorityNormal,
		Enabled:     true,
		AlertConfig: AlertConfig{
			DownThreshold:     3,
			RecoveryThreshold: 2,
			CertWarnDays:      30,
		},
	}
}

// ---------------------------------------------------------------------
// ProbeResult
// ---------------------------------------------------------------------

// ProbeResult is the outcome of a single probe execution.
type ProbeResult struct {
	TargetID    string         `json:"target_id"`
	ProbeNodeID string         `json:"probe_node_id"`
	Seq         int64          `json:"seq"`
	Timestamp   time.Time      `json:"timestamp"`
	Success     bool           `json:"success"`
	LatencyMs   float64        `json:"latency_ms"`
	StatusCode  int            `json:"status_code"`
	ErrorCode   string         `json:"error_code"`
	ErrorMsg    string         `json:"error_msg"`
	Detail      map[string]any `json:"detail,omitempty"`
}

// ---------------------------------------------------------------------
// TargetState  (in-memory hot data)
// ---------------------------------------------------------------------

// TargetState caches the live status for one target.
type TargetState struct {
	TargetID           string    `json:"target_id"`
	Status             Status    `json:"status"`
	LastStatus         Status    `json:"last_status"`
	StatusChangedAt    time.Time `json:"status_changed_at"`
	LastProbeAt        time.Time `json:"last_probe_at"`
	LastSuccessAt      time.Time `json:"last_success_at"`
	ConsecutiveFails   int       `json:"consecutive_fails"`
	ConsecutiveSuccess int       `json:"consecutive_success"`
	AvgLatencyMs       float64   `json:"avg_latency_ms"`
	P99LatencyMs       float64   `json:"p99_latency_ms"`
	PacketLossPct      float64   `json:"packet_loss_pct"`
	CertExpiryDays     int       `json:"cert_expiry_days"`
	Availability7d     float64   `json:"availability_7d"`
	FlapCount10m       int       `json:"flap_count_10m"`
	SuppressedBy       string    `json:"suppressed_by,omitempty"`
}

// ---------------------------------------------------------------------
// Event
// ---------------------------------------------------------------------

// Event is a persisted record of a state transition or notable occurrence.
type Event struct {
	ID           string         `json:"id"`
	TargetID     string         `json:"target_id"`
	ProbeNodeID  string         `json:"probe_node_id"`
	Type         EventType      `json:"type"`
	FromStatus   Status         `json:"from_status"`
	ToStatus     Status         `json:"to_status"`
	Reason       string         `json:"reason"`
	Message      string         `json:"message"`
	DurationMs   int64          `json:"duration_ms"`
	Tags         []string       `json:"tags"`
	Meta         map[string]any `json:"meta,omitempty"`
	Timestamp    time.Time      `json:"timestamp"`
	Acknowledged bool           `json:"acknowledged"`
	AckedBy      string         `json:"acked_by,omitempty"`
	AckedAt      *time.Time     `json:"acked_at,omitempty"`
}

// ---------------------------------------------------------------------
// Alert
// ---------------------------------------------------------------------

// Alert tracks one notification lifecycle from firing to resolution.
type Alert struct {
	ID               string      `json:"id"`
	EventID          string      `json:"event_id"`
	TargetID         string      `json:"target_id"`
	RuleName         string      `json:"rule_name"`
	Severity         Severity    `json:"severity"`
	Status           AlertStatus `json:"status"`
	Title            string      `json:"title"`
	Body             string      `json:"body"`
	Channels         []string    `json:"channels"`
	SentAt           time.Time   `json:"sent_at"`
	ResolvedAt       *time.Time  `json:"resolved_at,omitempty"`
	EscalationLevel  int         `json:"escalation_level"`
	NextEscalateAt   *time.Time  `json:"next_escalate_at,omitempty"`
	GroupID          string      `json:"group_id,omitempty"`
}

// ---------------------------------------------------------------------
// ProbeNode
// ---------------------------------------------------------------------

// ProbeNodeStatus represents probe connectivity state.
type ProbeNodeStatus string

const (
	ProbeNodeOnline   ProbeNodeStatus = "online"
	ProbeNodeOffline  ProbeNodeStatus = "offline"
	ProbeNodeDegraded ProbeNodeStatus = "degraded"
)

// ProbeNode is a registered probe agent.
type ProbeNode struct {
	ID               string          `json:"id"`
	Name             string          `json:"name"`
	Location         string          `json:"location"`
	ISP              string          `json:"isp"`
	Tags             []string        `json:"tags"`
	IPAddress        string          `json:"ip_address"`
	Version          string          `json:"version"`
	Status           ProbeNodeStatus `json:"status"`
	LastHeartbeat    time.Time       `json:"last_heartbeat"`
	AssignedTargets  int             `json:"assigned_targets"`
	Capabilities     []string        `json:"capabilities"`
	RegisteredAt     time.Time       `json:"registered_at"`
}
