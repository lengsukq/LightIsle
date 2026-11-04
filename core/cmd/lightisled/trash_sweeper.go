package main

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/server"
	"github.com/lengsukq/lightisle/core/internal/tasks"
)

// startRegisteredTrashSweeper sweeps the independently verified trash on
// every registered root, not the old single selected directory. An unplugged
// disk is skipped and its trash kept intact until it is reconnected.
func startRegisteredTrashSweeper(
	ctx context.Context, registry *roots.Registry, rootServer *server.RootServer,
	retention *tasks.RetentionStore, journal *tasks.Journal, onActivated func(string),
) {
	if registry == nil || rootServer == nil || retention == nil {
		return
	}
	go func() {
		start := time.NewTimer(trashSweepStartupDelay)
		defer start.Stop()
		select {
		case <-ctx.Done():
			return
		case <-start.C:
		}
		runRegisteredTrashSweep(ctx, registry, rootServer, retention, journal, onActivated)
		ticker := time.NewTicker(trashSweepInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				runRegisteredTrashSweep(ctx, registry, rootServer, retention, journal, onActivated)
			}
		}
	}()
}

func runRegisteredTrashSweep(
	ctx context.Context, registry *roots.Registry, rootServer *server.RootServer,
	retention *tasks.RetentionStore, journal *tasks.Journal, onActivated func(string),
) {
	cutoff := retention.Cutoff(time.Now())
	if cutoff.IsZero() || ctx.Err() != nil {
		return
	}
	started := false
	if journal != nil {
		if err := journal.Start("trash", "registered-sweep"); err == nil {
			started = true
		} else if errors.Is(err, tasks.ErrRunning) {
			return
		}
	}
	var sweepErr error
	totalPurged := 0
	for _, entry := range registry.List() {
		if ctx.Err() != nil {
			break
		}
		services, err := rootServer.AcquireRootServices(ctx, entry.ID)
		if errors.Is(err, roots.ErrOffline) || errors.Is(err, roots.ErrMissing) {
			continue
		}
		if err != nil {
			sweepErr = errors.Join(sweepErr, err)
			continue
		}
		manager, ok := services.Services.Files.(*files.Manager)
		if !ok || !services.Lease.Valid(ctx) {
			sweepErr = errors.Join(sweepErr, files.ErrOffline)
			_ = services.Close()
			continue
		}
		purged, failed, _, purgeErr := manager.SweepTrashExpired(cutoff, trashSweepRoundLimit)
		totalPurged += len(purged)
		if purgeErr != nil || len(failed) != 0 {
			slog.Warn("registered root trash cleanup incomplete", "rootID", entry.ID,
				"failed", len(failed), "error", purgeErr)
			sweepErr = errors.Join(sweepErr, purgeErr, errors.New("root_trash_cleanup_incomplete"))
		}
		_ = services.Close()
	}
	if journal != nil && started {
		_ = journal.Progress("trash", int64(totalPurged), 0)
		_ = journal.Finish("trash", sweepErr)
	}
	if ctx.Err() == nil {
		syncTrashSweepAlert(journal, sweepErr != nil, onActivated)
	}
}

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
func startTrashSweeper(ctx context.Context, fileStore *files.Manager, retention *tasks.RetentionStore, journal *tasks.Journal, onActivated func(string)) {
	if fileStore == nil || retention == nil {
		return
	}
	go func() {
		select {
		case <-ctx.Done():
			return
		case <-time.After(trashSweepStartupDelay):
		}
		runTrashSweep(fileStore, retention, journal, onActivated)
		ticker := time.NewTicker(trashSweepInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				runTrashSweep(fileStore, retention, journal, onActivated)
			}
		}
	}()
}

func runTrashSweep(fileStore *files.Manager, retention *tasks.RetentionStore, journal *tasks.Journal, onActivated func(string)) {
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
		syncTrashSweepAlert(journal, true, onActivated)
	case err == nil:
		syncTrashSweepAlert(journal, false, onActivated)
		if len(purged) > 0 {
			slog.Info("trash sweep completed", "purged", len(purged), "scanned", scanned)
		}
	case errors.Is(err, files.ErrOffline):
		// An unplugged share is storage_offline's business; retry next round.
	default:
		slog.Warn("trash sweep failed", "error", err)
		syncTrashSweepAlert(journal, true, onActivated)
	}
}

// Notification persistence is best-effort, but failures must remain visible
// in local logs. Never repeat a destructive sweep merely to fix an alert.
func syncTrashSweepAlert(journal *tasks.Journal, active bool, onActivated func(string)) {
	if journal == nil {
		return
	}
	becameActive, err := journal.SyncAlert("trash_cleanup_failed", active)
	if err != nil {
		slog.Warn("trash sweep alert was not persisted", "active", active, "error", err)
		return
	}
	if becameActive && onActivated != nil {
		onActivated("trash_cleanup_failed")
	}
}
