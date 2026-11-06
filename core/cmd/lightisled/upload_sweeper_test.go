//go:build darwin && arm64

package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/server"
	"github.com/lengsukq/lightisle/core/internal/storageidentity"
	"github.com/lengsukq/lightisle/core/internal/tasks"
)

type uploadSweepTestProvider struct{}

func (uploadSweepTestProvider) Capture(_ context.Context, name string) (storageidentity.Binding, error) {
	name, err := filepath.EvalSymlinks(name)
	if err != nil {
		return storageidentity.Binding{}, err
	}
	info, err := os.Stat(name)
	if err != nil {
		return storageidentity.Binding{}, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return storageidentity.Binding{}, errors.New("identity unavailable")
	}
	return storageidentity.Binding{Path: filepath.Clean(name), VolumeUUID: "12345678-1234-1234-1234-123456789abc", DirectoryID: stat.Ino,
		BirthSec: stat.Birthtimespec.Sec, BirthNsec: stat.Birthtimespec.Nsec, Generation: uint64(stat.Gen)}, nil
}
func (p uploadSweepTestProvider) Verify(ctx context.Context, expected storageidentity.Binding) error {
	actual, err := p.Capture(ctx, expected.Path)
	if err != nil {
		return err
	}
	if !storageidentity.Equal(actual, expected) {
		return errors.New("identity changed")
	}
	return nil
}

func TestScheduledUploadCleanupHonorsDisabledAndDefaultPolicy(t *testing.T) {
	base := t.TempDir()
	volume := filepath.Join(base, "volume")
	rootPath := filepath.Join(volume, "root")
	dataDir := filepath.Join(base, "private")
	for _, path := range []string{rootPath, dataDir} {
		if err := os.MkdirAll(path, 0700); err != nil {
			t.Fatal(err)
		}
	}
	registry, err := roots.OpenWithProvider(dataDir, uploadSweepTestProvider{}, volume)
	if err != nil {
		t.Fatal(err)
	}
	root, err := registry.Add(context.Background(), "root", rootPath)
	if err != nil {
		t.Fatal(err)
	}
	accounts, err := auth.Open(filepath.Join(dataDir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("owner", "upload-cleanup-owner-password"); err != nil {
		t.Fatal(err)
	}
	admin, err := accounts.Login("owner", "upload-cleanup-owner-password")
	if err != nil {
		t.Fatal(err)
	}
	factory := func(_ context.Context, record roots.Root, lease *roots.Lease) (*server.RootServices, error) {
		manager, err := files.NewPinnedManager(lease.Root)
		if err != nil {
			return nil, err
		}
		journal, err := tasks.OpenRootScoped(dataDir, record.ID)
		if err != nil {
			manager.Close()
			return nil, err
		}
		return &server.RootServices{Files: manager, Journal: journal, Close: func() error { return errors.Join(journal.Close(), manager.Close()) }}, nil
	}
	rootServer := server.NewWithRoots("", accounts, nil, nil, nil, nil, registry, factory)
	defer rootServer.Close()
	services, err := rootServer.AcquireRootServices(context.Background(), root.ID)
	if err != nil {
		t.Fatal(err)
	}
	item, err := services.Services.Files.BeginUpload("old.txt", 1, 1)
	if err != nil {
		services.Close()
		t.Fatal(err)
	}
	services.Close()
	basePath := filepath.Join(rootPath, ".lightisle-parts", item.ID)
	data, err := os.ReadFile(basePath + ".json")
	if err != nil {
		t.Fatal(err)
	}
	var journal map[string]any
	if err := json.Unmarshal(data, &journal); err != nil {
		t.Fatal(err)
	}
	now := time.Now().Truncate(time.Second)
	old := now.Add(-31 * 24 * time.Hour)
	journal["activity"] = old.Unix()
	data, err = json.Marshal(journal)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(basePath+".json", data, 0600); err != nil {
		t.Fatal(err)
	}
	for _, suffix := range []string{".json", ".part"} {
		if err := os.Chtimes(basePath+suffix, old, old); err != nil {
			t.Fatal(err)
		}
	}
	db, err := sql.Open("sqlite3", filepath.Join(dataDir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`DELETE FROM upload_cleanup_settings WHERE id=1`); err != nil {
		db.Close()
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	runRegisteredUploadSweep(context.Background(), registry, rootServer, accounts, now)
	if _, err := os.Stat(basePath + ".part"); err != nil {
		t.Fatalf("missing rules did not fail closed: %v", err)
	}
	if err := accounts.SetUploadRetentionDays(admin, 0); err != nil {
		t.Fatal(err)
	}
	runRegisteredUploadSweep(context.Background(), registry, rootServer, accounts, now)
	if _, err := os.Stat(basePath + ".part"); err != nil {
		t.Fatalf("disabled cleanup removed staging: %v", err)
	}
	if err := accounts.SetUploadRetentionDays(admin, 30); err != nil {
		t.Fatal(err)
	}
	runRegisteredUploadSweep(context.Background(), registry, rootServer, accounts, now)
	if _, err := os.Stat(basePath + ".part"); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("stale staging remains: %v", err)
	}
}
