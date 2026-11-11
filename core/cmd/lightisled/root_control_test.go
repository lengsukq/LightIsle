//go:build darwin && arm64

package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/server"
	"github.com/lengsukq/lightisle/core/internal/storageidentity"
)

func rootCommand(operation string, request any) string {
	data, _ := json.Marshal(request)
	return "roots " + operation + " " + base64.RawURLEncoding.EncodeToString(data)
}

func TestRootControlDefaultSelectionByRootIdentity(t *testing.T) {
	base := t.TempDir()
	data := filepath.Join(base, "private")
	first := filepath.Join(base, "first")
	second := filepath.Join(base, "second")
	for _, path := range []string{data, first, second} {
		if err := os.Mkdir(path, 0700); err != nil {
			t.Fatal(err)
		}
	}
	registry, err := roots.OpenWithProvider(data, storageidentity.SystemProvider{}, base)
	if err != nil {
		t.Fatal(err)
	}
	rootA, err := registry.Add(context.Background(), "第一盘", first)
	if err != nil {
		t.Fatal(err)
	}
	rootB, err := registry.Add(context.Background(), "第二盘", second)
	if err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	c := &rootControl{registry: registry, output: &output}
	c.handle(context.Background(), rootCommand("set-default", rootControlRequest{
		ID: rootB.ID, Generation: rootB.Generation + 1, RequestID: "old",
	}))
	if response := controlResponse(t, &output); string(response["error"]) != `"root_registry_stale"` {
		t.Fatalf("accepted stale default switch: %s", response["error"])
	}
	c.handle(context.Background(), rootCommand("set-default", rootControlRequest{
		ID: rootB.ID, Generation: rootB.Generation, RequestID: "new",
	}))
	if response := controlResponse(t, &output); len(response["error"]) != 0 {
		t.Fatalf("default switch failed: %s", response["error"])
	}
	chosen, ok := registry.Default()
	if !ok || chosen.ID != rootB.ID || chosen.ID == rootA.ID {
		t.Fatalf("default mismatch: %+v", chosen)
	}
	c.handle(context.Background(), rootCommand("list", rootControlRequest{RequestID: "list"}))
	response := controlResponse(t, &output)
	var listed []nativeRoot
	if err := json.Unmarshal(response["result"], &listed); err != nil {
		t.Fatal(err)
	}
	if len(listed) != 2 || len([]nativeRoot{listed[0], listed[1]}) != 2 ||
		!((listed[0].ID == rootB.ID && listed[0].IsDefault) || (listed[1].ID == rootB.ID && listed[1].IsDefault)) {
		t.Fatalf("native list lost default root: %+v", listed)
	}
}

func TestDefaultShareCanSwitchAlongsideSeparateRegisteredRoots(t *testing.T) {
	base := t.TempDir()
	registered := filepath.Join(base, "disk-a", "photos")
	separate := filepath.Join(base, "disk-b", "share")
	child := filepath.Join(registered, "child")
	for _, folder := range []string{registered, separate, child} {
		if err := os.MkdirAll(folder, 0700); err != nil {
			t.Fatal(err)
		}
	}
	registeredRoots := []roots.Root{{Path: registered}}
	if err := checkLegacyShareRootOverlap(separate, registeredRoots); err != nil {
		t.Fatalf("independent default share rejected while multi-root is enabled: %v", err)
	}
	for _, target := range []string{registered, child, filepath.Dir(registered)} {
		if err := checkLegacyShareRootOverlap(target, registeredRoots); !errors.Is(err, roots.ErrOverlap) {
			t.Fatalf("overlapping default share %q: expected conflict, got %v", target, err)
		}
	}
	alias := filepath.Join(base, "alias")
	if err := os.Symlink(registered, alias); err != nil {
		t.Fatal(err)
	}
	if err := checkLegacyShareRootOverlap(alias, registeredRoots); !errors.Is(err, roots.ErrOverlap) {
		t.Fatalf("symlink alias of registered root was accepted: %v", err)
	}
}

func TestNativeRootRegistrationRejectsDefaultShareOverlap(t *testing.T) {
	base := t.TempDir()
	data := filepath.Join(base, "private")
	defaultShare := filepath.Join(base, "default", "share")
	other := filepath.Join(base, "other")
	for _, folder := range []string{data, defaultShare, other} {
		if err := os.MkdirAll(folder, 0700); err != nil {
			t.Fatal(err)
		}
	}
	registry, err := roots.OpenWithProvider(data, storageidentity.SystemProvider{}, base)
	if err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	c := &rootControl{registry: registry, output: &output, legacySharePath: func() string { return defaultShare }}
	for _, target := range []string{defaultShare, filepath.Dir(defaultShare)} {
		c.handle(context.Background(), rootCommand("add", rootControlRequest{Name: "conflicting", Path: target}))
		response := controlResponse(t, &output)
		if string(response["error"]) != `"root_registry_overlap"` {
			t.Fatalf("registered overlapping root %q: %s", target, response["error"])
		}
	}
	c.handle(context.Background(), rootCommand("add", rootControlRequest{Name: "other", Path: other}))
	response := controlResponse(t, &output)
	if len(response["error"]) != 0 || len(registry.List()) != 1 {
		t.Fatalf("independent registered root rejected: %s", response["error"])
	}
}

func TestRootControlMigrationPreviewWasRemoved(t *testing.T) {
	base := t.TempDir()
	private := filepath.Join(base, "private")
	if err := os.Mkdir(private, 0700); err != nil {
		t.Fatal(err)
	}
	registry, err := roots.OpenWithProvider(private, storageidentity.SystemProvider{}, base)
	if err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	c := &rootControl{registry: registry, output: &output}
	for _, operation := range []string{"migration-preview", "backup-start", "backup-restore", "backup-plan-status", "backup-plan-set", "backup-plan-off"} {
		c.handle(context.Background(), rootCommand(operation, rootControlRequest{RequestID: "retired"}))
		result := controlResponse(t, &output)
		if string(result["error"]) != `"root_registry_path_not_allowed"` {
			t.Fatalf("removed native operation %s still reachable: %+v", operation, result)
		}
	}
}

func controlResponse(t *testing.T, output *bytes.Buffer) map[string]json.RawMessage {
	t.Helper()
	line := strings.TrimSpace(output.String())
	output.Reset()
	if !strings.HasPrefix(line, "LIGHTISLE_ROOTS ") {
		t.Fatalf("invalid response: %q", line)
	}
	data, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(line, "LIGHTISLE_ROOTS "))
	if err != nil {
		t.Fatal(err)
	}
	var response map[string]json.RawMessage
	if err := json.Unmarshal(data, &response); err != nil {
		t.Fatal(err)
	}
	return response
}

func TestRootControlRequiresPreviewAndRejectsMalformedRequest(t *testing.T) {
	var output bytes.Buffer
	c := &rootControl{output: &output}
	if c.handle(context.Background(), "stats") {
		t.Fatal("captured unrelated native command")
	}
	if !c.handle(context.Background(), "roots list") {
		t.Fatal("root command not handled")
	}
	if got := controlResponse(t, &output); string(got["error"]) != `"root_registry_path_not_allowed"` {
		t.Fatalf("unavailable root control accepted request: %s", got["error"])
	}
}

func TestRootControlListEchoesRequestIDAndKeepsLegacyCommand(t *testing.T) {
	base := t.TempDir()
	data := filepath.Join(base, "private")
	if err := os.Mkdir(data, 0700); err != nil {
		t.Fatal(err)
	}
	registry, err := roots.OpenWithProvider(data, storageidentity.SystemProvider{}, base)
	if err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	c := &rootControl{registry: registry, output: &output}
	const requestID = "native-request-123"
	c.handle(context.Background(), rootCommand("list", rootControlRequest{RequestID: requestID}))
	response := controlResponse(t, &output)
	var gotRequestID string
	if err := json.Unmarshal(response["requestID"], &gotRequestID); err != nil || gotRequestID != requestID {
		t.Fatalf("list request ID = %q, err=%v", gotRequestID, err)
	}
	c.handle(context.Background(), "roots list")
	response = controlResponse(t, &output)
	gotRequestID = "unset"
	if err := json.Unmarshal(response["requestID"], &gotRequestID); err != nil || gotRequestID != "" {
		t.Fatalf("legacy list request ID = %q, err=%v", gotRequestID, err)
	}
	c.handle(context.Background(), rootCommand("list", rootControlRequest{RequestID: strings.Repeat("x", 65)}))
	response = controlResponse(t, &output)
	if string(response["error"]) != `"root_registry_invalid"` || string(response["requestID"]) != `""` {
		t.Fatalf("oversized request ID was accepted or echoed: %s", response["requestID"])
	}
}

func TestRootControlRegisterRebindAndRemovePreservesFiles(t *testing.T) {
	base := t.TempDir()
	base, _ = filepath.EvalSymlinks(base)
	data := filepath.Join(base, "private")
	first := filepath.Join(base, "first")
	second := filepath.Join(base, "second")
	backupTarget := filepath.Join(base, "backups")
	for _, dir := range []string{data, first, second, backupTarget} {
		if err := os.Mkdir(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(first, "keep.txt"), []byte("original"), 0600); err != nil {
		t.Fatal(err)
	}
	registry, err := roots.OpenWithProvider(data, storageidentity.SystemProvider{}, base)
	if err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	c := &rootControl{registry: registry, output: &output, backupDestinations: func() []string { return []string{backupTarget} }}
	ctx := context.Background()
	c.handle(ctx, rootCommand("add", rootControlRequest{Name: "disk", Path: first}))
	response := controlResponse(t, &output)
	if len(response["error"]) != 0 {
		t.Fatalf("add: %s", response["error"])
	}
	var item roots.Root
	if err := json.Unmarshal(response["result"], &item); err != nil || item.ID == "" {
		t.Fatalf("root: %+v %v", item, err)
	}
	c.handle(ctx, rootCommand("add", map[string]any{"name": "x", "path": second, "unexpected": true}))
	if response = controlResponse(t, &output); len(response["error"]) == 0 {
		t.Fatal("unknown request property accepted")
	}
	c.handle(ctx, rootCommand("add", rootControlRequest{Name: "backup", Path: backupTarget}))
	if response = controlResponse(t, &output); string(response["error"]) != `"root_registry_overlap"` {
		t.Fatal("backup destination became a shared root")
	}
	backupParent := filepath.Join(base, "backup-parent")
	backupAlias := filepath.Join(base, "backup-alias")
	aliasedCandidate := filepath.Join(backupParent, "future", "candidate")
	if err := os.Mkdir(backupParent, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(backupParent, backupAlias); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(aliasedCandidate, 0700); err != nil {
		t.Fatal(err)
	}
	c.backupDestinations = func() []string { return []string{filepath.Join(backupAlias, "future")} }
	c.handle(ctx, rootCommand("add", rootControlRequest{Name: "scheduled destination", Path: aliasedCandidate}))
	if response = controlResponse(t, &output); string(response["error"]) != `"root_registry_overlap"` {
		t.Fatalf("uncreated symlinked backup destination was not protected: %s", response["error"])
	}
	c.backupDestinations = func() []string { return []string{backupTarget} }
	c.handle(ctx, rootCommand("remove", rootControlRequest{ID: item.ID, Generation: item.Generation + 1}))
	if response = controlResponse(t, &output); string(response["error"]) != `"root_registry_stale"` {
		t.Fatal("stale native selection removed root")
	}
	lease, err := registry.Acquire(ctx, item.ID)
	if err != nil {
		t.Fatal(err)
	}
	c.handle(ctx, rootCommand("rebind", rootControlRequest{ID: item.ID, Generation: item.Generation, Path: second}))
	if response = controlResponse(t, &output); string(response["error"]) != `"root_registry_busy"` {
		t.Fatal("active lease did not prevent rebind")
	}
	lease.Close()
	c.handle(ctx, rootCommand("rebind", rootControlRequest{ID: item.ID, Generation: item.Generation, Path: second}))
	response = controlResponse(t, &output)
	if string(response["error"]) != `"root_registry_other_folder_requires_add"` {
		t.Fatalf("unrelated physical folder reused old ACL: %s", response["error"])
	}
	c.handle(ctx, rootCommand("rebind", rootControlRequest{ID: item.ID, Generation: item.Generation, Path: first}))
	response = controlResponse(t, &output)
	if len(response["error"]) != 0 {
		t.Fatalf("rebind: %s", response["error"])
	}
	json.Unmarshal(response["result"], &item)
	c.handle(ctx, "roots list")
	response = controlResponse(t, &output)
	var listing []nativeRoot
	json.Unmarshal(response["result"], &listing)
	if len(listing) != 1 || !listing[0].Online || listing[0].Path != first {
		t.Fatalf("listing: %+v", listing)
	}
	c.handle(ctx, rootCommand("remove", rootControlRequest{ID: item.ID, Generation: item.Generation}))
	if response = controlResponse(t, &output); len(response["error"]) != 0 {
		t.Fatalf("remove: %s", response["error"])
	}
	if len(registry.List()) != 0 {
		t.Fatal("removed root still registered")
	}
	if bytes, err := os.ReadFile(filepath.Join(first, "keep.txt")); err != nil || string(bytes) != "original" {
		t.Fatal("root removal/rebind modified original files")
	}
}

func TestRootControlRejectsBackupDestinationOverlappingAnyRegisteredRoot(t *testing.T) {
	base := t.TempDir()
	volume := filepath.Join(base, "volume")
	dataDir := filepath.Join(base, "private")
	rootAPath := filepath.Join(volume, "root-a")
	rootBPath := filepath.Join(volume, "root-b")
	for _, path := range []string{rootAPath, rootBPath, dataDir} {
		if err := os.MkdirAll(path, 0700); err != nil {
			t.Fatal(err)
		}
	}
	registry, err := roots.OpenWithProvider(dataDir, storageidentity.SystemProvider{}, volume)
	if err != nil {
		t.Fatal(err)
	}
	rootA, err := registry.Add(context.Background(), "Root A", rootAPath)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := registry.Add(context.Background(), "Root B", rootBPath); err != nil {
		t.Fatal(err)
	}
	accounts, err := auth.Open(filepath.Join(base, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("owner", "long-initial-password"); err != nil {
		t.Fatal(err)
	}
	factory := func(_ context.Context, root roots.Root, lease *roots.Lease) (*server.RootServices, error) {
		manager, err := files.NewPinnedManager(lease.Root, root.Binding)
		if err != nil {
			return nil, err
		}
		return &server.RootServices{Files: manager}, nil
	}
	rootServer := server.NewWithRoots("", accounts, nil, nil, nil, nil, registry, factory)
	defer func() {
		if err := rootServer.Shutdown(); err != nil {
			t.Errorf("shutdown root server: %v", err)
		}
	}()
	var output bytes.Buffer
	control := &rootControl{registry: registry, output: &output, server: rootServer}
	const requestID = "backup-destination-check"
	control.handle(context.Background(), rootCommand("backup-start", rootControlRequest{
		ID: rootA.ID, Generation: rootA.Generation, Path: rootBPath, RequestID: requestID,
	}))
	response := controlResponse(t, &output)
	var gotRequestID string
	if err := json.Unmarshal(response["requestID"], &gotRequestID); err != nil || gotRequestID != requestID {
		t.Fatalf("backup overlap reply request ID = %q, err=%v", gotRequestID, err)
	}
	if string(response["error"]) != `"root_registry_path_not_allowed"` {
		t.Fatalf("removed whole-root backup IPC accepted an old client: %s", response["error"])
	}
}

func TestRootControlUpfrontPermissionVerificationAndPrewarm(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root bypasses POSIX mode checks")
	}
	base := t.TempDir()
	base, _ = filepath.EvalSymlinks(base)
	dataDir := filepath.Join(base, "private")
	lockedDisk := filepath.Join(base, "external-disk")
	for _, dir := range []string{dataDir, lockedDisk} {
		if err := os.MkdirAll(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Chmod(lockedDisk, 0500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(lockedDisk, 0700) })

	registry, err := roots.OpenWithProvider(dataDir, storageidentity.SystemProvider{}, base)
	if err != nil {
		t.Fatal(err)
	}
	accounts, err := auth.Open(filepath.Join(base, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("owner", "long-initial-password"); err != nil {
		t.Fatal(err)
	}
	prewarmed := 0
	factory := func(_ context.Context, root roots.Root, lease *roots.Lease) (*server.RootServices, error) {
		prewarmed++
		manager, err := files.NewPinnedManager(lease.Root, root.Binding)
		if err != nil {
			return nil, err
		}
		return &server.RootServices{Files: manager}, nil
	}
	rootServer := server.NewWithRoots("", accounts, nil, nil, nil, nil, registry, factory)
	defer func() { _ = rootServer.Shutdown() }()

	var output bytes.Buffer
	control := &rootControl{registry: registry, accounts: accounts, output: &output, server: rootServer}
	ctx := context.Background()

	control.handle(ctx, rootCommand("verify-access", rootControlRequest{Path: lockedDisk, RequestID: "perm-1"}))
	if resp := controlResponse(t, &output); string(resp["error"]) != `"root_permission_denied"` {
		t.Fatalf("expected upfront root_permission_denied on verify-access, got: %s", resp["error"])
	}

	control.handle(ctx, rootCommand("add", rootControlRequest{Name: "外置盘", Path: lockedDisk, RequestID: "perm-2"}))
	if resp := controlResponse(t, &output); string(resp["error"]) != `"root_permission_denied"` {
		t.Fatalf("expected upfront root_permission_denied on add, got: %s", resp["error"])
	}
	if len(registry.List()) != 0 || prewarmed != 0 {
		t.Fatalf("unwritable root should not be registered or prewarmed: roots=%d prewarmed=%d", len(registry.List()), prewarmed)
	}

	if err := os.Chmod(lockedDisk, 0700); err != nil {
		t.Fatal(err)
	}
	nestedLocked := filepath.Join(lockedDisk, "Users", "u1", "photos")
	if err := os.MkdirAll(nestedLocked, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(nestedLocked, 0500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(nestedLocked, 0700) })

	control.handle(ctx, rootCommand("add", rootControlRequest{Name: "外置盘", Path: lockedDisk, RequestID: "perm-nested"}))
	if resp := controlResponse(t, &output); string(resp["error"]) != `"root_permission_denied"` {
		t.Fatalf("expected upfront root_permission_denied when nested Users dir is read-only, got: %s", resp["error"])
	}
	if len(registry.List()) != 0 {
		t.Fatalf("root with unwritable nested Users dir should not be registered: %d", len(registry.List()))
	}

	if err := os.Chmod(nestedLocked, 0700); err != nil {
		t.Fatal(err)
	}
	control.handle(ctx, rootCommand("verify-access", rootControlRequest{Path: lockedDisk, RequestID: "perm-3"}))
	if resp := controlResponse(t, &output); len(resp["error"]) != 0 {
		t.Fatalf("verify-access after chmod failed: %s", resp["error"])
	}

	control.handle(ctx, rootCommand("add", rootControlRequest{Name: "外置盘", Path: lockedDisk, RequestID: "perm-4"}))
	if resp := controlResponse(t, &output); len(resp["error"]) != 0 {
		t.Fatalf("add after chmod failed: %s", resp["error"])
	}
	if len(registry.List()) != 1 || prewarmed != 0 {
		t.Fatalf("expected registered root without prematurely caching RootServices, got roots=%d prewarmed=%d", len(registry.List()), prewarmed)
	}
	for _, internalDir := range []string{"Users", ".lightisle-trash", ".lightisle-parts", ".lightisle-uploads", ".lightisle-appdata"} {
		info, statErr := os.Stat(filepath.Join(lockedDisk, internalDir))
		if statErr != nil || !info.IsDir() {
			t.Fatalf("expected on-volume %s directory to be prewarmed: %v", internalDir, statErr)
		}
	}
	if got := externalVolumeMountRoot("/Volumes/PortableSSD/LightIsle/Data"); got != "/Volumes/PortableSSD" {
		t.Fatalf("externalVolumeMountRoot = %q, want /Volumes/PortableSSD", got)
	}
	if got := externalVolumeMountRoot("/Users/leo/LightIsle"); got != "" {
		t.Fatalf("externalVolumeMountRoot for home dir = %q, want empty", got)
	}
}
