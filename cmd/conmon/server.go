package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/spf13/cobra"
	"github.com/grandinfo/gi-conMon/internal/alerter"
	"github.com/grandinfo/gi-conMon/internal/alerter/notifier"
	"github.com/grandinfo/gi-conMon/internal/api"
	"github.com/grandinfo/gi-conMon/internal/config"
	"github.com/grandinfo/gi-conMon/internal/fsm"
	"github.com/grandinfo/gi-conMon/internal/model"
	"github.com/grandinfo/gi-conMon/internal/probe"
	"github.com/grandinfo/gi-conMon/internal/storage/sqlite"

	// Register built-in probers
	_ "github.com/grandinfo/gi-conMon/internal/probe"
)

var serverCmd = &cobra.Command{
	Use:   "server",
	Short: "启动 conMon 控制端服务",
	RunE:  runServer,
}

var cfgFile string

func init() {
	serverCmd.Flags().StringVarP(&cfgFile, "config", "c", "", "配置文件路径")
}

func runServer(cmd *cobra.Command, args []string) error {
	// Load configuration
	cfg, err := config.Load(cfgFile)
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}

	// Setup structured logger
	level := slog.LevelInfo
	if cfg.Log.Level == "debug" {
		level = slog.LevelDebug
	}
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: level})))

	slog.Info("conMon starting", "bind", cfg.Server.Bind)

	// Open storage
	store, err := sqlite.Open(cfg.Storage.Path)
	if err != nil {
		return fmt.Errorf("open storage: %w", err)
	}
	defer store.Close()

	// Build state machine
	fsmInst := fsm.New(fsm.DefaultConfig())

	// Build alert engine
	rules := buildRules(cfg.Alerting.Rules)
	channels := buildChannels(cfg.Alerting.Channels)
	notifiers := []alerter.Notifier{
		&notifier.WebhookNotifier{},
		&notifier.DingTalkNotifier{},
		&notifier.WeComNotifier{},
	}
	getTarget := func(id string) *model.Target {
		t, _ := store.GetTarget(context.Background(), id)
		return t
	}
	alerterInst := alerter.New(rules, channels, notifiers, getTarget)

	// Seed targets from config and start scheduler
	nodeID := cfg.Probe.ID
	if nodeID == "" {
		nodeID = "local"
	}
	scheduler := probe.NewScheduler(cfg.Probe.Concurrency, nodeID, func(result *probe.Result) {
		ctx := context.Background()
		t, err := store.GetTarget(ctx, result.TargetID)
		if err != nil || t == nil {
			return
		}
		changed, event := fsmInst.Process(result, t)
		if changed && event != nil {
			_ = store.SaveEvent(ctx, event)
			alerterInst.Process(ctx, event)
		}
	})

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	// Register and schedule monitors from config
	for _, spec := range cfg.Monitors {
		t := specToTarget(spec)
		if err := store.SaveTarget(ctx, &t); err != nil {
			slog.Warn("failed to save target", "name", t.Name, "err", err)
			continue
		}
		scheduler.Add(&t)
	}

	// Also load previously stored targets
	existing, _, err := store.ListTargets(ctx, struct {
		Tags     []string
		Statuses []model.Status
		Protocol string
		Search   string
		Limit    int
		Offset   int
	}{Limit: 10000})
	if err == nil {
		for _, t := range existing {
			scheduler.Add(t)
		}
	}

	// Start API server
	apiSrv := api.New(api.Config{
		Bind:        cfg.Server.Bind,
		JWTSecret:   cfg.Server.Auth.JWTSecret,
		ExternalURL: cfg.Server.ExternalURL,
	}, store, fsmInst, alerterInst)

	if err := apiSrv.Start(ctx); err != nil {
		slog.Error("server error", "err", err)
	}

	scheduler.Stop()
	slog.Info("conMon stopped")
	return nil
}

// ---- helpers ---------------------------------------------------------

func specToTarget(spec config.MonitorSpec) model.Target {
	def := model.DefaultTarget()
	t := def
	t.ID = spec.ID
	if t.ID == "" {
		t.ID = "target-" + spec.Name
	}
	t.Name = spec.Name
	t.Host = spec.Target
	t.Port = spec.Port
	t.Protocol = model.Protocol(spec.Protocol)
	t.Tags = spec.Tags
	t.Dependencies = spec.Dependencies
	t.ProbeIDs = spec.ProbeIDs
	t.ProbeConfig = spec.ProbeConfig

	if spec.Interval > 0 {
		t.IntervalSec = int(spec.Interval.Seconds())
	}
	if spec.Timeout > 0 {
		t.TimeoutMs = int(spec.Timeout.Milliseconds())
	}
	if spec.Retries > 0 {
		t.Retries = spec.Retries
	}
	if spec.Priority != "" {
		t.Priority = model.Priority(spec.Priority)
	}
	if spec.AlertWhen.DownThreshold > 0 {
		t.AlertConfig.DownThreshold = spec.AlertWhen.DownThreshold
	}
	if spec.AlertWhen.RecovThreshold > 0 {
		t.AlertConfig.RecoveryThreshold = spec.AlertWhen.RecovThreshold
	}
	if len(spec.AlertWhen.Channels) > 0 {
		t.AlertConfig.AlertChannels = spec.AlertWhen.Channels
	}
	if spec.Hooks != nil {
		t.Hooks = &model.HookConfig{
			OnDown:     spec.Hooks.OnDown,
			OnUp:       spec.Hooks.OnUp,
			OnDegraded: spec.Hooks.OnDegraded,
			TimeoutSec: spec.Hooks.TimeoutSec,
		}
	}
	return t
}

func buildRules(cfgRules []config.RuleConfig) []alerter.RuleConfig {
	rules := make([]alerter.RuleConfig, 0, len(cfgRules))
	for _, r := range cfgRules {
		sev := model.Severity(r.Severity)
		if sev == "" {
			sev = model.SeverityError
		}
		rules = append(rules, alerter.RuleConfig{
			Name:          r.Name,
			Condition:     r.Condition,
			Channels:      r.Channels,
			Severity:      sev,
			Throttle:      r.Throttle,
			EscalateAfter: r.EscalateAfter,
			Template:      r.Template,
		})
	}
	// Always add a default rule for DOWN events
	if len(rules) == 0 {
		rules = append(rules, alerter.RuleConfig{
			Name:      "default_down",
			Condition: "event.to_status == 'DOWN'",
			Severity:  model.SeverityError,
		})
	}
	return rules
}

func buildChannels(cfgChs []config.ChannelConfig) []alerter.ChannelConfig {
	channels := make([]alerter.ChannelConfig, 0, len(cfgChs))
	for _, ch := range cfgChs {
		channels = append(channels, alerter.ChannelConfig{
			Name:   ch.Name,
			Type:   ch.Type,
			Config: ch.Config,
		})
	}
	return channels
}
