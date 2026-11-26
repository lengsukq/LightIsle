//go:build darwin && arm64

package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/apps"
	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/notify"
)

type capturedWebhookPayload struct {
	Source   string `json:"source"`
	Event    string `json:"event"`
	Severity string `json:"severity"`
	Title    string `json:"title"`
	Body     string `json:"body"`
}

func startTestNotifyWebhook(t *testing.T) (*httptest.Server, *[]capturedWebhookPayload, *sync.Mutex) {
	t.Helper()
	var mu sync.Mutex
	var events []capturedWebhookPayload
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, err := io.ReadAll(io.LimitReader(r.Body, 8<<10))
		if err != nil {
			http.Error(w, "bad body", http.StatusBadRequest)
			return
		}
		var payload capturedWebhookPayload
		if err := json.Unmarshal(raw, &payload); err != nil {
			http.Error(w, "bad json", http.StatusBadRequest)
			return
		}
		mu.Lock()
		events = append(events, payload)
		mu.Unlock()
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(srv.Close)
	return srv, &events, &mu
}

func waitForWebhookCount(t *testing.T, mu *sync.Mutex, events *[]capturedWebhookPayload, want int) {
	t.Helper()
	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		mu.Lock()
		n := len(*events)
		mu.Unlock()
		if n >= want {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	mu.Lock()
	defer mu.Unlock()
	t.Fatalf("timed out waiting for %d webhook events, got %d: %+v", want, len(*events), *events)
}

func TestAppReminderNotifierBridgesAndSanitizesToNotifyHub(t *testing.T) {
	srv, events, mu := startTestNotifyWebhook(t)
	hub, err := notify.New(notify.Config{WebhookURL: srv.URL, AllowPrivateTargets: true})
	if err != nil {
		t.Fatal(err)
	}
	defer hub.Close()

	dataDir := t.TempDir()
	mgr := apps.NewManager(dataDir, "", nil)
	mgr.SetReminderScanInterval(25 * time.Millisecond)
	defer mgr.Close()
	if err := mgr.Reload(); err != nil {
		t.Fatal(err)
	}
	if _, err := mgr.InstallTemplateAt("medicine-expiry", ""); err != nil {
		t.Fatal(err)
	}

	kvDir := filepath.Join(dataDir, "plugin-data", "medicine-expiry", "kv")
	if err := os.MkdirAll(kvDir, 0o700); err != nil {
		t.Fatal(err)
	}
	today := time.Now().Format("2006-01-02")
	raw, _ := json.Marshal(apps.AppReminderPayload{
		Items: []apps.AppReminderItem{
			{ID: "med-1", Title: "常备退烧药\n\t请查看", DueDate: today, WarnDays: 7},
		},
	})
	if err := os.WriteFile(filepath.Join(kvDir, "_reminders.json"), raw, 0o600); err != nil {
		t.Fatal(err)
	}

	mgr.SetReminderNotifier(newAppReminderNotifier(hub))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	mgr.StartReminderScanner(ctx)

	waitForWebhookCount(t, mu, events, 1)

	mu.Lock()
	got := (*events)[0]
	mu.Unlock()
	if got.Event != "app_reminder_due" || got.Severity != "warning" || !strings.Contains(got.Title, "轻应用提醒") {
		t.Fatalf("unexpected bridged app reminder event: %+v", got)
	}
	if strings.ContainsAny(got.Body, "\n\r\t") || !strings.Contains(got.Body, "常备退烧药") {
		t.Fatalf("expected sanitized single-line body, got %q", got.Body)
	}
	cancel()
}

func TestFamilyReminderLoopScansDesensitizesAndStopsOnCancel(t *testing.T) {
	srv, events, mu := startTestNotifyWebhook(t)
	hub, err := notify.New(notify.Config{WebhookURL: srv.URL, AllowPrivateTargets: true})
	if err != nil {
		t.Fatal(err)
	}
	defer hub.Close()

	accounts, err := auth.Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("admin", "AdminPass123456!"); err != nil {
		t.Fatal(err)
	}
	adminTok, err := accounts.Login("admin", "AdminPass123456!")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := accounts.CreateUser(adminTok, "secret_member_name", "MemberPass123456!", auth.RoleMember); err != nil {
		t.Fatal(err)
	}
	memberTok, err := accounts.Login("secret_member_name", "MemberPass123456!")
	if err != nil {
		t.Fatal(err)
	}

	fixedNow := time.Date(2025, 7, 18, 9, 0, 0, 0, time.UTC)
	// Lunar leap 6th month day 1 in 2025 is 2025-07-25 (7 days away).
	if _, err := accounts.CreateFamilyReminder(adminTok, auth.FamilyReminderInput{
		Title:        "妈妈生日",
		Category:     "birthday",
		CalendarType: "lunar",
		Year:         1987,
		Month:        6,
		Day:          1,
		IsLeapMonth:  true,
		RepeatRule:   "yearly",
		RemindDays:   []int{7, 1, 0},
		Notes:        "/Volumes/PrivateDisk/sensitive-note",
	}, fixedNow); err != nil {
		t.Fatal(err)
	}
	// Solar chore due today.
	if _, err := accounts.CreateFamilyReminder(memberTok, auth.FamilyReminderInput{
		Title:        "换净水器滤芯",
		Category:     "chore",
		CalendarType: "solar",
		Year:         2025,
		Month:        7,
		Day:          18,
		RepeatRule:   "interval_days",
		IntervalDays: 90,
		RemindDays:   []int{3, 0},
		Notes:        "/Users/secret_member_name/private.txt",
	}, fixedNow); err != nil {
		t.Fatal(err)
	}

	loop := &reminderLoop{
		scanner:      accounts,
		hub:          hub,
		interval:     20 * time.Millisecond,
		startupGrace: 0,
		nowFn:        func() time.Time { return fixedNow },
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		loop.Run(ctx)
	}()

	waitForWebhookCount(t, mu, events, 2)
	// Allow several extra ticks to verify deduplication prevents repeat sends.
	time.Sleep(120 * time.Millisecond)

	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("reminderLoop did not stop gracefully on ctx cancel")
	}

	mu.Lock()
	captured := append([]capturedWebhookPayload(nil), (*events)...)
	mu.Unlock()
	if len(captured) != 2 {
		t.Fatalf("expected exactly 2 deduplicated family reminders, got %d: %+v", len(captured), captured)
	}
	for _, ev := range captured {
		if ev.Event != "family_reminder_due" || !strings.Contains(ev.Title, "家庭提醒：") {
			t.Fatalf("unexpected family reminder event: %+v", ev)
		}
		combined := ev.Title + " " + ev.Body
		if strings.Contains(combined, "/Volumes") || strings.Contains(combined, "/Users") || strings.Contains(combined, "secret_member_name") || strings.Contains(combined, "sensitive-note") {
			t.Fatalf("family reminder leaked private path/note/account: %+v", ev)
		}
	}
}

func TestFamilyReminderLoopSkipsUnconfiguredHubUntilConfigured(t *testing.T) {
	srv, events, mu := startTestNotifyWebhook(t)
	hub, err := notify.New(notify.Config{})
	if err != nil {
		t.Fatal(err)
	}
	defer hub.Close()

	accounts, err := auth.Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("admin", "AdminPass123456!"); err != nil {
		t.Fatal(err)
	}
	adminTok, err := accounts.Login("admin", "AdminPass123456!")
	if err != nil {
		t.Fatal(err)
	}
	fixedNow := time.Date(2026, 5, 10, 8, 0, 0, 0, time.UTC)
	if _, err := accounts.CreateFamilyReminder(adminTok, auth.FamilyReminderInput{
		Title:        "物业缴费",
		Category:     "bill",
		CalendarType: "solar",
		Year:         2026,
		Month:        5,
		Day:          10,
		RepeatRule:   "once",
		RemindDays:   []int{0},
	}, fixedNow); err != nil {
		t.Fatal(err)
	}

	loop := &reminderLoop{scanner: accounts, hub: hub}
	if sent := loop.runOnce(context.Background(), fixedNow); sent != 0 {
		t.Fatalf("expected 0 sent when hub unconfigured, got %d", sent)
	}
	if err := hub.Update(notify.Config{WebhookURL: srv.URL, AllowPrivateTargets: true}); err != nil {
		t.Fatal(err)
	}
	if sent := loop.runOnce(context.Background(), fixedNow); sent != 1 {
		t.Fatalf("expected 1 sent after hub configured (dedup not prematurely burned), got %d", sent)
	}
	waitForWebhookCount(t, mu, events, 1)
}
