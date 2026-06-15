package probe

import (
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"net/http"
	"net/http/httptrace"
	"strings"
	"time"

	"github.com/grandinfo/gi-conMon/internal/model"
)

func init() {
	Register(&HTTPProber{})
	Register(&HTTPSProber{})
}

// HTTPProber implements HTTP health checking.
type HTTPProber struct{}

func (p *HTTPProber) Protocol() string { return string(model.ProtoHTTP) }

func (p *HTTPProber) Validate(config map[string]any) error { return nil }

func (p *HTTPProber) Probe(ctx context.Context, target *model.Target) (*Result, error) {
	return doHTTP(ctx, target, false)
}

// HTTPSProber implements HTTPS health checking with TLS details.
type HTTPSProber struct{}

func (p *HTTPSProber) Protocol() string { return string(model.ProtoHTTPS) }

func (p *HTTPSProber) Validate(config map[string]any) error { return nil }

func (p *HTTPSProber) Probe(ctx context.Context, target *model.Target) (*Result, error) {
	return doHTTP(ctx, target, true)
}

// doHTTP performs the actual HTTP/HTTPS probe and captures per-phase timings.
func doHTTP(ctx context.Context, target *model.Target, useTLS bool) (*Result, error) {
	cfg := target.ProbeConfig
	if cfg == nil {
		cfg = map[string]any{}
	}

	method := strOr(cfg, "method", "GET")
	path := strOr(cfg, "path", "/")
	bodyStr := strOr(cfg, "body", "")
	bodyContains := strOr(cfg, "body_contains", "")
	skipVerify := boolOr(cfg, "tls_skip_verify", false)
	expectedCodes := intSliceOr(cfg, "expected_codes", []int{200})

	scheme := "http"
	if useTLS {
		scheme = "https"
	}
	host := target.Host
	if target.Port > 0 {
		host = fmt.Sprintf("%s:%d", host, target.Port)
	}
	url := fmt.Sprintf("%s://%s%s", scheme, host, path)

	// Per-phase timing via httptrace
	var (
		dnsStart, dnsDone     time.Time
		tcpStart, tcpDone     time.Time
		tlsStart, tlsDone     time.Time
		firstByteAt           time.Time
		startAt               = time.Now()
	)

	trace := &httptrace.ClientTrace{
		DNSStart:             func(_ httptrace.DNSStartInfo) { dnsStart = time.Now() },
		DNSDone:              func(_ httptrace.DNSDoneInfo) { dnsDone = time.Now() },
		ConnectStart:         func(_, _ string) { tcpStart = time.Now() },
		ConnectDone:          func(_, _ string, _ error) { tcpDone = time.Now() },
		TLSHandshakeStart:    func() { tlsStart = time.Now() },
		TLSHandshakeDone:     func(_ tls.ConnectionState, _ error) { tlsDone = time.Now() },
		GotFirstResponseByte: func() { firstByteAt = time.Now() },
	}
	ctx = httptrace.WithClientTrace(ctx, trace)

	var reqBody io.Reader
	if bodyStr != "" {
		reqBody = strings.NewReader(bodyStr)
	}

	req, err := http.NewRequestWithContext(ctx, method, url, reqBody)
	if err != nil {
		return failResult(target, "http_build_request", err.Error()), nil
	}

	// Custom headers
	if hdrs, ok := cfg["headers"].(map[string]any); ok {
		for k, v := range hdrs {
			req.Header.Set(k, fmt.Sprintf("%v", v))
		}
	}
	if req.Header.Get("User-Agent") == "" {
		req.Header.Set("User-Agent", "conmon-probe/2.0")
	}

	tlsCfg := &tls.Config{InsecureSkipVerify: skipVerify} //nolint:gosec
	transport := &http.Transport{TLSClientConfig: tlsCfg}
	client := &http.Client{
		Transport: transport,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			if boolOr(cfg, "follow_redirects", true) {
				return nil
			}
			return http.ErrUseLastResponse
		},
	}

	resp, err := client.Do(req)
	if err != nil {
		return failResult(target, "http_timeout", err.Error()), nil
	}
	defer resp.Body.Close()

	rawBody, _ := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	totalMs := float64(time.Since(startAt).Microseconds()) / 1000.0

	// Status code check
	if !containsInt(expectedCodes, resp.StatusCode) {
		return &Result{
			Timestamp:  time.Now(),
			Success:    false,
			LatencyMs:  totalMs,
			StatusCode: resp.StatusCode,
			ErrorCode:  "http_unexpected_status",
			ErrorMsg:   fmt.Sprintf("got %d, want %v", resp.StatusCode, expectedCodes),
		}, nil
	}

	// Body content check
	if bodyContains != "" && !strings.Contains(string(rawBody), bodyContains) {
		return &Result{
			Timestamp:  time.Now(),
			Success:    false,
			LatencyMs:  totalMs,
			StatusCode: resp.StatusCode,
			ErrorCode:  "body_mismatch",
			ErrorMsg:   fmt.Sprintf("response body does not contain %q", bodyContains),
		}, nil
	}

	detail := map[string]any{
		"status_code":    resp.StatusCode,
		"first_byte_ms":  ms(firstByteAt, startAt),
		"dns_ms":         ms(dnsDone, dnsStart),
		"tcp_ms":         ms(tcpDone, tcpStart),
	}
	if useTLS {
		detail["tls_ms"] = ms(tlsDone, tlsStart)
		// Certificate expiry
		if resp.TLS != nil && len(resp.TLS.PeerCertificates) > 0 {
			cert := resp.TLS.PeerCertificates[0]
			days := int(time.Until(cert.NotAfter).Hours() / 24)
			detail["cert_expiry_days"] = days
			detail["tls_version"] = tlsVersionName(resp.TLS.Version)
		}
	}

	return &Result{
		Timestamp:  time.Now(),
		Success:    true,
		LatencyMs:  totalMs,
		StatusCode: resp.StatusCode,
		Detail:     detail,
	}, nil
}

// ---- helpers ---------------------------------------------------------

func failResult(_ *model.Target, code, msg string) *Result {
	return &Result{
		Timestamp: time.Now(),
		Success:   false,
		ErrorCode: code,
		ErrorMsg:  msg,
	}
}

func ms(end, start time.Time) float64 {
	if end.IsZero() || start.IsZero() {
		return 0
	}
	return float64(end.Sub(start).Microseconds()) / 1000.0
}

func strOr(m map[string]any, key, def string) string {
	if v, ok := m[key].(string); ok && v != "" {
		return v
	}
	return def
}

func boolOr(m map[string]any, key string, def bool) bool {
	if v, ok := m[key].(bool); ok {
		return v
	}
	return def
}

func intSliceOr(m map[string]any, key string, def []int) []int {
	v, ok := m[key]
	if !ok {
		return def
	}
	switch t := v.(type) {
	case []int:
		return t
	case []any:
		out := make([]int, 0, len(t))
		for _, i := range t {
			switch n := i.(type) {
			case int:
				out = append(out, n)
			case float64:
				out = append(out, int(n))
			}
		}
		return out
	}
	return def
}

func containsInt(slice []int, v int) bool {
	for _, s := range slice {
		if s == v {
			return true
		}
	}
	return false
}

func tlsVersionName(v uint16) string {
	switch v {
	case tls.VersionTLS10:
		return "TLS1.0"
	case tls.VersionTLS11:
		return "TLS1.1"
	case tls.VersionTLS12:
		return "TLS1.2"
	case tls.VersionTLS13:
		return "TLS1.3"
	default:
		return fmt.Sprintf("0x%04x", v)
	}
}
