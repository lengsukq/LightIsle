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
	purged, scanned, err := fileStore.SweepTrashExpired(cutoff, trashSweepRoundLimit)
	if journal != nil && started {
		_ = journal.Progress("trash", int64(len(purged)), 0)
		_ = journal.Finish("trash", err)
	}
	switch {
	case err == nil:
		if journal != nil {
			_ = journal.SyncAlert("trash_cleanup_failed", false)
		}
		if len(purged) > 0 {
			slog.Info("trash sweep completed", "purged", len(purged), "scanned", scanned)
		}
	case errors.Is(err, files.ErrOffline):
		// An unplugged share is storage_offline's business; retry next round.
	default:
		slog.Warn("trash sweep failed", "error", err)
		if journal != nil {
			_ = journal.SyncAlert("trash_cleanup_failed", true)
		}
	}
}
