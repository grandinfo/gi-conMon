// Package alerter evaluates alert rules and dispatches notifications.
package alerter

import (
	"bytes"
	"context"
	"fmt"
	"log/slog"
	"sync"
	"text/template"
	"time"

	"github.com/google/uuid"
	"github.com/grandinfo/gi-conMon/internal/model"
)

// RuleConfig mirrors config.RuleConfig but is package-local.
type RuleConfig struct {
	Name          string
	Condition     string
	Channels      []string
	Severity      model.Severity
	Throttle      time.Duration
	EscalateAfter time.Duration
	Template      string
}

// ChannelConfig is the configuration for one notification channel.
type ChannelConfig struct {
	Name   string
	Type   string
	Config map[string]any
}

// Notifier sends notifications over a specific channel.
type Notifier interface {
	Name() string
	Type() string
	Send(ctx context.Context, msg *Message, cfg map[string]any) error
}

// Message is the channel-agnostic notification payload.
type Message struct {
	Title    string
	Body     string
	Severity model.Severity
	Alert    *model.Alert
	Event    *model.Event
	Target   *model.Target
}

// Engine evaluates events against rules and dispatches alerts.
type Engine struct {
	mu         sync.RWMutex
	rules      []RuleConfig
	channels   map[string]ChannelConfig
	notifiers  map[string]Notifier
	throttle   map[string]time.Time // "targetID:ruleName" → last sent time
	alerts     map[string]*model.Alert
	getTarget  func(string) *model.Target
}

// New creates a new alert engine.
func New(
	rules []RuleConfig,
	channels []ChannelConfig,
	notifiers []Notifier,
	getTarget func(string) *model.Target,
) *Engine {
	e := &Engine{
		rules:     rules,
		channels:  make(map[string]ChannelConfig),
		notifiers: make(map[string]Notifier),
		throttle:  make(map[string]time.Time),
		alerts:    make(map[string]*model.Alert),
		getTarget: getTarget,
	}
	for _, ch := range channels {
		e.channels[ch.Name] = ch
	}
	for _, n := range notifiers {
		e.notifiers[n.Type()] = n
	}
	return e
}

// Process evaluates an event against all rules and fires matching alerts.
func (e *Engine) Process(ctx context.Context, event *model.Event) {
	target := e.getTarget(event.TargetID)
	if target == nil {
		return
	}

	for _, rule := range e.rules {
		if !e.matchRule(rule, event, target) {
			continue
		}

		// Throttle check
		key := event.TargetID + ":" + rule.Name
		e.mu.Lock()
		lastSent, exists := e.throttle[key]
		if exists && rule.Throttle > 0 && time.Since(lastSent) < rule.Throttle {
			e.mu.Unlock()
			continue
		}
		e.throttle[key] = time.Now()
		e.mu.Unlock()

		alert := e.buildAlert(rule, event, target)
		e.storeAlert(alert)
		e.dispatch(ctx, alert, rule, event, target)
	}
}

// AckAlert acknowledges an alert by ID.
func (e *Engine) AckAlert(alertID, userID string) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	a, ok := e.alerts[alertID]
	if !ok {
		return fmt.Errorf("alert %s not found", alertID)
	}
	a.Status = model.AlertAcknowledged
	now := time.Now()
	_ = now
	slog.Info("alert acknowledged", "alert_id", alertID, "user", userID)
	return nil
}

// ResolveByTarget marks all firing alerts for a target as resolved.
func (e *Engine) ResolveByTarget(targetID string) {
	e.mu.Lock()
	defer e.mu.Unlock()
	now := time.Now()
	for _, a := range e.alerts {
		if a.TargetID == targetID && a.Status == model.AlertFiring {
			a.Status = model.AlertResolved
			a.ResolvedAt = &now
		}
	}
}

// ListAlerts returns all alerts, optionally filtered by status.
func (e *Engine) ListAlerts(status model.AlertStatus) []*model.Alert {
	e.mu.RLock()
	defer e.mu.RUnlock()
	out := make([]*model.Alert, 0)
	for _, a := range e.alerts {
		if status == "" || a.Status == status {
			cp := *a
			out = append(out, &cp)
		}
	}
	return out
}

// ---- internal --------------------------------------------------------

func (e *Engine) matchRule(rule RuleConfig, event *model.Event, target *model.Target) bool {
	// Simple built-in rule evaluation (CEL integration can replace this later)
	switch rule.Condition {
	case "":
		return false
	case "DOWN":
		return event.ToStatus == model.StatusDown
	case "UP":
		return event.ToStatus == model.StatusUp && event.FromStatus == model.StatusDown
	default:
		// Simple expression evaluation for common patterns
		return evalSimpleCondition(rule.Condition, event, target)
	}
}

// evalSimpleCondition handles basic CEL-like expressions without the full CEL runtime.
func evalSimpleCondition(cond string, event *model.Event, target *model.Target) bool {
	// "event.to_status == 'DOWN'"
	if cond == "event.to_status == 'DOWN'" {
		return event.ToStatus == model.StatusDown
	}
	if cond == "event.to_status == 'UP' && event.from_status == 'DOWN'" {
		return event.ToStatus == model.StatusUp && event.FromStatus == model.StatusDown
	}
	// Default: fire on any status_changed event
	return event.Type == model.EventStatusChanged
}

func (e *Engine) buildAlert(rule RuleConfig, event *model.Event, target *model.Target) *model.Alert {
	severity := rule.Severity
	if severity == "" {
		if event.ToStatus == model.StatusDown {
			severity = model.SeverityError
		} else {
			severity = model.SeverityWarn
		}
	}

	title := renderTemplate(
		"[{{.Severity}}] {{.Target}} {{.Status}}",
		map[string]any{
			"Severity": severity,
			"Target":   target.Name,
			"Status":   event.ToStatus,
		},
	)
	body := renderTemplate(
		defaultBodyTemplate,
		map[string]any{
			"Target":    target,
			"Event":     event,
			"Severity":  severity,
			"Timestamp": event.Timestamp.Format("2006-01-02 15:04:05"),
		},
	)

	now := time.Now()
	a := &model.Alert{
		ID:              "alert-" + uuid.New().String(),
		EventID:         event.ID,
		TargetID:        event.TargetID,
		RuleName:        rule.Name,
		Severity:        severity,
		Status:          model.AlertFiring,
		Title:           title,
		Body:            body,
		Channels:        rule.Channels,
		SentAt:          now,
		EscalationLevel: 1,
	}
	if rule.EscalateAfter > 0 {
		t := now.Add(rule.EscalateAfter)
		a.NextEscalateAt = &t
	}
	return a
}

func (e *Engine) storeAlert(a *model.Alert) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.alerts[a.ID] = a
}

func (e *Engine) dispatch(ctx context.Context, alert *model.Alert, rule RuleConfig, event *model.Event, target *model.Target) {
	msg := &Message{
		Title:    alert.Title,
		Body:     alert.Body,
		Severity: alert.Severity,
		Alert:    alert,
		Event:    event,
		Target:   target,
	}

	for _, chName := range rule.Channels {
		chCfg, ok := e.channels[chName]
		if !ok {
			slog.Warn("channel not found", "channel", chName)
			continue
		}
		notifier, ok := e.notifiers[chCfg.Type]
		if !ok {
			slog.Warn("notifier not registered", "type", chCfg.Type)
			continue
		}

		go func(n Notifier, cfg map[string]any) {
			sendCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
			defer cancel()
			if err := n.Send(sendCtx, msg, cfg); err != nil {
				slog.Error("notification failed",
					"channel", chName,
					"alert_id", alert.ID,
					"error", err,
				)
			} else {
				slog.Info("notification sent", "channel", chName, "alert_id", alert.ID)
			}
		}(notifier, chCfg.Config)
	}
}

// ---- template helpers ------------------------------------------------

const defaultBodyTemplate = `【{{.Severity}}】网络事件通知
━━━━━━━━━━━━━━━━━━━━━━━
目标：{{.Target.Name}} ({{.Target.Host}}:{{.Target.Port}})
事件：{{.Event.FromStatus}} → {{.Event.ToStatus}}
时间：{{.Timestamp}}
根因：{{.Event.Reason}}
━━━━━━━━━━━━━━━━━━━━━━━`

func renderTemplate(tmplStr string, data map[string]any) string {
	t, err := template.New("").Parse(tmplStr)
	if err != nil {
		return tmplStr
	}
	var buf bytes.Buffer
	if err := t.Execute(&buf, data); err != nil {
		return tmplStr
	}
	return buf.String()
}
