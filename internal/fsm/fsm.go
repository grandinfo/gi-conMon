// Package fsm implements the target state machine and flap detection.
package fsm

import (
	"fmt"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/grandinfo/gi-conMon/internal/model"
)

// Config controls state transition thresholds.
type Config struct {
	DownThreshold     int
	RecoveryThreshold int
	FlapWindow        time.Duration
	FlapThreshold     int
	DegradedLatencyMs int64
	DegradedLossPct   float64
}

// DefaultConfig returns production-tuned defaults.
func DefaultConfig() Config {
	return Config{
		DownThreshold:     3,
		RecoveryThreshold: 2,
		FlapWindow:        10 * time.Minute,
		FlapThreshold:     5,
		DegradedLatencyMs: 1000,
		DegradedLossPct:   0.1,
	}
}

// FSM manages TargetState for all monitored targets.
type FSM struct {
	mu      sync.RWMutex
	states  map[string]*model.TargetState
	cfg     Config
	flapper *FlapTracker
}

// New creates a new FSM with the given configuration.
func New(cfg Config) *FSM {
	return &FSM{
		states:  make(map[string]*model.TargetState),
		cfg:     cfg,
		flapper: NewFlapTracker(cfg.FlapWindow),
	}
}

// Process applies a ProbeResult to the state machine.
// It returns (changed, event) where event is non-nil only on state transitions.
func (f *FSM) Process(result *model.ProbeResult, target *model.Target) (bool, *model.Event) {
	f.mu.Lock()
	defer f.mu.Unlock()

	state := f.getOrCreate(result.TargetID)
	prev := state.Status
	state.LastProbeAt = result.Timestamp

	// Update consecutive counters
	if result.Success {
		state.ConsecutiveFails = 0
		state.ConsecutiveSuccess++
		state.LastSuccessAt = result.Timestamp
		if result.LatencyMs > 0 {
			state.AvgLatencyMs = ewma(state.AvgLatencyMs, result.LatencyMs, 0.1)
		}
	} else {
		state.ConsecutiveSuccess = 0
		state.ConsecutiveFails++
	}

	// Update cert expiry if provided
	if v, ok := result.Detail["cert_expiry_days"]; ok {
		if days, ok := v.(int); ok {
			state.CertExpiryDays = days
		}
	}

	// Maintenance window overrides everything
	if target.Maintenance.IsActive(result.Timestamp) {
		if state.Status != model.StatusMaintenance {
			state.Status = model.StatusMaintenance
		}
		return false, nil
	}

	// Silent: probing continues but no state change is reported
	if state.Status == model.StatusSilent {
		return false, nil
	}

	// Derive the new status
	newStatus := f.derive(state, result, target)

	// Flap detection
	if newStatus != prev {
		f.flapper.Record(result.TargetID, result.Timestamp)
		state.FlapCount10m = f.flapper.Count(result.TargetID, result.Timestamp)
		if state.FlapCount10m >= f.cfg.FlapThreshold {
			newStatus = model.StatusFlapping
		}
	}

	if newStatus == prev {
		return false, nil
	}

	// Commit transition
	durationMs := result.Timestamp.Sub(state.StatusChangedAt).Milliseconds()
	state.LastStatus = prev
	state.Status = newStatus
	state.StatusChangedAt = result.Timestamp

	event := &model.Event{
		ID:          "event-" + uuid.New().String(),
		TargetID:    result.TargetID,
		ProbeNodeID: result.ProbeNodeID,
		Type:        model.EventStatusChanged,
		FromStatus:  prev,
		ToStatus:    newStatus,
		Reason:      result.ErrorCode,
		Message:     buildMessage(prev, newStatus, result),
		DurationMs:  durationMs,
		Tags:        target.Tags,
		Meta: map[string]any{
			"consecutive_fails":   state.ConsecutiveFails,
			"consecutive_success": state.ConsecutiveSuccess,
			"latency_ms":          result.LatencyMs,
		},
		Timestamp: result.Timestamp,
	}
	return true, event
}

// GetState returns the current state for a target (nil if unknown).
func (f *FSM) GetState(targetID string) *model.TargetState {
	f.mu.RLock()
	defer f.mu.RUnlock()
	s := f.states[targetID]
	if s == nil {
		return nil
	}
	copy := *s
	return &copy
}

// SetSilent manually silences or un-silences a target.
func (f *FSM) SetSilent(targetID string, silent bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	s := f.getOrCreate(targetID)
	if silent {
		s.Status = model.StatusSilent
	} else if s.Status == model.StatusSilent {
		s.Status = model.StatusUnknown
	}
}

// AllStates returns a snapshot of all known target states.
func (f *FSM) AllStates() []*model.TargetState {
	f.mu.RLock()
	defer f.mu.RUnlock()
	out := make([]*model.TargetState, 0, len(f.states))
	for _, s := range f.states {
		cp := *s
		out = append(out, &cp)
	}
	return out
}

// Remove deletes the state entry for a deleted target.
func (f *FSM) Remove(targetID string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.states, targetID)
	f.flapper.Remove(targetID)
}

// ---- internal helpers ------------------------------------------------

func (f *FSM) getOrCreate(targetID string) *model.TargetState {
	s, ok := f.states[targetID]
	if !ok {
		s = &model.TargetState{
			TargetID:        targetID,
			Status:          model.StatusUnknown,
			CertExpiryDays:  -1,
			StatusChangedAt: time.Now(),
		}
		f.states[targetID] = s
	}
	return s
}

func (f *FSM) derive(state *model.TargetState, result *model.ProbeResult, target *model.Target) model.Status {
	downTh := f.cfg.DownThreshold
	recTh := f.cfg.RecoveryThreshold
	if target.AlertConfig.DownThreshold > 0 {
		downTh = target.AlertConfig.DownThreshold
	}
	if target.AlertConfig.RecoveryThreshold > 0 {
		recTh = target.AlertConfig.RecoveryThreshold
	}

	switch state.Status {
	case model.StatusUnknown:
		if result.Success {
			return model.StatusUp
		}
		return model.StatusUnknown

	case model.StatusUp, model.StatusDegraded:
		if state.ConsecutiveFails >= downTh {
			return model.StatusDown
		}
		if f.isDegraded(result, target) {
			return model.StatusDegraded
		}
		return model.StatusUp

	case model.StatusDown, model.StatusFlapping:
		if state.ConsecutiveSuccess >= recTh {
			return model.StatusUp
		}
		return model.StatusDown
	}
	return state.Status
}

func (f *FSM) isDegraded(r *model.ProbeResult, t *model.Target) bool {
	if !r.Success {
		return false
	}
	latTh := f.cfg.DegradedLatencyMs
	if t.AlertConfig.LatencyWarnMs > 0 {
		latTh = t.AlertConfig.LatencyWarnMs
	}
	if latTh > 0 && int64(r.LatencyMs) > latTh {
		return true
	}
	lossTh := f.cfg.DegradedLossPct
	if t.AlertConfig.PacketLossWarnPct > 0 {
		lossTh = t.AlertConfig.PacketLossWarnPct
	}
	if pl, ok := r.Detail["packet_loss_pct"].(float64); ok && lossTh > 0 && pl > lossTh {
		return true
	}
	return false
}

func buildMessage(from, to model.Status, r *model.ProbeResult) string {
	if r.ErrorMsg != "" {
		return fmt.Sprintf("%s → %s: %s", from, to, r.ErrorMsg)
	}
	return fmt.Sprintf("%s → %s", from, to)
}

// ewma computes an exponentially-weighted moving average.
func ewma(prev, next, alpha float64) float64 {
	if prev == 0 {
		return next
	}
	return alpha*next + (1-alpha)*prev
}
