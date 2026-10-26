// Package notify delivers a small set of owner-configured outbound
// notifications (Bark push, generic webhook) for alert state transitions and
// discrete task outcomes. Channel secrets arrive only through the Mac App's
// private IPC and are held in memory; nothing here is persisted. Message
// bodies must never carry file paths, serial numbers or account names.
package notify

import (
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
type Config struct {
	BarkServer string
	BarkKey    string
	WebhookURL string
	// AllowPrivateTargets permits loopback/LAN endpoints for self-hosted
	// bark servers or webhooks; the default rejects them.
	AllowPrivateTargets bool
}

// Event is one outbound notification. Code is a stable identifier for logs
// only (alert code or task event), never part of the delivered payload.
type Event struct {
	Code     string
	Title    string
	Body     string
	Severity string
}

// Hub serializes deliveries on one worker, drops instead of blocking callers,
// and backs off after repeated channel failures so a dead endpoint cannot
// accumulate work or spam logs.
type Hub struct {
	mu   sync.Mutex
	cfg  Config
	stop chan struct{}
	wg   sync.WaitGroup

	queue     chan Event
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
	return cfg, nil
}

// New starts a hub for the given channels. An unusable configuration is
// reported immediately; a hub without channels is valid and inert.
func New(cfg Config) (*Hub, error) {
	normalized, err := ValidateConfig(cfg)
	if err != nil {
		return nil, err
	}
	hub := &Hub{
		cfg:   normalized,
		stop:  make(chan struct{}),
		queue: make(chan Event, queueCapacity),
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
	return h.cfg.BarkKey != "" || h.cfg.WebhookURL != ""
}

// Notify enqueues an event without ever blocking the caller. Events are
// dropped when the queue is full or the hub is backing off; delivery is
// best-effort and never retries beyond the queue.
func (h *Hub) Notify(event Event) {
	event.Title = clamp(event.Title, maxTitleLen)
	event.Body = clamp(event.Body, maxBodyLen)
	h.mu.Lock()
	configured := h.cfg.BarkKey != "" || h.cfg.WebhookURL != ""
	quiet := time.Now().Before(h.quietTill)
	h.mu.Unlock()
	if !configured || quiet {
		return
	}
	select {
	case h.queue <- event:
	default:
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
	if cfg.BarkKey == "" && cfg.WebhookURL == "" {
		return ErrNoChannel
	}
	event := Event{
		Code:     testEventCode,
		Title:    "LightIsle 通知测试",
		Body:     "收到这条消息说明通知通道配置有效。",
		Severity: "info",
	}
	return h.deliver(client, cfg, event)
}

// Close stops the worker; queued events are abandoned.
func (h *Hub) Close() {
	close(h.stop)
	h.wg.Wait()
}

// Stats reports channel liveness for the Mac App status surface.
type Stats struct {
	Configured bool
	Queued     int
	Dropped    uint64
	Failures   int
	BackingOff bool
}

func (h *Hub) Stats() Stats {
	h.mu.Lock()
	defer h.mu.Unlock()
	return Stats{
		Configured: h.cfg.BarkKey != "" || h.cfg.WebhookURL != "",
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
		case <-h.stop:
			return
		case event := <-h.queue:
			if wait := minSendInterval - time.Since(lastSend); wait > 0 {
				select {
				case <-time.After(wait):
				case <-h.stop:
					return
				}
			}
			h.mu.Lock()
			cfg := h.cfg
			client := h.clientLocked()
			h.mu.Unlock()
			err := h.deliver(client, cfg, event)
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

// clientLocked builds the transport on demand; the dial guard consults the
// current configuration on every connection so Update takes effect at once.
func (h *Hub) clientLocked() *http.Client {
	transport := &http.Transport{
		Proxy: nil,
		DialContext: (&net.Dialer{
			Timeout: sendTimeout,
			Control: h.guardDial,
		}).DialContext,
	}
	return &http.Client{Transport: transport, Timeout: sendTimeout}
}

func (h *Hub) guardDial(network, address string, _ syscall.RawConn) error {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return err
	}
	h.mu.Lock()
	allowed := h.cfg.AllowPrivateTargets
	h.mu.Unlock()
	if allowed {
		return nil
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return nil // unresolved names are checked after resolution
	}
	if isPrivateTarget(ip) {
		return ErrPrivateTarget
	}
	return nil
}

func isPrivateTarget(ip net.IP) bool {
	return ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() ||
		ip.IsLinkLocalMulticast() || ip.IsUnspecified()
}

func clamp(value string, limit int) string {
	value = strings.TrimSpace(value)
	if len(value) <= limit {
		return value
	}
	return value[:limit]
}
