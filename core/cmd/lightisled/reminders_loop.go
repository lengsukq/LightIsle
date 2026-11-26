//go:build darwin && arm64

package main

import (
	"context"
	"log/slog"
	"time"

	"github.com/lengsukq/lightisle/core/internal/apps"
	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/notify"
)

const (
	familyReminderScanInterval = 30 * time.Minute
	reminderStartupGrace       = 5 * time.Second
	reminderStartupPoll        = 200 * time.Millisecond
	maxReminderTitleRunes      = 120
	maxReminderBodyRunes       = 480
)

type familyReminderScanner interface {
	ScanDueReminders(now time.Time) ([]auth.DueFamilyReminder, error)
}

type reminderNotifier interface {
	Configured() bool
	Notify(event notify.Event)
}

type appReminderRunner interface {
	StartReminderScanner(ctx context.Context)
}

type reminderLoop struct {
	scanner      familyReminderScanner
	apps         appReminderRunner
	hub          reminderNotifier
	interval     time.Duration
	startupGrace time.Duration
	startupPoll  time.Duration
	nowFn        func() time.Time
}

func newReminderLoop(accounts *auth.Store, appsManager *apps.Manager, hub *notify.Hub) *reminderLoop {
	var scanner familyReminderScanner
	if accounts != nil {
		scanner = accounts
	}
	var appRunner appReminderRunner
	if appsManager != nil {
		appRunner = appsManager
		if hub != nil {
			appsManager.SetReminderReadyCheck(hub.Configured)
		}
	}
	var notifier reminderNotifier
	if hub != nil {
		notifier = hub
	}
	return &reminderLoop{
		scanner:      scanner,
		apps:         appRunner,
		hub:          notifier,
		interval:     familyReminderScanInterval,
		startupGrace: reminderStartupGrace,
		startupPoll:  reminderStartupPoll,
		nowFn:        time.Now,
	}
}

// newAppReminderNotifier bridges light-app reminder alerts into notify.Hub,
// keeping outbound payloads single-line and bounded.
func newAppReminderNotifier(hub reminderNotifier) func(code, title, body, severity string) {
	return func(code, title, body, severity string) {
		if hub == nil || !hub.Configured() {
			return
		}
		cleanTitle := apps.SanitizeReminderText(title, maxReminderTitleRunes)
		cleanBody := apps.SanitizeReminderText(body, maxReminderBodyRunes)
		if cleanTitle == "" || cleanBody == "" {
			return
		}
		if severity != "warning" && severity != "critical" {
			severity = "info"
		}
		hub.Notify(notify.Event{
			Code:     code,
			Title:    cleanTitle,
			Body:     cleanBody,
			Severity: severity,
		})
	}
}

func (l *reminderLoop) Run(ctx context.Context) {
	if ctx == nil {
		ctx = context.Background()
	}
	l.waitForNotifyConfigured(ctx)
	if ctx.Err() != nil {
		return
	}
	if l.apps != nil {
		l.apps.StartReminderScanner(ctx)
	}
	nowFn := l.nowFn
	if nowFn == nil {
		nowFn = time.Now
	}
	l.runOnce(ctx, nowFn())

	interval := l.interval
	if interval <= 0 {
		interval = familyReminderScanInterval
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-ticker.C:
			l.runOnce(ctx, now)
		}
	}
}

// waitForNotifyConfigured gives the Mac App parent a brief window after core_ready
// to deliver Keychain notification secrets over stdin IPC before the initial scan
// consumes deduplication keys.
func (l *reminderLoop) waitForNotifyConfigured(ctx context.Context) {
	if l.hub == nil || l.hub.Configured() || l.startupGrace <= 0 {
		return
	}
	poll := l.startupPoll
	if poll <= 0 {
		poll = reminderStartupPoll
	}
	deadline := time.NewTimer(l.startupGrace)
	defer deadline.Stop()
	ticker := time.NewTicker(poll)
	defer ticker.Stop()
	for {
		if l.hub.Configured() {
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-deadline.C:
			return
		case <-ticker.C:
		}
	}
}

func (l *reminderLoop) runOnce(ctx context.Context, now time.Time) int {
	if ctx.Err() != nil || l.scanner == nil || l.hub == nil || !l.hub.Configured() {
		return 0
	}
	due, err := l.scanner.ScanDueReminders(now)
	if err != nil {
		if ctx.Err() == nil {
			slog.Warn("family reminder scan failed", "error", err)
		}
		return 0
	}
	sent := 0
	for _, item := range due {
		if ctx.Err() != nil {
			break
		}
		title := apps.SanitizeReminderText(item.SummaryTitle, maxReminderTitleRunes)
		body := apps.SanitizeReminderText(item.SummaryBody, maxReminderBodyRunes)
		if title == "" || body == "" {
			continue
		}
		severity := "info"
		if item.DaysUntil <= 1 {
			severity = "warning"
		}
		l.hub.Notify(notify.Event{
			Code:     "family_reminder_due",
			Title:    title,
			Body:     body,
			Severity: severity,
		})
		sent++
	}
	return sent
}
