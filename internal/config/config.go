// Package config provides conMon configuration loading and validation.
package config

import (
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/spf13/viper"
)

// Config is the top-level configuration structure.
type Config struct {
	Server   ServerConfig   `mapstructure:"server"`
	Storage  StorageConfig  `mapstructure:"storage"`
	Probe    ProbeConfig    `mapstructure:"probe"`
	Monitors []MonitorSpec  `mapstructure:"monitors"`
	Alerting AlertingConfig `mapstructure:"alerting"`
	Log      LogConfig      `mapstructure:"log"`
	Debug    DebugConfig    `mapstructure:"debug"`
}

// ServerConfig configures the HTTP/gRPC server.
type ServerConfig struct {
	Bind        string    `mapstructure:"bind"`
	ExternalURL string    `mapstructure:"external_url"`
	TLS         TLSConfig `mapstructure:"tls"`
	Auth        AuthConfig `mapstructure:"auth"`
	Cluster     ClusterConfig `mapstructure:"cluster"`
}

// TLSConfig holds TLS certificate paths.
type TLSConfig struct {
	Enabled  bool   `mapstructure:"enabled"`
	CertFile string `mapstructure:"cert_file"`
	KeyFile  string `mapstructure:"key_file"`
	CAFile   string `mapstructure:"ca_file"`
	MinVersion string `mapstructure:"min_version"`
}

// AuthConfig holds JWT and session settings.
type AuthConfig struct {
	JWTSecret   string        `mapstructure:"jwt_secret"`
	TokenExpire time.Duration `mapstructure:"token_expire"`
}

// ClusterConfig enables multi-server HA mode.
type ClusterConfig struct {
	Enabled       bool     `mapstructure:"enabled"`
	NodeID        string   `mapstructure:"node_id"`
	EtcdEndpoints []string `mapstructure:"etcd_endpoints"`
}

// StorageConfig selects the persistence backend.
type StorageConfig struct {
	Type       string          `mapstructure:"type"` // sqlite | postgresql
	Path       string          `mapstructure:"path"` // sqlite only
	DSN        string          `mapstructure:"dsn"`  // postgresql
	Timeseries TSConfig        `mapstructure:"timeseries"`
	Retention  RetentionConfig `mapstructure:"retention"`
	PostgreSQL PGPoolConfig    `mapstructure:"postgresql"`
}

// TSConfig configures the time-series backend.
type TSConfig struct {
	Type          string `mapstructure:"type"` // influxdb | none
	URL           string `mapstructure:"url"`
	Token         string `mapstructure:"token"`
	Org           string `mapstructure:"org"`
	Bucket        string `mapstructure:"bucket"`
	BatchSize     int    `mapstructure:"batch_size"`
	FlushInterval time.Duration `mapstructure:"flush_interval"`
}

// RetentionConfig sets data lifetime per category.
type RetentionConfig struct {
	Raw    time.Duration `mapstructure:"raw"`
	Events time.Duration `mapstructure:"events"`
	Alerts time.Duration `mapstructure:"alerts"`
}

// PGPoolConfig tunes the PostgreSQL connection pool.
type PGPoolConfig struct {
	MaxConns        int32         `mapstructure:"max_conns"`
	MinConns        int32         `mapstructure:"min_conns"`
	MaxConnLifetime time.Duration `mapstructure:"max_conn_lifetime"`
	MaxConnIdleTime time.Duration `mapstructure:"max_conn_idle_time"`
}

// ProbeConfig configures the probe agent (used by conmon-probe).
type ProbeConfig struct {
	ID              string   `mapstructure:"id"`
	Name            string   `mapstructure:"name"`
	Location        string   `mapstructure:"location"`
	ISP             string   `mapstructure:"isp"`
	Tags            []string `mapstructure:"tags"`
	ServerEndpoints []string `mapstructure:"server_endpoints"`
	Concurrency     int      `mapstructure:"concurrency"`
	BufferSize      int      `mapstructure:"buffer_size"`
	TLS             TLSConfig `mapstructure:"tls"`
}

// MonitorSpec is the YAML representation of a monitored target.
type MonitorSpec struct {
	Name         string            `mapstructure:"name"`
	ID           string            `mapstructure:"id"`
	Target       string            `mapstructure:"target"`
	Protocol     string            `mapstructure:"protocol"`
	Port         int               `mapstructure:"port"`
	Interval     time.Duration     `mapstructure:"interval"`
	Timeout      time.Duration     `mapstructure:"timeout"`
	Retries      int               `mapstructure:"retries"`
	Priority     string            `mapstructure:"priority"`
	Tags         []string          `mapstructure:"tags"`
	Dependencies []string          `mapstructure:"dependencies"`
	ProbeIDs     []string          `mapstructure:"probe_ids"`
	ProbeConfig  map[string]any    `mapstructure:"probe_config"`
	AlertWhen    AlertWhenSpec     `mapstructure:"alert_when"`
	Hooks        *HookSpec         `mapstructure:"hooks,omitempty"`
}

// AlertWhenSpec captures per-target alert conditions from YAML.
type AlertWhenSpec struct {
	Down           bool     `mapstructure:"down"`
	LatencyGt      string   `mapstructure:"latency_gt"`
	PacketLossGt   string   `mapstructure:"packet_loss_gt"`
	Channels       []string `mapstructure:"channels"`
	DownThreshold  int      `mapstructure:"down_threshold"`
	RecovThreshold int      `mapstructure:"recovery_threshold"`
}

// HookSpec holds shell script paths for event hooks.
type HookSpec struct {
	OnDown     string `mapstructure:"on_down"`
	OnUp       string `mapstructure:"on_up"`
	OnDegraded string `mapstructure:"on_degraded"`
	TimeoutSec int    `mapstructure:"timeout_sec"`
}

// AlertingConfig holds all alerting rules and channel definitions.
type AlertingConfig struct {
	Channels []ChannelConfig `mapstructure:"channels"`
	Rules    []RuleConfig    `mapstructure:"rules"`
}

// ChannelConfig defines one notification channel.
type ChannelConfig struct {
	Name   string         `mapstructure:"name"`
	Type   string         `mapstructure:"type"`
	Config map[string]any `mapstructure:"config"`
}

// RuleConfig defines one alert rule.
type RuleConfig struct {
	Name          string        `mapstructure:"name"`
	Condition     string        `mapstructure:"condition"`
	Channels      []string      `mapstructure:"channels"`
	Severity      string        `mapstructure:"severity"`
	Throttle      time.Duration `mapstructure:"throttle"`
	EscalateAfter time.Duration `mapstructure:"escalate_after"`
	Template      string        `mapstructure:"template"`
}

// LogConfig controls logging behaviour.
type LogConfig struct {
	Level  string    `mapstructure:"level"`
	Format string    `mapstructure:"format"`
	Output string    `mapstructure:"output"`
	File   LogFile   `mapstructure:"file"`
}

// LogFile configures file-based log rotation.
type LogFile struct {
	Path       string `mapstructure:"path"`
	MaxSizeMB  int    `mapstructure:"max_size_mb"`
	MaxBackups int    `mapstructure:"max_backups"`
}

// DebugConfig enables developer diagnostics.
type DebugConfig struct {
	PProf bool `mapstructure:"pprof"`
	PProfAddr string `mapstructure:"pprof_addr"`
}

// Load reads and parses the configuration file at path.
// Environment variables with the CONMON_ prefix override file values.
func Load(path string) (*Config, error) {
	v := viper.New()

	// Defaults
	setDefaults(v)

	// File
	if path != "" {
		v.SetConfigFile(path)
	} else {
		v.SetConfigName("conmon")
		v.SetConfigType("yaml")
		v.AddConfigPath("/etc/conmon")
		v.AddConfigPath("$HOME/.conmon")
		v.AddConfigPath(".")
	}

	v.SetEnvPrefix("CONMON")
	v.SetEnvKeyReplacer(strings.NewReplacer(".", "_"))
	v.AutomaticEnv()

	if err := v.ReadInConfig(); err != nil {
		if _, ok := err.(viper.ConfigFileNotFoundError); !ok {
			return nil, fmt.Errorf("read config: %w", err)
		}
	}

	// Expand environment variable references inside values (e.g. ${DB_PASSWORD})
	expandEnvInViper(v)

	cfg := &Config{}
	if err := v.Unmarshal(cfg); err != nil {
		return nil, fmt.Errorf("unmarshal config: %w", err)
	}

	if err := validate(cfg); err != nil {
		return nil, fmt.Errorf("invalid config: %w", err)
	}

	return cfg, nil
}

func setDefaults(v *viper.Viper) {
	v.SetDefault("server.bind", "0.0.0.0:8080")
	v.SetDefault("server.auth.token_expire", "24h")
	v.SetDefault("storage.type", "sqlite")
	v.SetDefault("storage.path", "/var/lib/conmon/conmon.db")
	v.SetDefault("storage.timeseries.batch_size", 1000)
	v.SetDefault("storage.timeseries.flush_interval", "500ms")
	v.SetDefault("storage.retention.raw", "168h")    // 7 days
	v.SetDefault("storage.retention.events", "2160h") // 90 days
	v.SetDefault("storage.retention.alerts", "4320h") // 180 days
	v.SetDefault("storage.postgresql.max_conns", 50)
	v.SetDefault("storage.postgresql.min_conns", 5)
	v.SetDefault("probe.concurrency", 100)
	v.SetDefault("probe.buffer_size", 100000)
	v.SetDefault("log.level", "info")
	v.SetDefault("log.format", "json")
	v.SetDefault("log.output", "stdout")
	v.SetDefault("debug.pprof_addr", "127.0.0.1:6060")
}

// expandEnvInViper walks all keys and expands ${VAR} references.
func expandEnvInViper(v *viper.Viper) {
	for _, key := range v.AllKeys() {
		val := v.GetString(key)
		expanded := os.ExpandEnv(val)
		if expanded != val {
			v.Set(key, expanded)
		}
	}
}

func validate(cfg *Config) error {
	if cfg.Server.Bind == "" {
		return fmt.Errorf("server.bind must not be empty")
	}
	for i, m := range cfg.Monitors {
		if m.Name == "" {
			return fmt.Errorf("monitors[%d]: name is required", i)
		}
		if m.Target == "" {
			return fmt.Errorf("monitors[%d] %q: target is required", i, m.Name)
		}
		if m.Protocol == "" {
			return fmt.Errorf("monitors[%d] %q: protocol is required", i, m.Name)
		}
	}
	return nil
}
