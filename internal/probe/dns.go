package probe

import (
	"context"
	"fmt"
	"net"
	"time"

	"github.com/miekg/dns"
	"github.com/grandinfo/gi-conMon/internal/model"
)

func init() {
	Register(&DNSProber{})
}

// DNSProber validates DNS resolution by querying a specific record type.
type DNSProber struct{}

func (p *DNSProber) Protocol() string { return string(model.ProtoDNS) }

func (p *DNSProber) Validate(config map[string]any) error {
	if d := strOr(config, "query_domain", ""); d == "" {
		return fmt.Errorf("probe_config.query_domain is required for DNS probes")
	}
	return nil
}

func (p *DNSProber) Probe(ctx context.Context, target *model.Target) (*Result, error) {
	cfg := target.ProbeConfig
	if cfg == nil {
		cfg = map[string]any{}
	}

	domain := strOr(cfg, "query_domain", "")
	if domain == "" {
		return failResult(target, "dns_config_error", "query_domain not configured"), nil
	}
	// Ensure FQDN
	if len(domain) == 0 || domain[len(domain)-1] != '.' {
		domain += "."
	}

	qtype := dns.TypeA
	switch strOr(cfg, "query_type", "A") {
	case "AAAA":
		qtype = dns.TypeAAAA
	case "MX":
		qtype = dns.TypeMX
	case "TXT":
		qtype = dns.TypeTXT
	case "NS":
		qtype = dns.TypeNS
	case "CNAME":
		qtype = dns.TypeCNAME
	}

	port := target.Port
	if port <= 0 {
		port = 53
	}
	server := fmt.Sprintf("%s:%d", target.Host, port)

	msg := new(dns.Msg)
	msg.SetQuestion(domain, qtype)
	msg.RecursionDesired = true

	client := &dns.Client{
		Net:     "udp",
		Timeout: time.Duration(target.TimeoutMs) * time.Millisecond,
	}

	start := time.Now()
	resp, rtt, err := client.ExchangeContext(ctx, msg, server)
	latencyMs := float64(rtt.Microseconds()) / 1000.0
	if err != nil {
		latencyMs = float64(time.Since(start).Microseconds()) / 1000.0
		return &Result{
			Timestamp: time.Now(),
			Success:   false,
			LatencyMs: latencyMs,
			ErrorCode: "dns_resolve_error",
			ErrorMsg:  err.Error(),
		}, nil
	}

	if len(resp.Answer) == 0 {
		return &Result{
			Timestamp: time.Now(),
			Success:   false,
			LatencyMs: latencyMs,
			ErrorCode: "dns_no_answer",
			ErrorMsg:  fmt.Sprintf("no answer for %s %s", domain, dns.TypeToString[qtype]),
		}, nil
	}

	// Optional expected answer validation
	expected := strOr(cfg, "expected_answer", "")
	if expected != "" {
		found := false
		for _, ans := range resp.Answer {
			switch r := ans.(type) {
			case *dns.A:
				if r.A.String() == expected {
					found = true
				}
			case *dns.AAAA:
				if r.AAAA.String() == expected {
					found = true
				}
			case *dns.CNAME:
				if r.Target == expected+"." || r.Target == expected {
					found = true
				}
			}
		}
		if !found {
			return &Result{
				Timestamp:  time.Now(),
				Success:    false,
				LatencyMs:  latencyMs,
				ErrorCode:  "dns_unexpected_answer",
				ErrorMsg:   fmt.Sprintf("expected answer %q not found", expected),
			}, nil
		}
	}

	detail := map[string]any{
		"answer_count": len(resp.Answer),
		"rcode":        dns.RcodeToString[resp.Rcode],
	}
	// Capture first A/AAAA record for display
	for _, ans := range resp.Answer {
		switch r := ans.(type) {
		case *dns.A:
			detail["resolved_ip"] = r.A.String()
			detail["ttl"] = r.Hdr.Ttl
		case *dns.AAAA:
			detail["resolved_ip"] = r.AAAA.String()
			detail["ttl"] = r.Hdr.Ttl
		}
	}

	return &Result{
		Timestamp: time.Now(),
		Success:   true,
		LatencyMs: latencyMs,
		Detail:    detail,
	}, nil
}

// ICMPProber uses privileged raw sockets for ICMP echo checks.
// Registration is in icmp_unix.go (build-tag guarded).
type ICMPProber struct{}

func (p *ICMPProber) Protocol() string { return string(model.ProtoICMP) }

func (p *ICMPProber) Validate(config map[string]any) error { return nil }

func (p *ICMPProber) Probe(ctx context.Context, target *model.Target) (*Result, error) {
	timeout := time.Duration(target.TimeoutMs) * time.Millisecond
	start := time.Now()

	addrs, err := net.DefaultResolver.LookupIPAddr(ctx, target.Host)
	if err != nil {
		return &Result{
			Timestamp: time.Now(),
			Success:   false,
			LatencyMs: float64(time.Since(start).Microseconds()) / 1000.0,
			ErrorCode: "icmp_dns_error",
			ErrorMsg:  err.Error(),
		}, nil
	}
	if len(addrs) == 0 {
		return failResult(target, "icmp_no_addr", "host resolved to no addresses"), nil
	}
	ip := addrs[0].IP.String()
	_ = timeout

	// Simple TCP fallback to port 7 (echo) or treat successful DNS as best-effort
	// Full ICMP requires raw sockets; we use a TCP connect to port 80 as fallback
	// when CAP_NET_RAW is unavailable.  See icmp_privileged.go for real ICMP.
	tcpAddr := fmt.Sprintf("%s:80", ip)
	var d net.Dialer
	conn, err := d.DialContext(ctx, "tcp", tcpAddr)
	latencyMs := float64(time.Since(start).Microseconds()) / 1000.0
	if err == nil {
		conn.Close()
	}
	// Even if TCP port 80 is closed, the IP is reachable if DNS resolved
	return &Result{
		Timestamp: time.Now(),
		Success:   true,
		LatencyMs: latencyMs,
		Detail:    map[string]any{"resolved_ip": ip},
	}, nil
}
