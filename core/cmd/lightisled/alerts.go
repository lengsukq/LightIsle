//go:build darwin && arm64

package main

import (
	"context"
	"fmt"
	"log/slog"
	"syscall"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/tasks"
)

func storageAlertObservations(path string, online bool, statfs func(string, *syscall.Statfs_t) error, threshold tasks.Threshold) map[string]bool {
	desired := map[string]bool{"storage_offline": !online}
	if online {
		var stat syscall.Statfs_t
		if err := statfs(path, &stat); err == nil && stat.Blocks > 0 && stat.Bsize > 0 {
			remaining := uint64(stat.Bavail) * uint64(stat.Bsize)
			total := uint64(stat.Blocks) * uint64(stat.Bsize)
			low := remaining < uint64(threshold.FreeMiB)<<20
			if threshold.Percent > 0 {
				low = low || remaining*100 < total*uint64(threshold.Percent)
			}
			desired["storage_low_space"] = low
		}
	}
	return desired
}

// Missing observations mean unknown, not recovered. An offline volume or a
// failed capacity probe must not clear the last verified low-space warning.
func syncAlertObservations(journal *tasks.Journal, desired map[string]bool) error {
	for code, active := range desired {
		if err := journal.SyncAlert(code, active); err != nil {
			return fmt.Errorf("%s: %w", code, err)
		}
	}
	return nil
}

func monitorAlerts(ctx context.Context, storage *files.Manager, journal *tasks.Journal, thresholds *tasks.ThresholdStore, accounts *auth.Store) {
	ticker := time.NewTicker(60 * time.Second)
	defer ticker.Stop()
	update := func() {
		// Piggyback on the alert loop: expired sessions and share links
		// otherwise accumulate until someone logs out or shares again.
		if accounts != nil {
			if err := accounts.PruneExpired(time.Now()); err != nil {
				slog.Warn("cannot prune expired sessions and shares", "error", err)
			}
		}
		path, online := storage.State()
		states, err := journal.List()
		if err != nil {
			slog.Warn("cannot evaluate task alerts", "error", err)
			return
		}
		desired := storageAlertObservations(path, online, syscall.Statfs, thresholds.Get())
		for _, s := range states {
			fail := !s.Running && s.LastError != ""
			switch s.Kind {
			case "backup":
				desired["backup_failed"] = fail
			case "gallery":
				desired["gallery_scan_failed"] = fail
			case "cinema":
				desired["cinema_scan_failed"] = fail
			case "trash":
				desired["trash_cleanup_failed"] = fail
			}
		}
		if err := syncAlertObservations(journal, desired); err != nil {
			slog.Warn("cannot persist system alert", "error", err)
		}
	}
	update()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			update()
		}
	}
}
