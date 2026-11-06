//go:build darwin && arm64

package main

import (
	"context"
	"log/slog"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/server"
)

// The task runs inside the existing Core process, not a separate service.
// Each root has a bounded cleanup and a root-scoped task status.
func startUploadSweeper(ctx context.Context, registry *roots.Registry, rootServer *server.RootServer, accounts *auth.Store) {
	if registry == nil || rootServer == nil || accounts == nil {
		return
	}
	go func() {
		startup := time.NewTimer(2 * time.Minute)
		defer startup.Stop()
		select {
		case <-ctx.Done():
			return
		case <-startup.C:
		}
		runRegisteredUploadSweep(ctx, registry, rootServer, accounts, time.Now())
		ticker := time.NewTicker(time.Hour)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case now := <-ticker.C:
				runRegisteredUploadSweep(ctx, registry, rootServer, accounts, now)
			}
		}
	}()
}

func runRegisteredUploadSweep(ctx context.Context, registry *roots.Registry, rootServer *server.RootServer, accounts *auth.Store, now time.Time) {
	days, err := accounts.UploadRetentionDays()
	if err != nil {
		slog.Warn("upload cleanup settings unavailable; nothing was removed", "error", err)
		return
	}
	if days == 0 {
		return
	}
	cutoff := now.Add(-time.Duration(days) * 24 * time.Hour)
	for _, root := range registry.List() {
		if ctx.Err() != nil {
			return
		}
		if _, err := rootServer.SweepRootUploads(ctx, root.ID, root.Generation, cutoff); err != nil {
			// The root task journal retains reviewable failures when available;
			// offline roots remain untouched until their next checked round.
			slog.Info("upload cleanup deferred or needs review", "rootID", root.ID, "error", err)
		}
	}
}
