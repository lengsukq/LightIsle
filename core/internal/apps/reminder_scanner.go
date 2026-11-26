package apps

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"unicode"

	"github.com/lengsukq/lightisle/core/internal/safego"
)

const (
	defaultReminderScanInterval = 30 * time.Minute
	reminderKVKey               = "_reminders"
	reminderStateFileName       = "apps-reminder-state.json"
	maxReminderItemsPerApp      = 200
	defaultReminderWarnDays     = 7
	maxReminderWarnDays         = 90
	maxOverdueReminderDays      = 30
	reminderStateRetentionDays  = 60
)

// AppReminderPayload is the standard JSON contract stored in kv/_reminders.json
// by static light apps that wish to trigger host notifications.
type AppReminderPayload struct {
	Items []AppReminderItem `json:"items"`
}

// AppReminderItem describes a single due-date reminder emitted by a light app.
type AppReminderItem struct {
	ID       string `json:"id"`
	Title    string `json:"title"`
	DueDate  string `json:"dueDate"`            // YYYY-MM-DD
	WarnDays int    `json:"warnDays,omitempty"` // defaults to 7
	Category string `json:"category,omitempty"`
}

type reminderDedupLedger struct {
	Sent map[string]string `json:"sent"`
}

type pendingReminderAlert struct {
	code     string
	title    string
	body     string
	severity string
}

// SetReminderNotifier injects the host notification callback used by the light
// app reminder scanner.
func (m *Manager) SetReminderNotifier(fn func(code, title, body, severity string)) {
	m.mu.Lock()
	m.reminderNotifier = fn
	m.mu.Unlock()
}

// SetReminderScanInterval overrides the background scan cadence (primarily for tests).
func (m *Manager) SetReminderScanInterval(d time.Duration) {
	if d > 0 {
		m.mu.Lock()
		m.reminderScanInterval = d
		m.mu.Unlock()
	}
}

// StartReminderScanner launches a lightweight background goroutine that periodically
// reads kv/_reminders.json from online enabled apps and emits deduplicated alerts.
// Calling it more than once is a safe no-op.
func (m *Manager) StartReminderScanner(ctx context.Context) {
	if ctx == nil {
		ctx = context.Background()
	}
	m.mu.Lock()
	if m.closed || m.reminderScannerStarted {
		m.mu.Unlock()
		return
	}
	m.reminderScannerStarted = true
	m.wg.Add(1)
	m.mu.Unlock()

	safego.Go("apps-reminder-scanner", func() {
		defer m.wg.Done()
		m.ScanAppReminders(time.Now())
		for {
			m.mu.RLock()
			interval := m.reminderScanInterval
			m.mu.RUnlock()
			if interval <= 0 {
				interval = defaultReminderScanInterval
			}
			timer := time.NewTimer(interval)
			select {
			case <-ctx.Done():
				timer.Stop()
				return
			case <-m.stopCh:
				timer.Stop()
				return
			case now := <-timer.C:
				m.ScanAppReminders(now)
			}
		}
	})
}

// ScanAppReminders performs one synchronous pass across all online enabled apps,
// persists deduplication keys, and emits sanitized notifications for newly matched
// reminder buckets. Returns the number of alerts dispatched.
func (m *Manager) ScanAppReminders(now time.Time) int {
	m.mu.RLock()
	notifier := m.reminderNotifier
	records := make([]appRecord, 0, len(m.apps))
	for _, rec := range m.apps {
		if rec.valid && !rec.pendingActivation && rec.manifest.Web != nil && rec.manifest.Web.Enabled {
			records = append(records, *rec)
		}
	}
	m.mu.RUnlock()

	if notifier == nil || len(records) == 0 {
		return 0
	}
	sort.Slice(records, func(i, j int) bool { return records[i].id < records[j].id })

	sysCfg, cfgErr := readSystemConfigFile(m.configPath)

	m.reminderMu.Lock()
	ledger := m.loadReminderLedgerLocked(now)
	dirty := false
	alerts := make([]pendingReminderAlert, 0, 8)

	for i := range records {
		rec := &records[i]
		if cfgErr == nil {
			if err := m.verifyRecordStorageOnlineWithConfig(sysCfg, rec.locationID, rec.pluginDir); err != nil {
				continue
			}
		}
		payload, ok := m.readAppReminders(rec)
		if !ok || len(payload.Items) == 0 {
			continue
		}
		appName := sanitizeReminderText(rec.manifest.Name, 36)
		if appName == "" {
			appName = rec.id
		}
		limit := len(payload.Items)
		if limit > maxReminderItemsPerApp {
			limit = maxReminderItemsPerApp
		}
		for _, item := range payload.Items[:limit] {
			alert, dedupKey, matched := evaluateReminderItem(rec.id, appName, item, now)
			if !matched {
				continue
			}
			if _, alreadySent := ledger.Sent[dedupKey]; alreadySent {
				continue
			}
			ledger.Sent[dedupKey] = now.UTC().Format(time.RFC3339)
			dirty = true
			alerts = append(alerts, alert)
		}
	}

	if dirty {
		if err := m.saveReminderLedgerLocked(ledger); err != nil {
			slog.Warn("failed to persist app reminder dedup ledger", "error", err)
		}
	}
	m.reminderMu.Unlock()

	for _, alert := range alerts {
		notifier(alert.code, alert.title, alert.body, alert.severity)
	}
	return len(alerts)
}

func (m *Manager) readAppReminders(rec *appRecord) (AppReminderPayload, bool) {
	mu := m.kvAppLock(rec.id)
	mu.Lock()
	defer mu.Unlock()

	dataRoot, kvRoot, err := openKVRootReadOnly(rec.dataDir)
	if err != nil {
		return AppReminderPayload{}, false
	}
	defer dataRoot.Close()
	defer kvRoot.Close()

	raw, _, err := readCheckedFile(kvRoot, reminderKVKey+".json", maxKVValueBytes)
	if err != nil {
		return AppReminderPayload{}, false
	}
	var payload AppReminderPayload
	if err := json.Unmarshal(raw, &payload); err != nil {
		return AppReminderPayload{}, false
	}
	return payload, true
}

func evaluateReminderItem(appID, appName string, item AppReminderItem, now time.Time) (pendingReminderAlert, string, bool) {
	itemID := sanitizeReminderText(item.ID, 64)
	title := sanitizeReminderText(item.Title, 60)
	dueDate := strings.TrimSpace(item.DueDate)
	if itemID == "" || title == "" || len(dueDate) != 10 {
		return pendingReminderAlert{}, "", false
	}

	loc := now.Location()
	due, err := time.ParseInLocation("2006-01-02", dueDate, loc)
	if err != nil {
		return pendingReminderAlert{}, "", false
	}
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, loc)
	daysLeft := int(math.Round(due.Sub(today).Hours() / 24))

	warnDays := item.WarnDays
	if warnDays <= 0 {
		warnDays = defaultReminderWarnDays
	}
	if warnDays > maxReminderWarnDays {
		warnDays = maxReminderWarnDays
	}

	bucket, code, severity, ok := classifyReminderBucket(daysLeft, warnDays)
	if !ok {
		return pendingReminderAlert{}, "", false
	}

	var body string
	switch {
	case daysLeft < 0:
		body = fmt.Sprintf("「%s」已过期 %d 天（到期日 %s）", title, -daysLeft, dueDate)
	case daysLeft == 0:
		body = fmt.Sprintf("「%s」今天到期（%s）", title, dueDate)
	default:
		body = fmt.Sprintf("「%s」还有 %d 天到期（%s）", title, daysLeft, dueDate)
	}

	dedupKey := fmt.Sprintf("%s|%s|%s|%s", appID, itemID, dueDate, bucket)
	return pendingReminderAlert{
		code:     code,
		title:    "轻应用提醒：" + appName,
		body:     body,
		severity: severity,
	}, dedupKey, true
}

func classifyReminderBucket(daysLeft, warnDays int) (bucket, code, severity string, matched bool) {
	if daysLeft > warnDays {
		return "", "", "", false
	}
	switch {
	case daysLeft < -maxOverdueReminderDays:
		return "", "", "", false
	case daysLeft < 0:
		return "overdue", "app_reminder_overdue", "warning", true
	case daysLeft == 0:
		return "due_today", "app_reminder_due", "warning", true
	case daysLeft == 1:
		return "due_1d", "app_reminder_due", "warning", true
	case daysLeft <= 3:
		return "due_3d", "app_reminder_due", "info", true
	case daysLeft <= 7:
		return "due_7d", "app_reminder_due", "info", true
	default:
		return "due_warn", "app_reminder_due", "info", true
	}
}

func sanitizeReminderText(input string, maxRunes int) string {
	var b strings.Builder
	b.Grow(len(input))
	prevSpace := false
	for _, r := range strings.TrimSpace(input) {
		if unicode.IsControl(r) {
			continue
		}
		if unicode.IsSpace(r) {
			if !prevSpace {
				b.WriteRune(' ')
				prevSpace = true
			}
			continue
		}
		prevSpace = false
		b.WriteRune(r)
	}
	clean := strings.TrimSpace(b.String())
	if maxRunes <= 0 {
		return clean
	}
	runes := []rune(clean)
	if len(runes) > maxRunes {
		return string(runes[:maxRunes]) + "…"
	}
	return clean
}

func (m *Manager) reminderStatePath() string {
	return filepath.Join(m.dataDir, reminderStateFileName)
}

func (m *Manager) loadReminderLedgerLocked(now time.Time) reminderDedupLedger {
	ledger := reminderDedupLedger{Sent: make(map[string]string)}
	raw, err := os.ReadFile(m.reminderStatePath())
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			slog.Warn("failed to read app reminder state", "error", err)
		}
		return ledger
	}
	var parsed reminderDedupLedger
	if err := json.Unmarshal(raw, &parsed); err != nil || parsed.Sent == nil {
		return ledger
	}
	cutoff := now.AddDate(0, 0, -reminderStateRetentionDays)
	for k, ts := range parsed.Sent {
		if parsedAt, parseErr := time.Parse(time.RFC3339, ts); parseErr == nil && parsedAt.After(cutoff) {
			ledger.Sent[k] = ts
		}
	}
	return ledger
}

func (m *Manager) saveReminderLedgerLocked(ledger reminderDedupLedger) error {
	path := m.reminderStatePath()
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	raw, err := json.MarshalIndent(ledger, "", "  ")
	if err != nil {
		return err
	}
	tmp := fmt.Sprintf("%s.%d.tmp", path, time.Now().UnixNano())
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	if _, err := f.Write(raw); err != nil {
		_ = f.Close()
		_ = os.Remove(tmp)
		return err
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		_ = os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}
