package backup

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/files"
)

func inventoryTestDestination(t *testing.T) string {
	t.Helper()
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	dir, err := os.MkdirTemp(home, "lightisle-inventory-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return dir
}

func inventoryTestService(t *testing.T) *Service {
	t.Helper()
	manager, err := files.NewManager(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	service := New(manager)
	t.Cleanup(func() {
		service.Close()
		_ = manager.Close()
	})
	return service
}

func writeInventoryManifest(t *testing.T, snapshot string, manifest Manifest) {
	t.Helper()
	if err := os.MkdirAll(snapshot, 0700); err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(snapshot, "manifest.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
}

func TestListSnapshotsReportsManifestSizeWithoutClaimingVerification(t *testing.T) {
	service := inventoryTestService(t)
	destination := inventoryTestDestination(t)
	name := "LightIsle-Backup-20261022-120000-abc"
	snapshot := filepath.Join(destination, name)
	if err := os.MkdirAll(filepath.Join(snapshot, "data"), 0700); err != nil {
		t.Fatal(err)
	}
	original := []byte("original")
	sum := sha256.Sum256(original)
	manifest := Manifest{
		Format: format, Created: 1792668000, Source: "SharedFiles",
		Dirs: []string{}, Files: []File{{
			Path: "sample.bin", Size: int64(len(original)), SHA256: hex.EncodeToString(sum[:]),
		}},
	}
	writeInventoryManifest(t, snapshot, manifest)
	// Deliberately use same-size, different content: inventory must not imply
	// a checksum pass merely because manifest metadata parses cleanly.
	if err := os.WriteFile(filepath.Join(snapshot, "data", "sample.bin"), []byte("tampered"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(destination, "nested", name), 0700); err != nil {
		t.Fatal(err)
	}

	inventory, err := service.ListSnapshots(context.Background(), destination)
	if err != nil {
		t.Fatal(err)
	}
	if inventory.Truncated || inventory.ScannedEntries < 2 || len(inventory.Snapshots) != 1 {
		t.Fatalf("unexpected inventory: %+v", inventory)
	}
	record := inventory.Snapshots[0]
	if record.Name != name || record.Path != snapshot || record.Version != format ||
		record.CreatedAt != manifest.Created || record.SizeBytes != int64(len(original)) ||
		record.Integrity != "not_verified" || record.IntegrityDetail != "checksums_not_checked" {
		t.Fatalf("unexpected snapshot record: %+v", record)
	}
	if _, err := VerifySnapshot(context.Background(), snapshot); err == nil {
		t.Fatal("fixture content should fail full checksum verification")
	}
}

func TestListSnapshotsMarksBrokenManifestsAndRejectsSymlinks(t *testing.T) {
	service := inventoryTestService(t)
	destination := inventoryTestDestination(t)
	broken := filepath.Join(destination, "LightIsle-Backup-20261022-120000-broken")
	if err := os.Mkdir(broken, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(broken, "manifest.json"), []byte("{"), 0600); err != nil {
		t.Fatal(err)
	}

	outside := inventoryTestDestination(t)
	external := filepath.Join(outside, "manifest.json")
	manifest := Manifest{Format: format, Created: 1792668000, Source: "SharedFiles", Dirs: []string{}, Files: []File{}}
	data, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(external, data, 0600); err != nil {
		t.Fatal(err)
	}
	linkedManifest := filepath.Join(destination, "LightIsle-Backup-20261022-120001-manifest-link")
	if err := os.Mkdir(linkedManifest, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(external, filepath.Join(linkedManifest, "manifest.json")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(destination, "LightIsle-Backup-20261022-120002-folder-link")); err != nil {
		t.Fatal(err)
	}

	inventory, err := service.ListSnapshots(context.Background(), destination)
	if err != nil {
		t.Fatal(err)
	}
	byName := make(map[string]SnapshotRecord, len(inventory.Snapshots))
	for _, record := range inventory.Snapshots {
		byName[record.Name] = record
	}
	if len(byName) != 3 {
		t.Fatalf("unexpected inventory: %+v", inventory)
	}
	if got := byName["LightIsle-Backup-20261022-120000-broken"]; got.Integrity != "invalid" || got.IntegrityDetail != "manifest_invalid" {
		t.Fatalf("malformed manifest was not identified: %+v", got)
	}
	if got := byName["LightIsle-Backup-20261022-120001-manifest-link"]; got.Integrity != "invalid" || got.IntegrityDetail != "manifest_not_regular" {
		t.Fatalf("symlinked manifest was not rejected: %+v", got)
	}
	if got := byName["LightIsle-Backup-20261022-120002-folder-link"]; got.Integrity != "invalid" || got.IntegrityDetail != "snapshot_symlink" {
		t.Fatalf("symlinked snapshot was not rejected: %+v", got)
	}
}

func TestListSnapshotsEnforcesDestinationAndManifestBounds(t *testing.T) {
	service := inventoryTestService(t)
	destination := inventoryTestDestination(t)
	large := filepath.Join(destination, "LightIsle-Backup-20261022-120000-large")
	if err := os.Mkdir(large, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(large, "manifest.json"), make([]byte, maxInventoryManifestBytes+1), 0600); err != nil {
		t.Fatal(err)
	}
	inventory, err := service.ListSnapshots(context.Background(), destination)
	if err != nil {
		t.Fatal(err)
	}
	if len(inventory.Snapshots) != 1 || inventory.Snapshots[0].Integrity != "not_verified_limit" ||
		inventory.Snapshots[0].IntegrityDetail != "manifest_size_limit" {
		t.Fatalf("oversized manifest was not bounded: %+v", inventory)
	}

	shared := inventoryTestDestination(t)
	sharedData := t.TempDir()
	manager, err := files.NewManager(sharedData)
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()
	if err := manager.SetRootWithLegacyTransition(shared, func() error { return nil }, func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	serviceWithSharedRoot := New(manager)
	defer serviceWithSharedRoot.Close()
	inside := filepath.Join(shared, "Backups")
	if err := os.Mkdir(inside, 0700); err != nil {
		t.Fatal(err)
	}
	if _, err := serviceWithSharedRoot.ListSnapshots(context.Background(), inside); !errors.Is(err, ErrInvalid) {
		t.Fatalf("inventory inside shared root was accepted: %v", err)
	}
	alias := filepath.Join(filepath.Dir(destination), filepath.Base(destination)+"-alias")
	if err := os.Symlink(destination, alias); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Remove(alias) })
	if _, err := service.ListSnapshots(context.Background(), alias); !errors.Is(err, ErrInvalid) {
		t.Fatalf("symlink destination was accepted: %v", err)
	}
}

func TestListSnapshotsBoundsVeryWideDestination(t *testing.T) {
	service := inventoryTestService(t)
	destination := inventoryTestDestination(t)
	for i := 0; i <= maxInventoryEntries; i++ {
		name := filepath.Join(destination, fmt.Sprintf("ordinary-%05d", i))
		if err := os.WriteFile(name, nil, 0600); err != nil {
			t.Fatal(err)
		}
	}
	inventory, err := service.ListSnapshots(context.Background(), destination)
	if err != nil {
		t.Fatal(err)
	}
	if !inventory.Truncated || inventory.ScannedEntries > maxInventoryEntries {
		t.Fatalf("wide directory was not bounded: scanned=%d truncated=%t", inventory.ScannedEntries, inventory.Truncated)
	}
	if len(inventory.Snapshots) != 0 {
		t.Fatalf("ordinary files were misidentified as snapshots: %+v", inventory.Snapshots)
	}
}
