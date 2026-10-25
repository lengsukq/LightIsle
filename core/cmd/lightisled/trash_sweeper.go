package main

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/tasks"
)

// Trash sweep policy: rounds start after a quiet period and repeat hourly.
// Each round purges at most trashSweepRoundLimit items so a huge backlog
// cannot starve interactive I/O.
const (
	trashSweepStartupDelay = 90 * time.Second
	trashSweepInterval     = time.Hour
	trashSweepRoundLimit   = 100
)

// startTrashSweeper launches the opt-in trash auto-cleanup loop. A disabled
// policy makes every round a no-op; the sweeper never touches trash when the
// share is offline (that state belongs to storage_offline alerting).
func startTrashSweeper(ctx context.Context, fileStore *files.Manager, retention *tasks.RetentionStore, journal *tasks.Journal) {
	if fileStore == nil || retention == nil {
		return
	}
	go func() {
		select {
		case <-ctx.Done():
			return
		case <-time.After(trashSweepStartupDelay):
		}
		runTrashSweep(fileStore, retention, journal)
		ticker := time.NewTicker(trashSweepInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				runTrashSweep(fileStore, retention, journal)
			}
		}
	}()
}

func runTrashSweep(fileStore *files.Manager, retention *tasks.RetentionStore, journal *tasks.Journal) {
	cutoff := retention.Cutoff(time.Now())
	if cutoff.IsZero() {
		return
	}
	started := false
	if journal != nil {
		if err := journal.Start("trash", "sweep"); err != nil {
			if errors.Is(err, tasks.ErrRunning) {
				return
			}
			slog.Warn("trash sweep journal start failed", "error", err)
		} else {
			started = true
		}
	}
	purged, failedPurges, scanned, err := fileStore.SweepTrashExpired(cutoff, trashSweepRoundLimit)
	if journal != nil && started {
		if progressErr := journal.Progress("trash", int64(len(purged)), 0); progressErr != nil {
			slog.Warn("trash sweep progress was not persisted", "error", progressErr)
		}
		completionErr := err
		if completionErr == nil && len(failedPurges) > 0 {
			completionErr = errors.New("trash_cleanup_partial_failure")
		}
		if finishErr := journal.Finish("trash", completionErr); finishErr != nil {
			slog.Warn("trash sweep completion was not persisted", "error", finishErr)
		}
	}
	switch {
	case err == nil && len(failedPurges) > 0:
		// Items that keep failing to purge must not silently keep the alert
		// cleared; they stay in the trash until the underlying error is
		// resolved, so the operator keeps hearing about it.
		slog.Warn("trash sweep had stuck items", "failed", len(failedPurges), "ids", failedPurges)
		syncTrashSweepAlert(journal, true)
	case err == nil:
		syncTrashSweepAlert(journal, false)
		if len(purged) > 0 {
			slog.Info("trash sweep completed", "purged", len(purged), "scanned", scanned)
		}
	case errors.Is(err, files.ErrOffline):
		// An unplugged share is storage_offline's business; retry next round.
	default:
		slog.Warn("trash sweep failed", "error", err)
		syncTrashSweepAlert(journal, true)
	}
}

// Notification persistence is best-effort, but failures must remain visible
// in local logs. Never repeat a destructive sweep merely to fix an alert.
func syncTrashSweepAlert(journal *tasks.Journal, active bool) {
	if journal == nil {
		return
	}
	if err := journal.SyncAlert("trash_cleanup_failed", active); err != nil {
		slog.Warn("trash sweep alert was not persisted", "active", active, "error", err)
	}
}
