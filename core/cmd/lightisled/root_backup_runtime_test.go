//go:build darwin && arm64

package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/backup"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/server"
	"github.com/lengsukq/lightisle/core/internal/storageidentity"
)

func TestRootPlanFailuresReachNativeRecoveryMessages(t *testing.T) {
	for _, expected := range []error{backup.ErrRootPlanConfigInvalid, backup.ErrRootPlanConfigUnsafe, backup.ErrRootPlanArchiveFailed} {
		if got := rootControlError(fmt.Errorf("private diagnostics: %w", expected)); got != expected.Error() {
			t.Fatalf("plan error lost across IPC: %q, want %q", got, expected)
		}
	}
}

func TestRootBackupProviderPinsGenerationAndReleasesRejectedLease(t *testing.T) {
	base := t.TempDir()
	base, _ = filepath.EvalSymlinks(base)
	private, source := filepath.Join(base, "private"), filepath.Join(base, "source")
	for _, folder := range []string{private, source} {
		if err := os.Mkdir(folder, 0700); err != nil {
			t.Fatal(err)
		}
	}
	registry, err := roots.OpenWithProvider(private, storageidentity.SystemProvider{}, base)
	if err != nil {
		t.Fatal(err)
	}
	record, err := registry.Add(context.Background(), "Source", source)
	if err != nil {
		t.Fatal(err)
	}
	accounts, err := auth.Open(filepath.Join(private, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	factory := func(_ context.Context, root roots.Root, lease *roots.Lease) (*server.RootServices, error) {
		manager, err := files.NewPinnedManager(lease.Root, root.Binding)
		if err != nil {
			return nil, err
		}
		service, err := backup.NewForRoot(manager, private, root, registry)
		if err != nil {
			manager.Close()
			return nil, err
		}
		return &server.RootServices{Files: manager, Backup: service, Close: func() error { service.Close(); return manager.Close() }}, nil
	}
	runtime := server.NewWithRoots("", accounts, nil, nil, nil, nil, registry, factory)
	defer runtime.Close()
	provider := rootBackupProvider(runtime)
	if _, err := provider(context.Background(), record.ID, record.Generation+1); !errors.Is(err, roots.ErrStale) {
		t.Fatalf("stale generation was accepted: %v", err)
	}
	lease, err := provider(context.Background(), record.ID, record.Generation)
	if err != nil {
		t.Fatal(err)
	}
	if lease.Service == nil || lease.Root.ID != record.ID || lease.Root.Generation != record.Generation {
		t.Fatal("provider returned unrelated services")
	}
	if err := registry.Remove(record.ID); !errors.Is(err, roots.ErrBusy) {
		t.Fatalf("scheduled job did not pin root: %v", err)
	}
	if err := lease.Close(); err != nil {
		t.Fatal(err)
	}
	if err := lease.Close(); err != nil {
		t.Fatal(err)
	}
	if err := registry.Remove(record.ID); err != nil {
		t.Fatalf("completed provider lease still pins root: %v", err)
	}
	if _, err := rootBackupProvider(nil)(context.Background(), record.ID, record.Generation); !errors.Is(err, backup.ErrRootPlanUnavailable) {
		t.Fatalf("missing runtime: %v", err)
	}
}
