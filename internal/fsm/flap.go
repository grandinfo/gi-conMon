package fsm

import (
	"sync"
	"time"
)

// FlapTracker counts state changes within a sliding time window per target.
type FlapTracker struct {
	mu      sync.Mutex
	history map[string][]time.Time
	window  time.Duration
}

// NewFlapTracker creates a tracker with the given sliding window duration.
func NewFlapTracker(window time.Duration) *FlapTracker {
	return &FlapTracker{
		history: make(map[string][]time.Time),
		window:  window,
	}
}

// Record appends a state-change timestamp for targetID.
func (ft *FlapTracker) Record(targetID string, t time.Time) {
	ft.mu.Lock()
	defer ft.mu.Unlock()
	ts := ft.trim(ft.history[targetID], t)
	ft.history[targetID] = append(ts, t)
}

// Count returns the number of changes within the window ending at now.
func (ft *FlapTracker) Count(targetID string, now time.Time) int {
	ft.mu.Lock()
	defer ft.mu.Unlock()
	ts := ft.trim(ft.history[targetID], now)
	ft.history[targetID] = ts
	return len(ts)
}

// Remove clears history for a deleted target.
func (ft *FlapTracker) Remove(targetID string) {
	ft.mu.Lock()
	defer ft.mu.Unlock()
	delete(ft.history, targetID)
}

func (ft *FlapTracker) trim(ts []time.Time, now time.Time) []time.Time {
	cutoff := now.Add(-ft.window)
	i := 0
	for i < len(ts) && ts[i].Before(cutoff) {
		i++
	}
	if i == 0 {
		return ts
	}
	trimmed := make([]time.Time, len(ts)-i)
	copy(trimmed, ts[i:])
	return trimmed
}
