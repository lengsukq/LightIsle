//go:build darwin && arm64

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/backup"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/storageidentity"
)

type rootPlanFixtureIdentityProvider struct{}

func (rootPlanFixtureIdentityProvider) Capture(_ context.Context, path string) (storageidentity.Binding, error) {
	info, err := os.Stat(path)
	if err != nil {
		return storageidentity.Binding{}, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return storageidentity.Binding{}, errors.New("fixture stat identity unavailable")
	}
	return storageidentity.Binding{
		Path: path, VolumeUUID: "12345678-1234-1234-1234-123456789abc",
		DirectoryID: stat.Ino, BirthSec: stat.Birthtimespec.Sec,
		BirthNsec: stat.Birthtimespec.Nsec, Generation: uint64(stat.Gen),
	}, nil
}

func (p rootPlanFixtureIdentityProvider) Verify(ctx context.Context, expected storageidentity.Binding) error {
	actual, err := p.Capture(ctx, expected.Path)
	if err != nil {
		return err
	}
	if !storageidentity.Equal(actual, expected) {
		return storageidentity.ErrMismatch
	}
	return nil
}

func newRootPlanControlFixture(t *testing.T) (*rootControl, *roots.Registry, *backup.RootPlanManager, roots.Root, string) {
	t.Helper()
	base := t.TempDir()
	private := filepath.Join(base, "private")
	rootPath := filepath.Join(base, "source")
	if err := os.Mkdir(private, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(rootPath, 0700); err != nil {
		t.Fatal(err)
	}
	provider := rootPlanFixtureIdentityProvider{}
	registry, err := roots.OpenWithProvider(private, provider, base)
	if err != nil {
		t.Fatal(err)
	}
	root, err := registry.Add(context.Background(), "source", rootPath)
	if err != nil {
		t.Fatal(err)
	}
	planProvider := backup.RootBackupProvider(func(context.Context, string, uint64) (*backup.RootBackupLease, error) {
		return nil, backup.ErrRootPlanUnavailable
	})
	canonicalPrivate, err := filepath.EvalSymlinks(private)
	if err != nil {
		t.Fatal(err)
	}
	manager, err := backup.NewRootPlanManager(canonicalPrivate, registry, planProvider)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := manager.Close(); err != nil {
			t.Errorf("close root plan manager: %v", err)
		}
	})
	return &rootControl{registry: registry, rootPlans: manager}, registry, manager, root, canonicalPrivate
}

func decodeRootPlanResult(t *testing.T, raw json.RawMessage) nativeRootBackupPlan {
	t.Helper()
	var result nativeRootBackupPlan
	if err := json.Unmarshal(raw, &result); err != nil {
		t.Fatal(err)
	}
	return result
}

func TestRootPlanIPCStatusAndDisableWorkWhileSourceIsOffline(t *testing.T) {
	control, registry, manager, root, private := newRootPlanControlFixture(t)
	defer manager.Close()
	planDir := filepath.Join(private, "root-backup-plans")
	preconfigured := backup.Schedule{
		RootID: root.ID, RootGeneration: root.Generation, Enabled: true,
		EveryHours: 24, Destination: filepath.Join(t.TempDir(), "offline-destination"),
		PlanID: "fixture-plan", RetentionCount: 0, LastAttempt: 1234,
		NextRun: time.Now().Add(time.Hour).Unix(),
	}
	data, err := json.Marshal(preconfigured)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(planDir, planFileNameForTest(root)), data, 0600); err != nil {
		t.Fatal(err)
	}
	// Reload the manager so the test exercises the same persisted read path as
	// an app restart. No backup provider call or destination disk access occurs.
	if err := manager.Close(); err != nil {
		t.Fatal(err)
	}
	manager, err = backup.NewRootPlanManager(private, registry, func(context.Context, string, uint64) (*backup.RootBackupLease, error) {
		return nil, backup.ErrRootPlanUnavailable
	})
	if err != nil {
		t.Fatal(err)
	}
	control.rootPlans = manager
	defer manager.Close()

	offlinePath := root.Path + ".unmounted"
	if err := os.Rename(root.Path, offlinePath); err != nil {
		t.Fatal(err)
	}
	if _, err := registry.Acquire(context.Background(), root.ID); !errors.Is(err, roots.ErrOffline) {
		t.Fatalf("fixture source should be offline: %v", err)
	}

	var output bytes.Buffer
	control.output = &output
	control.handle(context.Background(), rootCommand("backup-plan-status", rootPlanRequest(root)))
	response := controlResponse(t, &output)
	if len(response["error"]) != 0 {
		t.Fatalf("status unexpectedly required an online source: %s", response["error"])
	}
	plan := decodeRootPlanResult(t, response["result"])
	if plan.RootID != root.ID || plan.Generation != root.Generation || !plan.Schedule.Enabled ||
		plan.Schedule.RootGeneration != root.Generation || plan.Schedule.LastAttempt != 1234 ||
		plan.Schedule.LastError != backup.ErrDestinationConfirmationRequired.Error() {
		t.Fatalf("offline status lost its persisted identity or failure: %+v", plan)
	}

	control.handle(context.Background(), rootCommand("backup-plan-off", rootPlanRequest(root)))
	response = controlResponse(t, &output)
	if len(response["error"]) != 0 {
		t.Fatalf("disable unexpectedly required an online source: %s", response["error"])
	}
	plan = decodeRootPlanResult(t, response["result"])
	if plan.Schedule.Enabled || plan.Schedule.NextRun != 0 || plan.Schedule.RootGeneration != root.Generation {
		t.Fatalf("offline disable did not persist for the selected generation: %+v", plan.Schedule)
	}
	if err := os.Rename(offlinePath, root.Path); err != nil {
		t.Fatal(err)
	}
	lease, err := registry.Acquire(context.Background(), root.ID)
	if err != nil {
		t.Fatalf("fixture source did not reconnect: %v", err)
	}
	lease.Close()
	control.handle(context.Background(), rootCommand("backup-plan-status", rootPlanRequest(root)))
	response = controlResponse(t, &output)
	plan = decodeRootPlanResult(t, response["result"])
	if len(response["error"]) != 0 || plan.Schedule.Enabled || plan.Schedule.LastError != "" {
		t.Fatalf("disabled plan was not readable after reconnect: %+v (%s)", plan.Schedule, response["error"])
	}
}

func TestRootPlanIPCRejectsStalePendingAndCompatibilityRoots(t *testing.T) {
	control, _, manager, root, _ := newRootPlanControlFixture(t)
	defer manager.Close()
	var output bytes.Buffer
	control.output = &output
	control.handle(context.Background(), rootCommand("backup-plan-status", rootPlanRequest(root, root.Generation+1)))
	if response := controlResponse(t, &output); string(response["error"]) != `"root_registry_stale"` {
		t.Fatalf("stale generation was accepted: %s", response["error"])
	}

	base := t.TempDir()
	private := filepath.Join(base, "private")
	legacyPath := filepath.Join(base, "legacy")
	if err := os.Mkdir(private, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(legacyPath, 0700); err != nil {
		t.Fatal(err)
	}
	registry, err := roots.OpenWithProvider(private, rootPlanFixtureIdentityProvider{}, base)
	if err != nil {
		t.Fatal(err)
	}
	legacyConfig := filepath.Join(private, "shared-root.json")
	if err := os.WriteFile(legacyConfig, []byte(`{"path":"`+legacyPath+`"}`), 0600); err != nil {
		t.Fatal(err)
	}
	if err := registry.ImportLegacy(legacyConfig); err != nil {
		t.Fatal(err)
	}
	var legacy roots.Root
	for _, item := range registry.List() {
		if item.Compatibility {
			legacy = item
			break
		}
	}
	if legacy.ID == "" {
		t.Fatal("legacy fixture was not registered")
	}
	canonicalPrivate, err := filepath.EvalSymlinks(private)
	if err != nil {
		t.Fatal(err)
	}
	legacyManager, err := backup.NewRootPlanManager(canonicalPrivate, registry, func(context.Context, string, uint64) (*backup.RootBackupLease, error) {
		return nil, backup.ErrRootPlanUnavailable
	})
	if err != nil {
		t.Fatal(err)
	}
	defer legacyManager.Close()
	control.registry = registry
	control.rootPlans = legacyManager
	control.handle(context.Background(), rootCommand("backup-plan-off", rootPlanRequest(legacy)))
	if response := controlResponse(t, &output); string(response["error"]) != `"root_registry_path_not_allowed"` {
		t.Fatalf("compatibility or pending root accepted a plan operation: %s", response["error"])
	}
	if legacy.Pending != true {
		t.Fatal("legacy fixture was expected to be pending")
	}
}

func TestRootPlanIPCRequiresExactOperationFieldsAndValidPlanValues(t *testing.T) {
	control, _, manager, root, _ := newRootPlanControlFixture(t)
	defer manager.Close()
	var output bytes.Buffer
	control.output = &output

	for _, request := range []map[string]any{
		{"requestID": "status-extra", "rootID": root.ID, "generation": root.Generation, "path": ""},
		{"requestID": "status-extra-zero", "rootID": root.ID, "generation": root.Generation, "everyHours": 0},
	} {
		control.handle(context.Background(), rootCommand("backup-plan-status", request))
		if response := controlResponse(t, &output); string(response["error"]) != `"root_registry_invalid"` {
			t.Fatalf("status accepted an unrelated present field: %s", response["error"])
		}
	}

	destination := t.TempDir()
	for _, request := range []map[string]any{
		{"requestID": "missing-retention", "rootID": root.ID, "generation": root.Generation,
			"path": destination, "everyHours": 24},
		{"requestID": "bad-frequency", "rootID": root.ID, "generation": root.Generation,
			"path": destination, "everyHours": 48, "retentionCount": 0},
		{"requestID": "bad-retention", "rootID": root.ID, "generation": root.Generation,
			"path": destination, "everyHours": 24, "retentionCount": 31},
	} {
		control.handle(context.Background(), rootCommand("backup-plan-set", request))
		if response := controlResponse(t, &output); string(response["error"]) != `"root_registry_invalid"` {
			t.Fatalf("set accepted an incomplete or out-of-range plan: %s", response["error"])
		}
	}

	control.handle(context.Background(), rootCommand("backup-plan-set", map[string]any{
		"requestID": "source-overlap", "rootID": root.ID, "generation": root.Generation,
		"path": root.Path, "everyHours": 24, "retentionCount": 0,
	}))
	if response := controlResponse(t, &output); string(response["error"]) != `"root_registry_overlap"` {
		t.Fatalf("source root was allowed as its backup destination: %s", response["error"])
	}

	control.handle(context.Background(), rootCommand("backup-plan-set", map[string]any{
		"requestID": "provider-error", "rootID": root.ID, "generation": root.Generation,
		"path": destination, "everyHours": 24, "retentionCount": 0,
	}))
	if response := controlResponse(t, &output); string(response["error"]) != `"root_backup_plan_unavailable"` {
		t.Fatalf("real provider failure was not returned through IPC: %s", response["error"])
	}

	// The newly added request fields are also forbidden on established verbs.
	control.handle(context.Background(), rootCommand("remove", map[string]any{
		"requestID": "remove-extra", "rootID": root.ID, "generation": root.Generation, "retentionCount": 0,
	}))
	if response := controlResponse(t, &output); string(response["error"]) != `"root_registry_invalid"` {
		t.Fatalf("an existing operation accepted a new unrelated field: %s", response["error"])
	}
}

func rootPlanRequest(root roots.Root, generation ...uint64) map[string]any {
	selectedGeneration := root.Generation
	if len(generation) > 0 {
		selectedGeneration = generation[0]
	}
	return map[string]any{"requestID": "plan-test", "rootID": root.ID, "generation": selectedGeneration}
}

func planFileNameForTest(root roots.Root) string {
	return root.ID + "-" + strconv.FormatUint(root.Generation, 10) + ".json"
}
