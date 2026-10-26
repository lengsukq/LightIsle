package notify

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/mail"
	"net/smtp"
	"net/url"
	"strconv"
	"strings"
	"syscall"
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

func sendRobot(client *http.Client, endpoint string, event Event, ding bool, secret string) error {
	text := event.Title + "\n" + event.Body
	var body []byte
	var err error
	if ding {
		if secret != "" {
			timestamp := strconv.FormatInt(time.Now().UnixMilli(), 10)
			mac := hmac.New(sha256.New, []byte(secret))
			mac.Write([]byte(timestamp + "\n" + secret))
			signature := base64.StdEncoding.EncodeToString(mac.Sum(nil))
			u, e := url.Parse(endpoint)
			if e != nil {
				return e
			}
			query := u.Query()
			query.Set("timestamp", timestamp)
			query.Set("sign", signature)
			u.RawQuery = query.Encode()
			endpoint = u.String()
		}
		body, err = json.Marshal(map[string]any{"msgtype": "text", "text": map[string]string{"content": text}})
	} else {
		body, err = json.Marshal(map[string]any{"msgtype": "text", "text": map[string]string{"content": text}})
	}
	if err != nil {
		return err
	}
	response, err := client.Post(endpoint, "application/json", bytes.NewReader(body))
	if err != nil {
		// Endpoint URLs carry robot keys. Never include the URL in event logs.
		return errors.New("notify_robot_network_failed")
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(response.Body, 4<<10))
	if err != nil {
		return err
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("notify_robot_http_%d", response.StatusCode)
	}
	var result struct {
		ErrorCode int    `json:"errcode"`
		Message   string `json:"errmsg"`
	}
	if json.Unmarshal(raw, &result) != nil || result.ErrorCode != 0 {
		return errors.New("notify_robot_rejected")
	}
	return nil
}

func validateSMTP(cfg Config) error {
	if cfg.SMTPHost == "" {
		if cfg.SMTPPort != 0 || cfg.SMTPUsername != "" || cfg.SMTPPassword != "" || cfg.SMTPFrom != "" || cfg.SMTPTo != "" {
			return errors.New("notify_invalid_smtp")
		}
		return nil
	}
	if len(cfg.SMTPHost) > 253 || strings.ContainsAny(cfg.SMTPHost, ":/\\@ \t\n") || cfg.SMTPPort != 465 && cfg.SMTPPort != 587 {
		return errors.New("notify_invalid_smtp")
	}
	for _, address := range append([]string{cfg.SMTPFrom}, smtpRecipients(cfg.SMTPTo)...) {
		parsed, err := mail.ParseAddress(address)
		if err != nil || parsed.Address != address {
			return errors.New("notify_invalid_email_address")
		}
	}
	if cfg.SMTPTo == "" || len(smtpRecipients(cfg.SMTPTo)) > 5 || cfg.SMTPUsername == "" || cfg.SMTPPassword == "" || len(cfg.SMTPPassword) > 1024 {
		return errors.New("notify_invalid_smtp")
	}
	return nil
}
func smtpRecipients(value string) []string {
	result := []string{}
	for _, part := range strings.Split(value, ",") {
		if trimmed := strings.TrimSpace(part); trimmed != "" {
			result = append(result, trimmed)
		}
	}
	return result
}
func sendEmail(cfg Config, event Event) error {
	if err := validateSMTP(cfg); err != nil {
		return err
	}
	// DNS is resolved by the guarded dialer; private destinations remain opt-in.
	dialer := &net.Dialer{Timeout: sendTimeout, Control: func(network, address string, _ syscall.RawConn) error {
		if cfg.AllowPrivateTargets {
			return nil
		}
		host, _, err := net.SplitHostPort(address)
		if err != nil {
			return err
		}
		if ip := net.ParseIP(host); ip != nil && isPrivateTarget(ip) {
			return ErrPrivateTarget
		}
		return nil
	}}
	conn, err := dialer.Dial("tcp", net.JoinHostPort(cfg.SMTPHost, strconv.Itoa(cfg.SMTPPort)))
	if err != nil {
		return errors.New("notify_smtp_connect_failed")
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(sendTimeout))
	tlsConfig := &tls.Config{ServerName: cfg.SMTPHost, MinVersion: tls.VersionTLS12}
	if cfg.SMTPPort == 465 {
		tlsConn := tls.Client(conn, tlsConfig)
		if err := tlsConn.Handshake(); err != nil {
			return errors.New("notify_smtp_tls_failed")
		}
		conn = tlsConn
	}
	client, err := smtp.NewClient(conn, cfg.SMTPHost)
	if err != nil {
		return errors.New("notify_smtp_handshake_failed")
	}
	defer client.Close()
	if cfg.SMTPPort == 587 {
		if ok, _ := client.Extension("STARTTLS"); !ok {
			return errors.New("notify_smtp_starttls_required")
		}
		if err := client.StartTLS(tlsConfig); err != nil {
			return errors.New("notify_smtp_tls_failed")
		}
	}
	if err := client.Auth(smtp.PlainAuth("", cfg.SMTPUsername, cfg.SMTPPassword, cfg.SMTPHost)); err != nil {
		return errors.New("notify_smtp_auth_failed")
	}
	if err := client.Mail(cfg.SMTPFrom); err != nil {
		return errors.New("notify_smtp_sender_failed")
	}
	for _, recipient := range smtpRecipients(cfg.SMTPTo) {
		if err := client.Rcpt(recipient); err != nil {
			return errors.New("notify_smtp_recipient_failed")
		}
	}
	writer, err := client.Data()
	if err != nil {
		return errors.New("notify_smtp_data_failed")
	}
	// Every notification has a plain-text fallback and a branded/custom HTML part.
	message, buildErr := buildEmailMessage(cfg, event)
	if buildErr != nil {
		writer.Close()
		return errors.New("notify_email_template_invalid")
	}
	_, err = writer.Write(message)
	closeErr := writer.Close()
	if err != nil || closeErr != nil {
		return errors.New("notify_smtp_write_failed")
	}
	return client.Quit()
}
func mimeHeader(value string) string {
	return "=?UTF-8?B?" + base64.StdEncoding.EncodeToString([]byte(value)) + "?="
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
func (h *Hub) deliver(client *http.Client, cfg Config, event Event, channels []string) error {
	var failures []error
	wants := func(id string) bool {
		if len(channels) == 0 {
			return true
		}
		for _, ch := range channels {
			if ch == id {
				return true
			}
		}
		return false
	}
	if cfg.BarkKey != "" && wants("bark") {
		if err := sendBark(client, cfg, event); err != nil {
			slogFailure("bark", event.Code, err)
			failures = append(failures, err)
		}
	}
	if cfg.WebhookURL != "" && wants("webhook") {
		if err := sendWebhook(client, cfg, event); err != nil {
			slogFailure("webhook", event.Code, err)
			failures = append(failures, err)
		}
	}
	if cfg.WecomWebhook != "" && wants("wecom") {
		if err := sendRobot(client, cfg.WecomWebhook, event, false, ""); err != nil {
			failures = append(failures, err)
			slogFailure("wecom", event.Code, err)
		}
	}
	if cfg.DingtalkWebhook != "" && wants("dingtalk") {
		if err := sendRobot(client, cfg.DingtalkWebhook, event, true, cfg.DingtalkSecret); err != nil {
			failures = append(failures, err)
			slogFailure("dingtalk", event.Code, err)
		}
	}
	if cfg.SMTPHost != "" && wants("email") {
		if err := sendEmail(cfg, event); err != nil {
			failures = append(failures, err)
			slogFailure("email", event.Code, errors.New("smtp_delivery_failed"))
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
	// Errors must never include endpoint URLs; webhook query strings can be keys.
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
		return errors.New("notify_http_network_failed")
	}
	defer response.Body.Close()
	// Drain a bounded amount so the connection can be reused, then judge.
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4<<10))
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("notify_delivery_status: %s", response.Status)
	}
	return nil
}
