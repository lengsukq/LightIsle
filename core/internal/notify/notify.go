// Package notify delivers a small set of owner-configured outbound
// notifications (Bark push, generic webhook) for alert state transitions and
// discrete task outcomes. Channel secrets arrive only through the Mac App's
// private IPC and are held in memory; nothing here is persisted. Message
// bodies must never carry file paths, serial numbers or account names.
package notify

import (
	"context"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	defaultBarkServer = "https://api.day.app"
	queueCapacity     = 16
	sendTimeout       = 10 * time.Second
	minSendInterval   = time.Second
	backoffAfterFails = 3
	backoffDuration   = 5 * time.Minute
	testEventCode     = "notify_test"
	maxTitleLen       = 120
	maxBodyLen        = 500
)

// Config names the enabled channels. An empty Bark key or webhook URL simply
// disables that channel; a hub with no channel configured drops events.
// JSON tags exist for the private Mac App IPC encoding; secrets arrive only
// on that pipe and are never persisted or logged by this package.
type Config struct {
	BarkServer      string `json:"barkServer,omitempty"`
	BarkKey         string `json:"barkKey,omitempty"`
	WebhookURL      string `json:"webhookURL,omitempty"`
	WecomWebhook    string `json:"wecomWebhook,omitempty"`
	DingtalkWebhook string `json:"dingtalkWebhook,omitempty"`
	DingtalkSecret  string `json:"dingtalkSecret,omitempty"`
	SMTPHost        string `json:"smtpHost,omitempty"`
	SMTPPort        int    `json:"smtpPort,omitempty"`
	SMTPUsername    string `json:"smtpUsername,omitempty"`
	SMTPPassword    string `json:"smtpPassword,omitempty"`
	SMTPFrom        string `json:"smtpFrom,omitempty"`
	SMTPTo          string `json:"smtpTo,omitempty"`
	// AllowPrivateTargets permits loopback/LAN endpoints for self-hosted
	// bark servers or webhooks; the default rejects them.
	AllowPrivateTargets bool `json:"allowPrivateTargets,omitempty"`
}
type delivery struct {
	Event    Event
	Channels []string
	Report   func(channel, status string)
}

func (c Config) Channels() []string {
	var out []string
	if c.BarkKey != "" {
		out = append(out, "bark")
	}
	if c.WebhookURL != "" {
		out = append(out, "webhook")
	}
	if c.SMTPHost != "" {
		out = append(out, "email")
	}
	if c.WecomWebhook != "" {
		out = append(out, "wecom")
	}
	if c.DingtalkWebhook != "" {
		out = append(out, "dingtalk")
	}
	return out
}
func (h *Hub) ConfiguredChannels() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.cfg.Channels()
}

// Event is one outbound notification. Code is a stable identifier for logs
// only (alert code or task event), never part of the delivered payload.
type Event struct {
	Code     string
	Title    string
	Body     string
	Severity string
	// Mail-only fields: content uses the LightIsle branded outer wrapper,
	// custom completely replaces it. Other channels always use plain text.
	EmailMode    string
	EmailHTML    string
	EmailSubject string
}

// Hub serializes deliveries on one worker, drops instead of blocking callers,
// and backs off after repeated channel failures so a dead endpoint cannot
// accumulate work or spam logs.
type Hub struct {
	mu     sync.Mutex
	cfg    Config
	ctx    context.Context
	cancel context.CancelFunc
	wg     sync.WaitGroup

	queue     chan delivery
	failures  int
	quietTill time.Time
	dropped   uint64
}

// ValidateConfig normalizes and checks the channel definitions. BarkServer is
// optional and must be a bare origin; the webhook URL may carry a path.
func ValidateConfig(cfg Config) (Config, error) {
	if cfg.BarkKey != "" {
		server := strings.TrimSpace(cfg.BarkServer)
		if server == "" {
			server = defaultBarkServer
		}
		origin, err := validateOrigin(server)
		if err != nil {
			return Config{}, err
		}
		cfg.BarkServer = origin
	}
	if cfg.WebhookURL != "" {
		endpoint, err := validateEndpoint(cfg.WebhookURL)
		if err != nil {
			return Config{}, err
		}
		cfg.WebhookURL = endpoint
	}
	for _, raw := range []*string{&cfg.WecomWebhook, &cfg.DingtalkWebhook} {
		if *raw != "" {
			endpoint, err := validateEndpoint(*raw)
			if err != nil {
				return Config{}, err
			}
			*raw = endpoint
		}
	}
	if err := validateSMTP(cfg); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

// New starts a hub for the given channels. An unusable configuration is
// reported immediately; a hub without channels is valid and inert.
func New(cfg Config) (*Hub, error) {
	normalized, err := ValidateConfig(cfg)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	hub := &Hub{
		cfg:    normalized,
		ctx:    ctx,
		cancel: cancel,
		queue:  make(chan delivery, queueCapacity),
	}
	hub.wg.Add(1)
	go hub.worker()
	return hub, nil
}

// Update replaces the channel configuration for future deliveries.
func (h *Hub) Update(cfg Config) error {
	normalized, err := ValidateConfig(cfg)
	if err != nil {
		return err
	}
	h.mu.Lock()
	h.cfg = normalized
	h.mu.Unlock()
	return nil
}

// Configured reports whether any delivery channel is enabled.
func (h *Hub) Configured() bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.cfg.Channels()) > 0
}

// Notify enqueues an event without ever blocking the caller. Events are
// dropped when the queue is full or the hub is backing off; delivery is
// best-effort and never retries beyond the queue.
func (h *Hub) Notify(event Event) { h.NotifyTo(event, nil) }

// NotifyTo restricts a task event to the configured named channels. Nil
// keeps the original global alert behavior (all enabled channels).
func (h *Hub) NotifyTo(event Event, channels []string) {
	h.enqueue(event, channels, nil)
}

func (h *Hub) NotifyTracked(event Event, channels []string, report func(channel, status string)) {
	h.enqueue(event, channels, report)
}

func (d delivery) reportAll(status string) {
	if d.Report != nil {
		for _, channel := range d.Channels {
			d.Report(channel, status)
		}
	}
}

func (h *Hub) enqueue(event Event, channels []string, report func(channel, status string)) {
	event.Title = clamp(event.Title, maxTitleLen)
	event.Body = clamp(event.Body, maxBodyLen)
	h.mu.Lock()
	configured := len(h.cfg.Channels()) > 0
	quiet := time.Now().Before(h.quietTill)
	h.mu.Unlock()
	d := delivery{Event: event, Channels: append([]string(nil), channels...), Report: report}
	switch {
	case h.ctx.Err() != nil:
		d.reportAll("interrupted")
		return
	case !configured:
		d.reportAll("not_configured")
		return
	case quiet:
		d.reportAll("backoff")
		return
	}
	select {
	case h.queue <- d:
	default:
		d.reportAll("queue_full")
		h.mu.Lock()
		h.dropped++
		h.mu.Unlock()
		slog.Warn("notification dropped: queue full", "code", event.Code)
	}
}

// TestSend delivers one synchronous probe event so the Mac App can verify a
// newly entered channel before saving it. It ignores the backoff window.
func (h *Hub) TestSend() error {
	h.mu.Lock()
	cfg := h.cfg
	client := h.clientLocked()
	h.mu.Unlock()
	defer client.CloseIdleConnections()
	if len(cfg.Channels()) == 0 {
		return ErrNoChannel
	}
	event := Event{
		Code:     testEventCode,
		Title:    "LightIsle 通知测试",
		Body:     "收到这条消息说明通知通道配置有效。",
		Severity: "info",
	}
	return h.deliver(client, cfg, event, nil)
}

// Close stops the worker; queued events are abandoned.
func (h *Hub) Close() {
	h.cancel()
	h.wg.Wait()
}

// Stats reports channel liveness for the Mac App status surface.
type Stats struct {
	Configured bool   `json:"configured"`
	Queued     int    `json:"queued"`
	Dropped    uint64 `json:"dropped"`
	Failures   int    `json:"failures"`
	BackingOff bool   `json:"backingOff"`
}

func (h *Hub) Stats() Stats {
	h.mu.Lock()
	defer h.mu.Unlock()
	return Stats{
		Configured: len(h.cfg.Channels()) > 0,
		Queued:     len(h.queue),
		Dropped:    h.dropped,
		Failures:   h.failures,
		BackingOff: time.Now().Before(h.quietTill),
	}
}

func (h *Hub) worker() {
	defer h.wg.Done()
	var lastSend time.Time
	for {
		select {
		case <-h.ctx.Done():
			return
		case queued := <-h.queue:
			if wait := minSendInterval - time.Since(lastSend); wait > 0 {
				select {
				case <-time.After(wait):
				case <-h.ctx.Done():
					return
				}
			}
			h.mu.Lock()
			if queued.Report != nil && time.Now().Before(h.quietTill) {
				h.mu.Unlock()
				queued.reportAll("backoff")
				continue
			}
			cfg := h.cfg
			client := h.clientLocked()
			h.mu.Unlock()
			err := h.deliverTracked(client, cfg, queued.Event, queued.Channels, queued.Report)
			client.CloseIdleConnections()
			lastSend = time.Now()
			h.mu.Lock()
			if err != nil {
				h.failures++
				if h.failures >= backoffAfterFails {
					h.quietTill = time.Now().Add(backoffDuration)
					slog.Warn("notification channels failing; backing off",
						"error", err, "until", h.quietTill)
				}
			} else {
				h.failures = 0
			}
			h.mu.Unlock()
		}
	}
}

// clientLocked captures the same private-target policy as the config used
// for this delivery. An update cannot widen an in-flight connection's policy.
func (h *Hub) clientLocked() *http.Client {
	transport := &http.Transport{
		MaxResponseHeaderBytes: 32 << 10,
		DialContext: (&net.Dialer{
			Timeout: sendTimeout,
			Control: targetGuard(h.cfg.AllowPrivateTargets),
		}).DialContext,
	}
	return &http.Client{
		Transport: transport,
		Timeout:   sendTimeout,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
}

func targetGuard(allowPrivate bool) func(string, string, syscall.RawConn) error {
	return func(_ string, address string, _ syscall.RawConn) error {
		host, _, err := net.SplitHostPort(address)
		if err != nil {
			return err
		}
		ip := net.ParseIP(strings.SplitN(host, "%", 2)[0])
		if ip == nil || (!allowPrivate && isPrivateTarget(ip)) {
			return ErrPrivateTarget
		}
		return nil
	}
}

var carrierNAT = &net.IPNet{IP: net.IPv4(100, 64, 0, 0).To4(), Mask: net.CIDRMask(10, 32)}

func isPrivateTarget(ip net.IP) bool {
	return !ip.IsGlobalUnicast() || ip.IsPrivate() || carrierNAT.Contains(ip)
}

func clamp(value string, limit int) string {
	value = strings.TrimSpace(value)
	if len(value) <= limit {
		return value
	}
	return value[:limit]
}
