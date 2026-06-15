// Package notifier provides notification channel implementations.
package notifier

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"github.com/grandinfo/gi-conMon/internal/alerter"
)

// ---- Webhook ---------------------------------------------------------

// WebhookNotifier sends a JSON POST to a configured URL.
type WebhookNotifier struct{}

func (n *WebhookNotifier) Name() string { return "webhook" }
func (n *WebhookNotifier) Type() string { return "webhook" }

func (n *WebhookNotifier) Send(ctx context.Context, msg *alerter.Message, cfg map[string]any) error {
	url, _ := cfg["url"].(string)
	if url == "" {
		return fmt.Errorf("webhook: url is required")
	}

	payload := map[string]any{
		"title":    msg.Title,
		"body":     msg.Body,
		"severity": msg.Severity,
		"target": map[string]any{
			"id":   msg.Target.ID,
			"name": msg.Target.Name,
			"host": msg.Target.Host,
		},
		"event": map[string]any{
			"from": msg.Event.FromStatus,
			"to":   msg.Event.ToStatus,
			"ts":   msg.Event.Timestamp.Format(time.RFC3339),
		},
		"alert_id": msg.Alert.ID,
	}

	body, _ := json.Marshal(payload)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	// Optional secret header
	if secret, ok := cfg["secret"].(string); ok && secret != "" {
		req.Header.Set("X-Webhook-Secret", secret)
	}
	// Optional custom headers
	if hdrs, ok := cfg["headers"].(map[string]any); ok {
		for k, v := range hdrs {
			req.Header.Set(k, fmt.Sprintf("%v", v))
		}
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("webhook: request failed: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return fmt.Errorf("webhook: server returned %d", resp.StatusCode)
	}
	return nil
}

// ---- DingTalk --------------------------------------------------------

// DingTalkNotifier sends Markdown messages to a DingTalk robot webhook.
type DingTalkNotifier struct{}

func (n *DingTalkNotifier) Name() string { return "dingtalk" }
func (n *DingTalkNotifier) Type() string { return "dingtalk" }

func (n *DingTalkNotifier) Send(ctx context.Context, msg *alerter.Message, cfg map[string]any) error {
	webhookURL, _ := cfg["webhook"].(string)
	if webhookURL == "" {
		return fmt.Errorf("dingtalk: webhook URL is required")
	}

	// Sign the request if a secret is provided
	secret, _ := cfg["secret"].(string)
	if secret != "" {
		ts := time.Now().UnixMilli()
		sign := dingTalkSign(secret, ts)
		webhookURL = fmt.Sprintf("%s&timestamp=%d&sign=%s", webhookURL, ts, sign)
	}

	emoji := "🔴"
	if msg.Event != nil && msg.Event.ToStatus == "UP" {
		emoji = "🟢"
	}

	content := fmt.Sprintf("%s **%s**\n\n%s", emoji, msg.Title, msg.Body)

	payload := map[string]any{
		"msgtype": "markdown",
		"markdown": map[string]any{
			"title": msg.Title,
			"text":  content,
		},
	}

	body, _ := json.Marshal(payload)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, webhookURL, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("dingtalk: request failed: %w", err)
	}
	defer resp.Body.Close()

	var result map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil
	}
	if code, ok := result["errcode"].(float64); ok && int(code) != 0 {
		return fmt.Errorf("dingtalk: errcode=%d errmsg=%v", int(code), result["errmsg"])
	}
	return nil
}

func dingTalkSign(secret string, timestamp int64) string {
	data := fmt.Sprintf("%d\n%s", timestamp, secret)
	h := hmac.New(sha256.New, []byte(secret))
	h.Write([]byte(data))
	return base64.StdEncoding.EncodeToString(h.Sum(nil))
}

// ---- WeCom (企业微信) -------------------------------------------------

// WeComNotifier sends messages to a WeCom robot webhook.
type WeComNotifier struct{}

func (n *WeComNotifier) Name() string { return "wecom" }
func (n *WeComNotifier) Type() string { return "wecom" }

func (n *WeComNotifier) Send(ctx context.Context, msg *alerter.Message, cfg map[string]any) error {
	webhookURL, _ := cfg["webhook"].(string)
	if webhookURL == "" {
		return fmt.Errorf("wecom: webhook URL is required")
	}

	payload := map[string]any{
		"msgtype": "markdown",
		"markdown": map[string]any{
			"content": fmt.Sprintf("**%s**\n\n%s", msg.Title, msg.Body),
		},
	}

	body, _ := json.Marshal(payload)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, webhookURL, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("wecom: request failed: %w", err)
	}
	defer resp.Body.Close()

	var result map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil
	}
	if code, ok := result["errcode"].(float64); ok && int(code) != 0 {
		return fmt.Errorf("wecom: errcode=%d errmsg=%v", int(code), result["errmsg"])
	}
	return nil
}
