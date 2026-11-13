package apps

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/storageidentity"
)

type fakeStorageIdentityProvider struct {
	mu       sync.Mutex
	uuids    map[string]string
	offline  map[string]bool
	changed  map[string]bool
	defaultU string
}

func (f *fakeStorageIdentityProvider) Capture(_ context.Context, path string) (storageidentity.Binding, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.offline[path] {
		return storageidentity.Binding{}, os.ErrNotExist
	}
	uuid := f.uuids[path]
	if uuid == "" {
		uuid = f.defaultU
		if uuid == "" {
			uuid = "uuid-" + filepath.Base(path)
		}
	}
	return storageidentity.Binding{
		Path:       filepath.Clean(path),
		VolumeUUID: uuid,
	}, nil
}

func (f *fakeStorageIdentityProvider) Verify(_ context.Context, b storageidentity.Binding) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.offline[b.Path] {
		return os.ErrNotExist
	}
	if f.changed[b.Path] {
		return storageidentity.ErrMismatch
	}
	if want := f.uuids[b.Path]; want != "" && want != b.VolumeUUID {
		return storageidentity.ErrMismatch
	}
	return nil
}

func TestAppStorageSlotLimitsValidationAndSafeRemoval(t *testing.T) {
	dataDir := t.TempDir()
	extRoot := t.TempDir()
	extVol := filepath.Join(extRoot, "DiskOne")
	extAppDir := filepath.Join(extVol, "LightIsleApps")
	if err := os.MkdirAll(extVol, 0700); err != nil {
		t.Fatal(err)
	}
	extVol2 := filepath.Join(extRoot, "DiskTwo")
	extAppDir2 := filepath.Join(extVol2, "Apps")
	if err := os.MkdirAll(extVol2, 0700); err != nil {
		t.Fatal(err)
	}
	customInternal := filepath.Join(t.TempDir(), "CustomInternalApps")

	provider := &fakeStorageIdentityProvider{
		uuids: map[string]string{
			extAppDir:  "vol-uuid-1",
			extAppDir2: "vol-uuid-2",
		},
	}

	mgr := NewManager(dataDir, "lightisled", nil)
	defer mgr.Close()
	mgr.SetStoragePolicyForTesting(provider, []string{extRoot})
	mgr.SetExternalVolumesProvider(func() []ExternalVolumeInfo {
		return []ExternalVolumeInfo{{Name: "DiskOne", Mount: extVol, TotalBytes: 1000, FreeBytes: 800}}
	})
	if err := mgr.Reload(); err != nil {
		t.Fatal(err)
	}

	snap := mgr.GetStorageSnapshot()
	if snap.MaxInternal != 1 || snap.MaxExternal != 1 || snap.MaxLocations != 2 {
		t.Fatalf("unexpected caps: %+v", snap)
	}
	if snap.HasExternal || len(snap.Locations) != 1 || snap.Locations[0].ID != AppStorageIDInternal {
		t.Fatalf("expected single default internal slot initially: %+v", snap)
	}

	// Cannot "add" a second internal location.
	if _, err := mgr.MutateStorageLocation(AppStorageMutationRequest{
		Action: "add",
		Kind:   AppStorageKindInternal,
		Path:   customInternal,
	}); !errors.Is(err, ErrStorageSlotLimit) {
		t.Fatalf("expected ErrStorageSlotLimit when adding internal, got %v", err)
	}

	// Reject external path in internal slot and non-external path in external slot.
	if _, err := mgr.MutateStorageLocation(AppStorageMutationRequest{
		Action: "set",
		Kind:   AppStorageKindInternal,
		Path:   extAppDir,
	}); !errors.Is(err, ErrInvalid) {
		t.Fatalf("expected ErrInvalid when setting external path as internal, got %v", err)
	}
	if _, err := mgr.MutateStorageLocation(AppStorageMutationRequest{
		Action: "add",
		Kind:   AppStorageKindExternal,
		Path:   customInternal,
	}); !errors.Is(err, ErrInvalid) {
		t.Fatalf("expected ErrInvalid when setting non-external path as external, got %v", err)
	}

	// Reject symlink escape from internal dir into external dir.
	symlinkInternal := filepath.Join(t.TempDir(), "sym-escape")
	if err := os.Symlink(extAppDir, symlinkInternal); err != nil {
		t.Fatal(err)
	}
	if _, err := mgr.MutateStorageLocation(AppStorageMutationRequest{
		Action: "set",
		Kind:   AppStorageKindInternal,
		Path:   symlinkInternal,
	}); !errors.Is(err, ErrInvalid) {
		t.Fatalf("expected ErrInvalid for symlink pointing to external volume, got %v", err)
	}

	// Add external slot -> succeeds (1 internal + 1 external = 2 locations).
	snap, err := mgr.MutateStorageLocation(AppStorageMutationRequest{
		Action:     "add",
		Kind:       AppStorageKindExternal,
		Path:       extAppDir,
		SetDefault: true,
	})
	if err != nil {
		t.Fatalf("failed adding external slot: %v", err)
	}
	if !snap.HasExternal || len(snap.Locations) != 2 || snap.DefaultLocationID != AppStorageIDExternal {
		t.Fatalf("unexpected snapshot after adding external: %+v", snap)
	}

	// Adding a 2nd external location must be blocked by slot cap.
	if _, err := mgr.MutateStorageLocation(AppStorageMutationRequest{
		Action: "add",
		Kind:   AppStorageKindExternal,
		Path:   extAppDir2,
	}); !errors.Is(err, ErrStorageSlotLimit) {
		t.Fatalf("expected ErrStorageSlotLimit adding second external, got %v", err)
	}

	// Customize internal slot & ensure built-in network-pulse from dataDir stays visible via fallback.
	snap, err = mgr.MutateStorageLocation(AppStorageMutationRequest{
		Action: "set",
		Kind:   AppStorageKindInternal,
		Path:   customInternal,
	})
	if err != nil {
		t.Fatalf("failed setting custom internal path: %v", err)
	}
	if snap.Locations[0].Path != filepath.Clean(customInternal) || !snap.Locations[0].IsCustomPath {
		t.Fatalf("expected custom internal path, got %+v", snap.Locations[0])
	}
	appsList := mgr.ListForUser(0, "admin")
	foundDemo := false
	for _, a := range appsList {
		if a.ID == "network-pulse" {
			foundDemo = true
			break
		}
	}
	if !foundDemo {
		t.Fatalf("expected network-pulse to stay discoverable after customizing internal path")
	}

	// Install official template explicitly onto external disk (via default).
	installed, err := mgr.InstallTemplateAt("family-subscriptions", "")
	if err != nil {
		t.Fatalf("InstallTemplateAt failed: %v", err)
	}
	if installed.LocationID != AppStorageIDExternal || installed.PluginsDir != filepath.Join(extAppDir, "plugins", "family-subscriptions") {
		t.Fatalf("unexpected install location: %+v", installed)
	}

	// Simulate external disk swap / UUID mismatch -> external becomes offline & cannot fall back.
	provider.mu.Lock()
	provider.uuids[extAppDir] = "different-physical-disk-uuid"
	provider.mu.Unlock()
	if err := mgr.Reload(); err != nil {
		t.Fatal(err)
	}
	snap = mgr.GetStorageSnapshot()
	if snap.Locations[1].Online || snap.Locations[1].Writable {
		t.Fatalf("expected external location offline after UUID mismatch: %+v", snap.Locations[1])
	}
	if _, err := mgr.InstallTemplateAt("family-board", AppStorageIDExternal); !errors.Is(err, ErrStorageOffline) {
		t.Fatalf("expected ErrStorageOffline installing to swapped/offline external, got %v", err)
	}

	// Safe removal of external location stops/unloads external apps, resets default to internal, NEVER deletes disk files.
	snap, err = mgr.MutateStorageLocation(AppStorageMutationRequest{Action: "remove_external"})
	if err != nil {
		t.Fatalf("remove_external failed: %v", err)
	}
	if snap.HasExternal || len(snap.Locations) != 1 || snap.DefaultLocationID != AppStorageIDInternal {
		t.Fatalf("unexpected state after remove_external: %+v", snap)
	}
	if _, err := os.Stat(filepath.Join(extAppDir, "plugins", "family-subscriptions", "plugin.json")); err != nil {
		t.Fatalf("external plugin files must NEVER be deleted on unregister: %v", err)
	}

	// Reset internal back to default.
	snap, err = mgr.MutateStorageLocation(AppStorageMutationRequest{Action: "reset_internal"})
	if err != nil {
		t.Fatalf("reset_internal failed: %v", err)
	}
	if snap.Locations[0].Path != filepath.Clean(dataDir) || snap.Locations[0].IsCustomPath {
		t.Fatalf("expected internal restored to default dataDir, got %+v", snap.Locations[0])
	}
}

func TestMCPToolsWorkAcrossExternalStorageLocation(t *testing.T) {
	dataDir := t.TempDir()
	extRoot := t.TempDir()
	extVol := filepath.Join(extRoot, "ExtSSD")
	extAppDir := filepath.Join(extVol, "LightIsleApps")
	if err := os.MkdirAll(extVol, 0700); err != nil {
		t.Fatal(err)
	}

	mgr := NewManager(dataDir, "lightisled", nil)
	defer mgr.Close()
	mgr.SetStoragePolicyForTesting(&fakeStorageIdentityProvider{}, []string{extRoot})
	if err := mgr.Reload(); err != nil {
		t.Fatal(err)
	}
	if _, err := mgr.MutateStorageLocation(AppStorageMutationRequest{
		Action: "add",
		Kind:   AppStorageKindExternal,
		Path:   extAppDir,
	}); err != nil {
		t.Fatal(err)
	}

	scaffoldArgs, _ := json.Marshal(map[string]any{
		"id":         "ext-widget",
		"name":       "External Widget",
		"mode":       WebModeStatic,
		"locationId": AppStorageIDExternal,
	})
	res := toolScaffoldApp(dataDir, mgr, scaffoldArgs)
	if res.IsError {
		t.Fatalf("scaffold failed: %s", res.Content[0].Text)
	}
	if _, err := os.Stat(filepath.Join(extAppDir, "plugins", "ext-widget", "plugin.json")); err != nil {
		t.Fatalf("expected scaffolded plugin on external location: %v", err)
	}

	writeArgs, _ := json.Marshal(map[string]any{
		"id":      "ext-widget",
		"path":    "ui/index.html",
		"content": "<h1>Updated External</h1>",
	})
	if wres := toolWritePluginFile(dataDir, mgr, writeArgs); wres.IsError {
		t.Fatalf("write failed: %s", wres.Content[0].Text)
	}

	readArgs, _ := json.Marshal(map[string]any{
		"id":   "ext-widget",
		"path": "ui/index.html",
	})
	rres := toolReadPluginFile(dataDir, mgr, readArgs)
	if rres.IsError {
		t.Fatalf("read failed: %s", rres.Content[0].Text)
	}

	valArgs, _ := json.Marshal(map[string]any{"id": "ext-widget"})
	vres := toolValidateAndReload(context.Background(), dataDir, mgr, valArgs)
	if vres.IsError {
		t.Fatalf("validate failed: %s", vres.Content[0].Text)
	}

	app, err := mgr.GetForUser("ext-widget", 0, "admin")
	if err != nil {
		t.Fatalf("expected ext-widget loaded after validate: %v", err)
	}
	if app.LocationID != AppStorageIDExternal {
		t.Fatalf("expected app locationId external, got %q", app.LocationID)
	}
}
