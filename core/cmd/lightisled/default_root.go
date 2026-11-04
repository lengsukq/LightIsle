//go:build darwin && arm64

package main

import (
	"context"
	"errors"
	"path/filepath"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/server"
)

// registeredDefaultState is read-only: an offline/replaced disk is reported
// offline, never reopened by matching a pathname.
func registeredDefaultState(registry *roots.Registry) (string, bool) {
	if registry == nil {
		return "", false
	}
	selected, ok := registry.Default()
	if !ok {
		return "", false
	}
	lease, err := registry.Acquire(context.Background(), selected.ID)
	if err != nil {
		return selected.Path, false
	}
	defer lease.Close()
	return selected.Path, lease.Valid(context.Background())
}

// withDefaultManager leases the actual RootRegistry runtime selected at the
// start of an owner-approved native operation. Another disk cannot inherit
// the operation, even if the default changes before it finishes.
func withDefaultManager(
	ctx context.Context, registry *roots.Registry, rootServer *server.RootServer,
	use func(*files.Manager) error,
) error {
	if registry == nil || rootServer == nil || use == nil {
		return roots.ErrMissing
	}
	selected, ok := registry.Default()
	if !ok {
		return roots.ErrMissing
	}
	services, err := rootServer.AcquireRootServices(ctx, selected.ID)
	if err != nil {
		return err
	}
	defer services.Close()
	if services.Root.Generation != selected.Generation || !services.Lease.Valid(ctx) {
		return roots.ErrStale
	}
	manager, ok := services.Services.Files.(*files.Manager)
	if !ok {
		return errors.New("root_manager_unavailable")
	}
	return use(manager)
}

// registerCurrentShareAsDefault preserves existing bytes in place while
// introducing a stable rootID. It does not migrate ACLs or public capabilities.
// A disconnected legacy directory is never treated as a new disk.
func registerCurrentShareAsDefault(ctx context.Context, registry *roots.Registry, legacy *files.Manager) error {
	if _, ok := registry.Default(); ok {
		return nil
	}
	path, online := legacy.State()
	if !online {
		return nil
	}
	for _, root := range registry.List() {
		if root.Path == path {
			return registry.SetDefault(ctx, root.ID, root.Generation)
		}
	}
	// A prior owner removal wrote an empty registry; do not resurrect the
	// removed disk merely because the old compatibility manager remembers it.
	if registry.HasConfiguration() {
		return nil
	}
	_, err := registry.Add(ctx, filepath.Base(path), path)
	return err
}
