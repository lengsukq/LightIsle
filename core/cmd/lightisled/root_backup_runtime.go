//go:build darwin && arm64

package main

import (
	"context"

	"github.com/lengsukq/lightisle/core/internal/backup"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/server"
)

// A scheduled job must keep its scoped services and physical root leased
// until all asynchronous backup work has stopped, including cancellation.
func rootBackupProvider(runtime *server.RootServer) backup.RootBackupProvider {
	return func(ctx context.Context, id string, generation uint64) (*backup.RootBackupLease, error) {
		if runtime == nil {
			return nil, backup.ErrRootPlanUnavailable
		}
		lease, err := runtime.AcquireRootServices(ctx, id)
		if err != nil {
			return nil, err
		}
		if lease.Root.ID != id || lease.Root.Generation != generation {
			_ = lease.Close()
			return nil, roots.ErrStale
		}
		if lease.Root.Pending || lease.Root.Compatibility || lease.Services == nil || lease.Services.Backup == nil {
			_ = lease.Close()
			return nil, roots.ErrNotAllowed
		}
		return &backup.RootBackupLease{Root: lease.Root, Service: lease.Services.Backup, Close: lease.Close}, nil
	}
}
