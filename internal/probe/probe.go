// Package probe defines the Prober interface and registry,
// plus the probe scheduler that drives periodic execution.
package probe

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"github.com/grandinfo/gi-conMon/internal/model"
)

// Result is an alias kept for backward compatibility within the package.
type Result = model.ProbeResult

// Prober is implemented by every protocol-specific probe.
type Prober interface {
	// Protocol returns the protocol identifier string (e.g. "http").
	Protocol() string

	// Probe performs a single check against target and returns the outcome.
	// ctx carries a deadline equal to target.TimeoutMs.
	Probe(ctx context.Context, target *model.Target) (*Result, error)

	// Validate checks that target.ProbeConfig is semantically correct.
	Validate(config map[string]any) error
}

// Registry is a concurrency-safe map from protocol name to Prober.
type Registry struct {
	mu      sync.RWMutex
	probers map[string]Prober
}

var defaultRegistry = &Registry{probers: make(map[string]Prober)}

// Register adds p to the global registry. Typically called from init().
func Register(p Prober) {
	defaultRegistry.Register(p)
}

// Get retrieves a prober from the global registry.
func Get(protocol string) (Prober, bool) {
	return defaultRegistry.Get(protocol)
}

// Register adds p to r.
func (r *Registry) Register(p Prober) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.probers[p.Protocol()] = p
}

// Get retrieves a prober by protocol name.
func (r *Registry) Get(protocol string) (Prober, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	p, ok := r.probers[string(protocol)]
	return p, ok
}

// ---- Scheduler -------------------------------------------------------

// ResultHandler is called with every ProbeResult produced by the scheduler.
type ResultHandler func(*Result)

// Scheduler drives periodic probe execution for a set of targets.
type Scheduler struct {
	mu        sync.RWMutex
	targets   map[string]*model.Target
	timers    map[string]*time.Timer
	executor  *Executor
	handler   ResultHandler
	nodeID    string
}

// NewScheduler creates a Scheduler with the given concurrency limit and result handler.
func NewScheduler(concurrency int, nodeID string, handler ResultHandler) *Scheduler {
	return &Scheduler{
		targets:  make(map[string]*model.Target),
		timers:   make(map[string]*time.Timer),
		executor: NewExecutor(concurrency),
		handler:  handler,
		nodeID:   nodeID,
	}
}

// Add registers target for periodic probing. If the target already exists
// it is updated (the old timer is cancelled and a new one is created).
func (s *Scheduler) Add(t *model.Target) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if old, ok := s.timers[t.ID]; ok {
		old.Stop()
	}
	s.targets[t.ID] = t
	s.timers[t.ID] = s.newTimer(t, time.Duration(t.IntervalSec)*time.Second)
}

// Remove cancels probing for the given target ID.
func (s *Scheduler) Remove(targetID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if timer, ok := s.timers[targetID]; ok {
		timer.Stop()
		delete(s.timers, targetID)
	}
	delete(s.targets, targetID)
}

// Stop cancels all probing.
func (s *Scheduler) Stop() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, t := range s.timers {
		t.Stop()
	}
}

// newTimer creates a one-shot timer. On expiry it submits a probe task
// and reschedules itself according to the result.
func (s *Scheduler) newTimer(t *model.Target, d time.Duration) *time.Timer {
	return time.AfterFunc(d, func() {
		s.runOnce(t)
	})
}

func (s *Scheduler) runOnce(t *model.Target) {
	prober, ok := Get(string(t.Protocol))
	if !ok {
		slog.Warn("no prober for protocol", "protocol", t.Protocol, "target", t.Name)
		s.reschedule(t, false)
		return
	}

	timeout := time.Duration(t.TimeoutMs) * time.Millisecond
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	result, err := prober.Probe(ctx, t)
	if err != nil {
		result = &Result{
			TargetID:    t.ID,
			ProbeNodeID: s.nodeID,
			Timestamp:   time.Now(),
			Success:     false,
			ErrorCode:   "probe_error",
			ErrorMsg:    err.Error(),
		}
	}
	result.TargetID = t.ID
	result.ProbeNodeID = s.nodeID

	if s.handler != nil {
		s.handler(result)
	}

	s.reschedule(t, result.Success)
}

func (s *Scheduler) reschedule(t *model.Target, success bool) {
	interval := time.Duration(t.IntervalSec) * time.Second
	if !success {
		// Accelerate polling when target is suspected down.
		faster := interval / 2
		if faster < 5*time.Second {
			faster = 5 * time.Second
		}
		interval = faster
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.targets[t.ID]; !ok {
		return // target was removed while probing
	}
	s.timers[t.ID] = time.AfterFunc(interval, func() {
		s.runOnce(t)
	})
}

// ---- Executor --------------------------------------------------------

// Executor limits the number of concurrent probe goroutines.
type Executor struct {
	sem chan struct{}
}

// NewExecutor creates an executor with the given concurrency ceiling.
func NewExecutor(concurrency int) *Executor {
	if concurrency <= 0 {
		concurrency = 100
	}
	return &Executor{sem: make(chan struct{}, concurrency)}
}

// Submit runs fn asynchronously, blocking if concurrency limit is reached.
func (e *Executor) Submit(ctx context.Context, fn func()) {
	go func() {
		select {
		case e.sem <- struct{}{}:
			defer func() { <-e.sem }()
			fn()
		case <-ctx.Done():
		}
	}()
}
