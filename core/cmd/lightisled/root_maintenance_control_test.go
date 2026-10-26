//go:build darwin && arm64

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/storageidentity"
	"github.com/lengsukq/lightisle/core/internal/tasks"
)

func TestNativeRootListIncludesPersistedMaintenanceWithoutDiskPathLeak(t *testing.T) {
	base := t.TempDir()
	folder := filepath.Join(base, "share")
	private := filepath.Join(base, "private")
	if err := os.Mkdir(folder, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(private, 0700); err != nil {
		t.Fatal(err)
	}
	registry, err := roots.OpenWithProvider(private, storageidentity.SystemProvider{}, base)
	if err != nil {
		t.Fatal(err)
	}
	root, err := registry.Add(context.Background(), "photos", folder)
	if err != nil {
		t.Fatal(err)
	}
	journal, err := tasks.Open(private)
	if err != nil {
		t.Fatal(err)
	}
	defer journal.Close()
	if err := journal.UpdateRootMaintenance(root.ID, root.Generation, "offline"); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	control := rootControl{registry: registry, journal: journal, output: &out}
	control.handle(context.Background(), rootCommand("list", rootControlRequest{RequestID: "status-test"}))
	result := controlResponse(t, &out)
	var items []nativeRoot
	if err := json.Unmarshal(result["result"], &items); err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 || items[0].Maintenance == nil || items[0].Maintenance.Status != "offline" ||
		items[0].Maintenance.RootID != root.ID || items[0].Maintenance.LastSuccess != 0 {
		t.Fatalf("native owner cannot inspect offline root status: %+v", items)
	}
}
