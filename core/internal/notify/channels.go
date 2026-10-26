package notify

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"time"
)

var (
	ErrNoChannel     = errors.New("notify_no_channel")
	ErrPrivateTarget = errors.New("notify_private_target_rejected")
)

// validateOrigin accepts a bare http(s) origin for the bark server: a scheme,
// a host, and nothing else. A trailing slash is tolerated and dropped; the
// push path is appended by the sender.
func validateOrigin(raw string) (string, error) {
	trimmed := strings.TrimRight(strings.TrimSpace(raw), "/")
	parsed, err := url.Parse(trimmed)
	if err != nil {
		return "", invalidEndpoint(raw, err)
	}
	if (parsed.Scheme != "https" && parsed.Scheme != "http") || parsed.Host == "" ||
		parsed.User != nil || parsed.Path != "" || parsed.RawQuery != "" ||
		parsed.Fragment != "" {
		return "", invalidEndpoint(raw, nil)
	}
	return parsed.String(), nil
}

// validateEndpoint accepts a full http(s) URL with an optional path and query
// but no credentials or fragment.
func validateEndpoint(raw string) (string, error) {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return "", invalidEndpoint(raw, err)
	}
	if (parsed.Scheme != "https" && parsed.Scheme != "http") || parsed.Host == "" ||
		parsed.User != nil || parsed.Fragment != "" {
		return "", invalidEndpoint(raw, nil)
	}
	return parsed.String(), nil
}

func invalidEndpoint(raw string, err error) error {
	if err != nil {
		return fmt.Errorf("notify_invalid_endpoint: %s: %w", raw, err)
	}
	return fmt.Errorf("notify_invalid_endpoint: %s", raw)
}

// deliver sends one event to every configured channel and joins their errors;
// per-channel failures are logged so one dead channel never hides another.
func (h *Hub) deliver(client *http.Client, cfg Config, event Event) error {
	var failures []error
	if cfg.BarkKey != "" {
		if err := sendBark(client, cfg, event); err != nil {
			slogFailure("bark", event.Code, err)
			failures = append(failures, err)
		}
	}
	if cfg.WebhookURL != "" {
		if err := sendWebhook(client, cfg, event); err != nil {
			slogFailure("webhook", event.Code, err)
			failures = append(failures, err)
		}
	}
	switch len(failures) {
	case 0:
		return nil
	case 1:
		return failures[0]
	default:
		return fmt.Errorf("notify_delivery_failed: %v", failures)
	}
}

func slogFailure(channel, code string, err error) {
	// The endpoint never carries secrets; the error text may carry the URL,
	// which the owner configured, so logging it is safe and useful.
	slog.Warn("notification delivery failed", "channel", channel, "code", code, "error", err)
}

type barkPayload struct {
	DeviceKey string `json:"device_key"`
	Title     string `json:"title"`
	Body      string `json:"body"`
	Group     string `json:"group"`
}

func sendBark(client *http.Client, cfg Config, event Event) error {
	body, err := json.Marshal(barkPayload{
		DeviceKey: cfg.BarkKey,
		Title:     event.Title,
		Body:      event.Body,
		Group:     "LightIsle",
	})
	if err != nil {
		return err
	}
	return postJSON(client, strings.TrimSuffix(cfg.BarkServer, "/")+"/push", body)
}

type webhookPayload struct {
	Source    string `json:"source"`
	Event     string `json:"event"`
	Severity  string `json:"severity"`
	Title     string `json:"title"`
	Body      string `json:"body"`
	Timestamp int64  `json:"timestamp"`
}

func sendWebhook(client *http.Client, cfg Config, event Event) error {
	body, err := json.Marshal(webhookPayload{
		Source:    "lightisle",
		Event:     event.Code,
		Severity:  event.Severity,
		Title:     event.Title,
		Body:      event.Body,
		Timestamp: time.Now().Unix(),
	})
	if err != nil {
		return err
	}
	return postJSON(client, cfg.WebhookURL, body)
}

func postJSON(client *http.Client, endpoint string, body []byte) error {
	response, err := client.Post(endpoint, "application/json", bytes.NewReader(body))
	if err != nil {
		return err
	}
	defer response.Body.Close()
	// Drain a bounded amount so the connection can be reused, then judge.
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4<<10))
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("notify_delivery_status: %s", response.Status)
	}
	return nil
}
