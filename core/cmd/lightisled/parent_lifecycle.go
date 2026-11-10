//go:build darwin && arm64

package main

import (
	"context"
	"log/slog"
	"os"
	"syscall"
	"time"
)

// EOF is the usual shutdown signal. Parent identity also catches orphaning
// when an inherited write end prevents EOF or the IPC reader is backlogged.
func watchCoreParent(ctx context.Context, parent int, cancel context.CancelFunc) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			// EOF can win the race against the parent check. Bound shutdown
			// in either case so an orphan cannot retain the listener or lock.
			time.Sleep(8 * time.Second)
			slog.Error("Core did not stop within its shutdown deadline")
			if pid := os.Getpid(); syscall.Getpgrp() == pid {
				_ = syscall.Kill(-pid, syscall.SIGKILL)
			}
			os.Exit(75)
		case <-ticker.C:
			if parent > 1 && os.Getppid() == parent {
				continue
			}
			slog.Warn("Core parent exited; stopping local services")
			cancel()

		}
	}
}
