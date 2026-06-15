// Package storage defines the persistence interface and a SQLite implementation.
package storage

import (
	"context"
	"time"

	"github.com/grandinfo/gi-conMon/internal/model"
)

// EventQuery filters event list queries.
type EventQuery struct {
	TargetID string
	Since    time.Time
	Until    time.Time
	Types    []model.EventType
	Limit    int
	Offset   int
}

// TargetQuery filters target list queries.
type TargetQuery struct {
	Tags     []string
	Statuses []model.Status
	Protocol string
	Search   string
	Limit    int
	Offset   int
}

// AlertQuery filters alert list queries.
type AlertQuery struct {
	TargetID string
	Status   model.AlertStatus
	Severity model.Severity
	Limit    int
	Offset   int
}

// MetricQuery selects time-series data.
type MetricQuery struct {
	TargetIDs []string
	Since     time.Time
	Until     time.Time
	Step      time.Duration
}

// LatencyPoint is one data point in a latency time series.
type LatencyPoint struct {
	Timestamp  time.Time
	AvgMs      float64
	P50Ms      float64
	P95Ms      float64
	P99Ms      float64
	SuccessRate float64
}

// AvailabilityStats holds computed SLA numbers.
type AvailabilityStats struct {
	TargetID     string
	Availability float64
	MTTR         time.Duration
	MTBF         time.Duration
	DownEvents   int
	TotalUpSec   int64
	TotalDownSec int64
}

// Store is the unified persistence interface.
type Store interface {
	// Targets
	SaveTarget(ctx context.Context, t *model.Target) error
	GetTarget(ctx context.Context, id string) (*model.Target, error)
	ListTargets(ctx context.Context, q TargetQuery) ([]*model.Target, int64, error)
	DeleteTarget(ctx context.Context, id string) error

	// Events
	SaveEvent(ctx context.Context, e *model.Event) error
	GetEvent(ctx context.Context, id string) (*model.Event, error)
	ListEvents(ctx context.Context, q EventQuery) ([]*model.Event, int64, error)
	AckEvent(ctx context.Context, id, userID string) error

	// Alerts
	SaveAlert(ctx context.Context, a *model.Alert) error
	GetAlert(ctx context.Context, id string) (*model.Alert, error)
	ListAlerts(ctx context.Context, q AlertQuery) ([]*model.Alert, int64, error)
	UpdateAlert(ctx context.Context, a *model.Alert) error

	// ProbeNodes
	SaveProbeNode(ctx context.Context, n *model.ProbeNode) error
	GetProbeNode(ctx context.Context, id string) (*model.ProbeNode, error)
	ListProbeNodes(ctx context.Context) ([]*model.ProbeNode, error)

	// Cleanup
	Cleanup(ctx context.Context, retentionEvents, retentionAlerts time.Duration) error

	// Lifecycle
	Close() error
}

// MetricStore writes and queries time-series probe metrics.
type MetricStore interface {
	WriteMetric(ctx context.Context, r *model.ProbeResult) error
	QueryLatency(ctx context.Context, q MetricQuery) ([]*LatencyPoint, error)
	QueryAvailability(ctx context.Context, targetID string, since, until time.Time) (*AvailabilityStats, error)
	Flush(ctx context.Context) error
	Close() error
}
