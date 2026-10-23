//go:build darwin

package backup

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/storageidentity"
)

type backupTestIdentityProvider struct{}

func (backupTestIdentityProvider) Capture(_ context.Context, path string) (storageidentity.Binding, error) {
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return storageidentity.Binding{}, err
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return storageidentity.Binding{}, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return storageidentity.Binding{}, errors.New("stat identity unavailable")
	}
	return storageidentity.Binding{
		Path: resolved, VolumeUUID: "12345678-1234-1234-1234-123456789abc",
		DirectoryID: uint64(stat.Ino), BirthSec: stat.Birthtimespec.Sec,
		BirthNsec: stat.Birthtimespec.Nsec, Generation: uint64(stat.Gen),
	}, nil
}

func (p backupTestIdentityProvider) Verify(ctx context.Context, expected storageidentity.Binding) error {
	actual, err := p.Capture(ctx, expected.Path)
	if err != nil {
		return err
	}
	if !storageidentity.Equal(actual, expected) {
		return storageidentity.ErrMismatch
	}
	return nil
}

func TestRootScopedBackupBindsLogicalAndPhysicalIdentityAndRejectsCrossRootRestore(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	base, err := os.MkdirTemp(home, ".lightisle-root-backup-test-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(base)
	private := filepath.Join(base, "private")
	rootAPath, rootBPath := filepath.Join(base, "photos"), filepath.Join(base, "cinema")
	backupPath := filepath.Join(base, "backups")
	for _, dir := range []string{private, rootAPath, rootBPath, backupPath} {
		if err := os.Mkdir(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	registry, err := roots.OpenWithProvider(private, backupTestIdentityProvider{}, home)
	if err != nil {
		t.Fatal(err)
	}
	rootA, err := registry.Add(context.Background(), "Photos", rootAPath)
	if err != nil {
		t.Fatal(err)
	}
	rootB, err := registry.Add(context.Background(), "Cinema", rootBPath)
	if err != nil {
		t.Fatal(err)
	}
	managerA := pinnedTestManager(t, registry, rootA)
	defer managerA.Close()
	if err := os.WriteFile(filepath.Join(rootAPath, "photo.jpg"), []byte("photo bytes"), 0600); err != nil {
		t.Fatal(err)
	}
	serviceA, err := NewForRoot(managerA, private, rootA, registry)
	if err != nil {
		t.Fatal(err)
	}
	defer serviceA.Close()
	if err := serviceA.StartBackup(backupPath); err != nil {
		t.Fatal(err)
	}
	status := waitForRootBackup(t, serviceA)
	if status.LastError != "" || status.LastSnapshot == "" {
		t.Fatalf("root backup failed: %+v", status)
	}
	manifestData, err := os.ReadFile(filepath.Join(status.LastSnapshot, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	var manifest Manifest
	if err := json.Unmarshal(manifestData, &manifest); err != nil {
		t.Fatal(err)
	}
	wantPhysical, err := sourceRootIDForBinding(rootA.Binding)
	if err != nil || manifest.LogicalRootID != rootA.ID || manifest.RootGeneration != rootA.Generation ||
		manifest.SourceRootID != wantPhysical || !validSourceRootID(manifest.SourceRootID) {
		t.Fatalf("manifest lost logical/physical binding: %+v; physical=%q err=%v", manifest, wantPhysical, err)
	}
	if manifest.PlanID != "" {
		t.Fatalf("root-scoped manual backup unexpectedly became scheduled: %+v", manifest)
	}

	managerB := pinnedTestManager(t, registry, rootB)
	defer managerB.Close()
	serviceB, err := NewForRoot(managerB, private, rootB, registry)
	if err != nil {
		t.Fatal(err)
	}
	defer serviceB.Close()
	if err := serviceB.StartRestore(status.LastSnapshot); !errors.Is(err, ErrRootSnapshotMismatch) {
		t.Fatalf("cross-root snapshot accepted: %v", err)
	}
}

func TestRootScopedBackupRejectsRegisteredAndPrivateDestinationOverlap(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	base, err := os.MkdirTemp(home, ".lightisle-root-destination-test-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(base)
	private := filepath.Join(base, "private")
	rootPath := filepath.Join(base, "share")
	otherRootPath := filepath.Join(base, "other")
	for _, dir := range []string{private, rootPath, otherRootPath} {
		if err := os.Mkdir(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Mkdir(filepath.Join(otherRootPath, "nested-backups"), 0700); err != nil {
		t.Fatal(err)
	}
	registry, err := roots.OpenWithProvider(private, backupTestIdentityProvider{}, home)
	if err != nil {
		t.Fatal(err)
	}
	root, err := registry.Add(context.Background(), "Share", rootPath)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = registry.Add(context.Background(), "Other", otherRootPath); err != nil {
		t.Fatal(err)
	}
	manager := pinnedTestManager(t, registry, root)
	defer manager.Close()
	service, err := NewForRoot(manager, private, root, registry)
	if err != nil {
		t.Fatal(err)
	}
	defer service.Close()
	if err := service.StartBackup(filepath.Join(otherRootPath, "nested-backups")); !errors.Is(err, ErrRootDestinationOverlap) {
		t.Fatalf("backup into another registered root accepted: %v", err)
	}
	if err := service.StartBackup(private); !errors.Is(err, ErrPrivateDestinationOverlap) {
		t.Fatalf("backup into private data accepted: %v", err)
	}
	if err := service.StartRestore(filepath.Join(otherRootPath, "nested-backups")); !errors.Is(err, ErrRootDestinationOverlap) {
		t.Fatalf("restore snapshot inside another root accepted: %v", err)
	}
}

func pinnedTestManager(t *testing.T, registry *roots.Registry, record roots.Root) *files.Manager {
	t.Helper()
	lease, err := registry.Acquire(context.Background(), record.ID)
	if err != nil {
		t.Fatal(err)
	}
	manager, err := files.NewPinnedManager(lease.Root, lease.Binding)
	closeErr := lease.Close()
	if err != nil {
		t.Fatal(err)
	}
	if closeErr != nil {
		manager.Close()
		t.Fatal(closeErr)
	}
	return manager
}

func waitForRootBackup(t *testing.T, service *Service) Status {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		status := service.Status()
		if !status.Running {
			return status
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("root backup timed out: %+v", service.Status())
	return Status{}
}

func TestRootScopedManifestRequiresBothIdentityLayers(t *testing.T) {
	manifest := Manifest{
		Format: format, Created: 1, Source: "photos", LogicalRootID: strings.Repeat("a", 32), RootGeneration: 4,
		SourceRootID: "fsr1:12345678-1234-1234-1234-123456789ABC:0000000000000001:1700000000:0:1",
		Dirs:         []string{}, Files: []File{},
	}
	if err := validateInventoryManifest(manifest); err != nil {
		t.Fatalf("valid logical and physical binding rejected: %v", err)
	}
	manifest.LogicalRootID = ""
	if err := validateInventoryManifest(manifest); !errors.Is(err, ErrInvalid) {
		t.Fatalf("manifest missing logical identity accepted: %v", err)
	}
}

func TestLegacyServiceDestinationProtectionDoesNotChangeManifestVersion(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	base, err := os.MkdirTemp(home, ".lightisle-v1-destination-test-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(base)
	private := filepath.Join(base, "private")
	rootPath, otherRootPath := filepath.Join(base, "share"), filepath.Join(base, "other")
	backupPath := filepath.Join(base, "backups")
	for _, dir := range []string{private, rootPath, otherRootPath, backupPath} {
		if err := os.Mkdir(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Mkdir(filepath.Join(otherRootPath, "nested"), 0700); err != nil {
		t.Fatal(err)
	}
	registry, err := roots.OpenWithProvider(private, backupTestIdentityProvider{}, home)
	if err != nil {
		t.Fatal(err)
	}
	root, err := registry.Add(context.Background(), "Share", rootPath)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := registry.Add(context.Background(), "Other", otherRootPath); err != nil {
		t.Fatal(err)
	}
	manager := pinnedTestManager(t, registry, root)
	defer manager.Close()
	if err := os.WriteFile(filepath.Join(rootPath, "legacy.txt"), []byte("v1 bytes"), 0600); err != nil {
		t.Fatal(err)
	}
	service := New(manager, private)
	defer service.Close()
	if err := service.ProtectDestinations(registry); err != nil {
		t.Fatal(err)
	}
	if service.rootRegistry != nil {
		t.Fatal("destination protection accidentally enabled v2 root manifest mode")
	}
	if _, err := service.CheckDestination(filepath.Join(otherRootPath, "nested")); !errors.Is(err, ErrRootDestinationOverlap) {
		t.Fatalf("v1 policy allowed a destination inside another root: %v", err)
	}
	blockedDestination := filepath.Join(otherRootPath, "nested")
	if err := service.StartScheduledBackup(blockedDestination, strings.Repeat("a", 32), 1); !errors.Is(err, ErrRootDestinationOverlap) {
		t.Fatalf("v1 scheduled backup accepted another root as destination: %v", err)
	}
	scheduler := &Scheduler{service: service}
	if err := scheduler.Configure(blockedDestination, 24); !errors.Is(err, ErrRootDestinationOverlap) {
		t.Fatalf("v1 schedule configuration accepted another root as destination: %v", err)
	}
	if _, err := service.ListSnapshots(context.Background(), blockedDestination); !errors.Is(err, ErrRootDestinationOverlap) {
		t.Fatalf("v1 inventory accepted another root as destination: %v", err)
	}
	if _, err := service.CheckDestination(private); !errors.Is(err, ErrPrivateDestinationOverlap) {
		t.Fatalf("v1 policy allowed private data as destination: %v", err)
	}
	if err := service.StartBackup(backupPath); err != nil {
		t.Fatal(err)
	}
	status := waitForRootBackup(t, service)
	if status.LastError != "" {
		t.Fatalf("protected v1 backup failed: %+v", status)
	}
	raw, err := os.ReadFile(filepath.Join(status.LastSnapshot, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	var manifest Manifest
	if err := json.Unmarshal(raw, &manifest); err != nil {
		t.Fatal(err)
	}
	if manifest.LogicalRootID != "" || manifest.RootGeneration != 0 || manifest.SourceRootID != "" {
		t.Fatalf("destination-only protection changed v1 manifest semantics: %+v", manifest)
	}
}
