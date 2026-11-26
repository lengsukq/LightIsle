package apps

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type capturedAlert struct {
	code     string
	title    string
	body     string
	severity string
}

func TestAppReminderScannerDedupAndBuckets(t *testing.T) {
	dataDir := t.TempDir()
	mgr := NewManager(dataDir, "", nil)
	defer mgr.Close()
	if err := mgr.Reload(); err != nil {
		t.Fatal(err)
	}
	if _, err := mgr.InstallTemplateAt("medicine-expiry", ""); err != nil {
		t.Fatal(err)
	}

	kvDir := filepath.Join(dataDir, "plugin-data", "medicine-expiry", "kv")
	if err := os.MkdirAll(kvDir, 0700); err != nil {
		t.Fatal(err)
	}
	payload := AppReminderPayload{
		Items: []AppReminderItem{
			{ID: "passport", Title: "护照到期\n/Users/secret/path", DueDate: "2026-06-10", WarnDays: 10, Category: "expiry"},
			{ID: "far-item", Title: "远期提醒", DueDate: "2026-08-30", WarnDays: 7, Category: "expiry"},
			{ID: "ancient", Title: "很久前过期", DueDate: "2026-01-01", WarnDays: 7, Category: "expiry"},
			{ID: "expired-2d", Title: "常备感冒药", DueDate: "2026-06-03", WarnDays: 7, Category: "expiry"},
		},
	}
	raw, _ := json.Marshal(payload)
	if err := os.WriteFile(filepath.Join(kvDir, "_reminders.json"), raw, 0600); err != nil {
		t.Fatal(err)
	}

	var mu sync.Mutex
	var alerts []capturedAlert
	mgr.SetReminderNotifier(func(code, title, body, severity string) {
		mu.Lock()
		alerts = append(alerts, capturedAlert{code: code, title: title, body: body, severity: severity})
		mu.Unlock()
	})

	loc := time.FixedZone("CST", 8*3600)
	day1 := time.Date(2026, 6, 5, 9, 0, 0, 0, loc) // passport: 5d -> due_7d; expired-2d: -2d -> overdue

	sent := mgr.ScanAppReminders(day1)
	if sent != 2 || len(alerts) != 2 {
		t.Fatalf("expected 2 alerts on day1, got sent=%d alerts=%+v", sent, alerts)
	}
	// Verify control characters/newlines were stripped
	for _, a := range alerts {
		if strings.Contains(a.body, "\n") || strings.Contains(a.body, "\r") {
			t.Fatalf("expected sanitized single-line body, got %q", a.body)
		}
	}

	// Second scan same day must emit 0 alerts (deduped)
	if again := mgr.ScanAppReminders(day1.Add(30 * time.Minute)); again != 0 {
		t.Fatalf("expected 0 duplicate alerts on same bucket, got %d", again)
	}

	// Reload fresh manager with same dataDir: persisted ledger still prevents duplicate
	mgr2 := NewManager(dataDir, "", nil)
	defer mgr2.Close()
	if err := mgr2.Reload(); err != nil {
		t.Fatal(err)
	}
	var alerts2 []capturedAlert
	mgr2.SetReminderNotifier(func(code, title, body, severity string) {
		mu.Lock()
		alerts2 = append(alerts2, capturedAlert{code: code, title: title, body: body, severity: severity})
		mu.Unlock()
	})
	if again2 := mgr2.ScanAppReminders(day1.Add(time.Hour)); again2 != 0 {
		t.Fatalf("expected persisted dedup across manager restart, got %d", again2)
	}

	// Advance to due_today (2026-06-10): passport enters new bucket "due_today" -> 1 new alert;
	// expired-2d is still in "overdue" -> stays deduped!
	dueToday := time.Date(2026, 6, 10, 9, 0, 0, 0, loc)
	if sentDue := mgr2.ScanAppReminders(dueToday); sentDue != 1 {
		t.Fatalf("expected 1 new alert when entering due_today bucket, got %d (%+v)", sentDue, alerts2)
	}
	if alerts2[0].severity != "warning" || !strings.Contains(alerts2[0].body, "今天到期") {
		t.Fatalf("unexpected due_today alert: %+v", alerts2[0])
	}
}

func TestAppReminderScannerLifecycle(t *testing.T) {
	dataDir := t.TempDir()
	mgr := NewManager(dataDir, "", nil)
	mgr.SetReminderScanInterval(20 * time.Millisecond)
	if err := mgr.Reload(); err != nil {
		t.Fatal(err)
	}
	if _, err := mgr.InstallTemplateAt("pet-care", ""); err != nil {
		t.Fatal(err)
	}

	kvDir := filepath.Join(dataDir, "plugin-data", "pet-care", "kv")
	if err := os.MkdirAll(kvDir, 0700); err != nil {
		t.Fatal(err)
	}
	today := time.Now().Format("2006-01-02")
	raw, _ := json.Marshal(AppReminderPayload{
		Items: []AppReminderItem{{ID: "deworm", Title: "橘座 · 体外驱虫", DueDate: today, WarnDays: 7, Category: "pet-care"}},
	})
	if err := os.WriteFile(filepath.Join(kvDir, "_reminders.json"), raw, 0600); err != nil {
		t.Fatal(err)
	}

	notified := make(chan capturedAlert, 4)
	mgr.SetReminderNotifier(func(code, title, body, severity string) {
		notified <- capturedAlert{code: code, title: title, body: body, severity: severity}
	})

	ctx, cancel := context.WithCancel(context.Background())
	mgr.StartReminderScanner(ctx)
	mgr.StartReminderScanner(ctx) // duplicate call must be a safe no-op

	select {
	case got := <-notified:
		if got.code != "app_reminder_due" || !strings.Contains(got.body, "橘座") {
			t.Fatalf("unexpected async alert: %+v", got)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for background reminder scanner")
	}

	cancel()
	if err := mgr.Close(); err != nil {
		t.Fatalf("Close failed: %v", err)
	}
}
