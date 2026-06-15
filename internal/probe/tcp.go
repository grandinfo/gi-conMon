package probe

import (
	"context"
	"fmt"
	"net"
	"time"

	"github.com/grandinfo/gi-conMon/internal/model"
)

func init() {
	Register(&TCPProber{})
}

// TCPProber checks TCP connectivity by attempting a full connection.
type TCPProber struct{}

func (p *TCPProber) Protocol() string { return string(model.ProtoTCP) }

func (p *TCPProber) Validate(config map[string]any) error {
	return nil
}

func (p *TCPProber) Probe(ctx context.Context, target *model.Target) (*Result, error) {
	if target.Port <= 0 {
		return failResult(target, "invalid_port", "TCP probe requires a valid port"), nil
	}

	addr := fmt.Sprintf("%s:%d", target.Host, target.Port)
	start := time.Now()

	var d net.Dialer
	conn, err := d.DialContext(ctx, "tcp", addr)
	latencyMs := float64(time.Since(start).Microseconds()) / 1000.0

	if err != nil {
		code := "tcp_timeout"
		if isRefused(err) {
			code = "tcp_refused"
		}
		return &Result{
			Timestamp: time.Now(),
			Success:   false,
			LatencyMs: latencyMs,
			ErrorCode: code,
			ErrorMsg:  err.Error(),
		}, nil
	}
	defer conn.Close()

	// Optional: send data and read expected response
	cfg := target.ProbeConfig
	if cfg == nil {
		cfg = map[string]any{}
	}
	sendData := strOr(cfg, "send_data", "")
	if sendData != "" {
		if deadline, ok := ctx.Deadline(); ok {
			_ = conn.SetDeadline(deadline)
		}
		if _, err := fmt.Fprint(conn, sendData); err != nil {
			return &Result{
				Timestamp: time.Now(),
				Success:   false,
				LatencyMs: latencyMs,
				ErrorCode: "tcp_send_error",
				ErrorMsg:  err.Error(),
			}, nil
		}
	}

	return &Result{
		Timestamp:  time.Now(),
		Success:    true,
		LatencyMs:  latencyMs,
		StatusCode: 1,
	}, nil
}

func isRefused(err error) bool {
	if ne, ok := err.(*net.OpError); ok {
		return ne.Op == "dial"
	}
	return false
}
