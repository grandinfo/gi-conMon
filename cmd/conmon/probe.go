package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/spf13/cobra"
	"github.com/grandinfo/gi-conMon/internal/config"
	"github.com/grandinfo/gi-conMon/internal/model"
	"github.com/grandinfo/gi-conMon/internal/probe"
)

var probeCfgFile string

var probeCmd = &cobra.Command{
	Use:   "probe",
	Short: "启动探针代理（独立进程）",
	RunE:  runProbe,
}

func init() {
	probeCmd.Flags().StringVarP(&probeCfgFile, "config", "c", "", "配置文件路径")
}

func runProbe(cmd *cobra.Command, args []string) error {
	cfg, err := config.Load(probeCfgFile)
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}

	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})))

	nodeID := cfg.Probe.ID
	if nodeID == "" {
		nodeID = "probe-local"
	}

	slog.Info("probe agent starting",
		"id", nodeID,
		"name", cfg.Probe.Name,
		"location", cfg.Probe.Location,
		"concurrency", cfg.Probe.Concurrency,
	)

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	// In standalone mode the probe prints results to stdout.
	// In connected mode it streams results to the control plane via gRPC.
	resultHandler := func(r *probe.Result) {
		status := "✓"
		if !r.Success {
			status = "✗"
		}
		slog.Info("probe result",
			"target_id", r.TargetID,
			"status", status,
			"latency_ms", fmt.Sprintf("%.1f", r.LatencyMs),
			"error", r.ErrorCode,
		)
	}

	scheduler := probe.NewScheduler(cfg.Probe.Concurrency, nodeID, resultHandler)

	// Schedule targets from config
	for _, spec := range cfg.Monitors {
		t := specToTargetFromProbe(spec)
		scheduler.Add(&t)
	}

	<-ctx.Done()
	scheduler.Stop()

	// Allow in-flight probes to finish
	time.Sleep(500 * time.Millisecond)
	slog.Info("probe agent stopped")
	return nil
}

func specToTargetFromProbe(spec config.MonitorSpec) model.Target {
	t := model.DefaultTarget()
	t.ID = spec.ID
	if t.ID == "" {
		t.ID = "target-" + spec.Name
	}
	t.Name = spec.Name
	t.Host = spec.Target
	t.Port = spec.Port
	t.Protocol = model.Protocol(spec.Protocol)
	t.Tags = spec.Tags
	t.ProbeConfig = spec.ProbeConfig
	if spec.Interval > 0 {
		t.IntervalSec = int(spec.Interval.Seconds())
	}
	if spec.Timeout > 0 {
		t.TimeoutMs = int(spec.Timeout.Milliseconds())
	}
	return t
}
