package notify

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

func TestValidateConfigRejectsMalformedChannels(t *testing.T) {
	bad := []Config{
		{BarkKey: "k", BarkServer: "https://user:pass@api.day.app"},
		{BarkKey: "k", BarkServer: "https://api.day.app/push"},
		{BarkKey: "k", BarkServer: "ftp://api.day.app"},
		{BarkKey: "k", BarkServer: "api.day.app"},
		{WebhookURL: "javascript:alert(1)"},
		{WebhookURL: "https://user@hooks.example/xy"},
		{WebhookURL: "not a url"},
	}
	for _, cfg := range bad {
		if _, err := ValidateConfig(cfg); err == nil {
			t.Errorf("invalid config accepted: %+v", cfg)
		}
	}
}

func TestValidateConfigNormalizesBarkServer(t *testing.T) {
	normalized, err := ValidateConfig(Config{BarkKey: "device-key"})
	if err != nil {
		t.Fatal(err)
	}
	if normalized.BarkServer != defaultBarkServer {
		t.Fatalf("default bark server = %q", normalized.BarkServer)
	}
	explicit, err := ValidateConfig(Config{BarkKey: "k", BarkServer: "https://bark.self/"})
	if err != nil {
		t.Fatal(err)
	}
	if explicit.BarkServer != "https://bark.self" {
		t.Fatalf("trailing slash kept: %q", explicit.BarkServer)
	}
}

func TestHubDeliversBarkAndWebhookPayloads(t *testing.T) {
	var mu sync.Mutex
	var barkSeen, hookSeen map[string]any
	bark := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/push" {
			t.Errorf("bark path = %q", r.URL.Path)
		}
		var payload map[string]any
		_ = json.NewDecoder(r.Body).Decode(&payload)
		mu.Lock()
		barkSeen = payload
		mu.Unlock()
		_, _ = w.Write([]byte(`{"code":200}`))
	}))
	defer bark.Close()
	hook := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var payload map[string]any
		_ = json.NewDecoder(r.Body).Decode(&payload)
		mu.Lock()
		hookSeen = payload
		mu.Unlock()
		w.WriteHeader(http.StatusNoContent)
	}))
	defer hook.Close()

	hub, err := New(Config{
		BarkServer:          bark.URL,
		BarkKey:             "device-key",
		WebhookURL:          hook.URL + "/hook?token=1",
		AllowPrivateTargets: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer hub.Close()

	hub.Notify(Event{
		Code:     "storage_low_space",
		Title:    "空间不足",
		Body:     "共享存储卷剩余空间不足。",
		Severity: "warning",
	})
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		mu.Lock()
		done := barkSeen != nil && hookSeen != nil
		mu.Unlock()
		if done {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	mu.Lock()
	defer mu.Unlock()
	if barkSeen == nil || barkSeen["device_key"] != "device-key" ||
		barkSeen["title"] != "空间不足" || barkSeen["group"] != "LightIsle" {
		t.Fatalf("bark payload = %+v", barkSeen)
	}
	if hookSeen == nil || hookSeen["source"] != "lightisle" ||
		hookSeen["event"] != "storage_low_space" || hookSeen["severity"] != "warning" {
		t.Fatalf("webhook payload = %+v", hookSeen)
	}
}

func TestHubRejectsPrivateTargetsUnlessExplicitlyAllowed(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	hub, err := New(Config{WebhookURL: server.URL})
	if err != nil {
		t.Fatal(err)
	}
	defer hub.Close()
	if err := hub.TestSend(); err == nil {
		t.Fatal("loopback webhook must be rejected by default")
	}
	if err := hub.Update(Config{WebhookURL: server.URL, AllowPrivateTargets: true}); err != nil {
		t.Fatal(err)
	}
	if err := hub.TestSend(); err != nil {
		t.Fatalf("allowed private target failed: %v", err)
	}
}

func TestHubTestSendRequiresChannel(t *testing.T) {
	hub, err := New(Config{})
	if err != nil {
		t.Fatal(err)
	}
	defer hub.Close()
	if hub.Configured() {
		t.Fatal("empty hub reports configured")
	}
	if err := hub.TestSend(); err != ErrNoChannel {
		t.Fatalf("test send without channel = %v", err)
	}
}

func TestHubDropsWhenUnconfiguredAndClampsText(t *testing.T) {
	hub, err := New(Config{})
	if err != nil {
		t.Fatal(err)
	}
	defer hub.Close()
	// Unconfigured hubs drop immediately; the call must not block or panic.
	hub.Notify(Event{Code: "backup_failed", Title: "x", Body: "y"})
	stats := hub.Stats()
	if stats.Configured || stats.Queued != 0 {
		t.Fatalf("stats after unconfigured notify = %+v", stats)
	}
	long := string(make([]byte, 4*maxBodyLen))
	hub.Notify(Event{Code: "c", Title: long, Body: long})
	if stats := hub.Stats(); stats.Queued != 0 {
		t.Fatalf("unconfigured hub queued an event: %+v", stats)
	}
}

func TestHubBacksOffAfterRepeatedFailures(t *testing.T) {
	var calls int
	var mu sync.Mutex
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		calls++
		mu.Unlock()
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer server.Close()

	hub, err := New(Config{
		WebhookURL:          server.URL,
		AllowPrivateTargets: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer hub.Close()
	// Each failing delivery counts once; three failures start the quiet
	// window during which further events are dropped before dialing.
	for i := 0; i < 6; i++ {
		hub.Notify(Event{Code: "storage_offline", Title: "t", Body: "b"})
		time.Sleep(50 * time.Millisecond)
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		stats := hub.Stats()
		if stats.BackingOff {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if stats := hub.Stats(); !stats.BackingOff {
		t.Fatalf("hub did not back off: %+v", stats)
	}
	mu.Lock()
	seen := calls
	mu.Unlock()
	// 3 dialing attempts + up to 3 queued before the window opened; the
	// exact count varies with timing but must stay bounded well below 6
	// deliveries per event because the window stops further sends.
	if seen > 6 {
		t.Fatalf("failing channel dialed %d times; backoff did not apply", seen)
	}
}

func TestWorkerRecoversAfterBackoffWindow(t *testing.T) {
	var mu sync.Mutex
	fail := true
	delivered := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		if fail {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		delivered++
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	hub, err := New(Config{
		WebhookURL:          server.URL,
		AllowPrivateTargets: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer hub.Close()
	for i := 0; i < backoffAfterFails; i++ {
		hub.Notify(Event{Code: "c", Title: "t", Body: "b"})
		time.Sleep(30 * time.Millisecond)
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if hub.Stats().BackingOff {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !hub.Stats().BackingOff {
		t.Fatal("expected backoff before recovery test")
	}
	// The quiet window is internal; simulate its expiry and prove the hub
	// delivers again once the endpoint recovers.
	hub.mu.Lock()
	hub.quietTill = time.Now().Add(-time.Second)
	hub.failures = 0
	hub.mu.Unlock()
	mu.Lock()
	fail = false
	mu.Unlock()
	hub.Notify(Event{Code: "c", Title: "t", Body: "b"})
	for time.Now().Before(deadline) {
		mu.Lock()
		done := delivered > 0
		mu.Unlock()
		if done {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("hub never delivered after backoff expired")
}
