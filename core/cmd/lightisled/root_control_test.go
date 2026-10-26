//go:build darwin && arm64

package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/backup"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/server"
	"github.com/lengsukq/lightisle/core/internal/storageidentity"
)

func rootCommand(operation string, request any) string {
	data, _ := json.Marshal(request)
	return "roots " + operation + " " + base64.RawURLEncoding.EncodeToString(data)
}

func TestRootControlLegacyVerificationRejectsCallerSelectedPaths(t *testing.T) {
	base := t.TempDir()
	private := filepath.Join(base, "private")
	original := filepath.Join(base, "legacy")
	for _, p := range []string{private, original} {
		if err := os.Mkdir(p, 0700); err != nil {
			t.Fatal(err)
		}
	}
	registry, err := roots.OpenWithProvider(private, storageidentity.SystemProvider{}, base)
	if err != nil {
		t.Fatal(err)
	}
	legacyConfig := filepath.Join(private, "shared-root.json")
	configData, _ := json.Marshal(map[string]string{"path": original})
	if err := os.WriteFile(legacyConfig, configData, 0600); err != nil {
		t.Fatal(err)
	}
	if err := registry.ImportLegacy(legacyConfig); err != nil {
		t.Fatal(err)
	}
	initial := registry.List()[0]
	binding, err := (storageidentity.SystemProvider{}).Capture(context.Background(), original)
	if err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	calls := 0
	c := &rootControl{registry: registry, output: &output,
		verifyLegacyRoot: func(ctx context.Context, id string, generation uint64) (roots.Root, error) {
			calls++
			if id != initial.ID || generation != initial.Generation {
				return roots.Root{}, roots.ErrStale
			}
			return registry.Rebind(ctx, id, original, binding)
		},
	}
	for _, req := range []rootControlRequest{
		{ID: initial.ID, Generation: initial.Generation, Path: original},
		{ID: initial.ID, Generation: initial.Generation, Name: "unexpected"},
		{Generation: initial.Generation},
	} {
		c.handle(context.Background(), rootCommand("legacy-verify", req))
		resp := controlResponse(t, &output)
		if string(resp["error"]) != `"root_registry_path_not_allowed"` {
			t.Fatalf("legacy identity accepted untrusted arguments: %s", resp["error"])
		}
	}
	if calls != 0 || !registry.List()[0].Pending {
		t.Fatal("rejected IPC mutation ran the privileged legacy verifier")
	}
	c.handle(context.Background(), rootCommand("legacy-verify", rootControlRequest{ID: initial.ID, Generation: initial.Generation}))
	resp := controlResponse(t, &output)
	if len(resp["error"]) > 0 || calls != 1 {
		t.Fatalf("owner verified original identity was denied: %+v", resp)
	}
	updated := registry.List()[0]
	if updated.Pending || updated.Generation != initial.Generation+1 {
		t.Fatalf("confirmed original identity was not persisted: %+v", updated)
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
		service, err := backup.NewForRoot(manager, dataDir, root, registry)
		if err != nil {
			_ = manager.Close()
			return nil, err
		}
		return &server.RootServices{Files: manager, Backup: service}, nil
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
