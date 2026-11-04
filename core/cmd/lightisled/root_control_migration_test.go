//go:build darwin && arm64

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/rootmigration"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/storageidentity"
)

func TestRootControlOneStepDefaultFolderSelectionPreservesOldRoot(t *testing.T) {
	base := t.TempDir()
	data := filepath.Join(base, "data")
	oldPath := filepath.Join(base, "old")
	nextPath := filepath.Join(base, "next")
	for _, location := range []string{data, oldPath, nextPath} {
		if err := os.Mkdir(location, 0700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(oldPath, "keep.txt"), []byte("remain"), 0600); err != nil {
		t.Fatal(err)
	}
	registry, err := roots.OpenWithProvider(data, storageidentity.SystemProvider{}, base)
	if err != nil {
		t.Fatal(err)
	}
	old, err := registry.Add(context.Background(), "old", oldPath)
	if err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	control := rootControl{registry: registry, output: &buf}
	choice := rootControlRequest{Name: "new", Path: nextPath, RequestID: "switch-new"}
	control.handle(context.Background(), rootCommand("select-folder", choice))
	response := controlResponse(t, &buf)
	if len(response["error"]) != 0 {
		t.Fatalf("select new directory: %s", response["error"])
	}
	newRoot, ok := registry.Default()
	canonicalNext, err := filepath.EvalSymlinks(nextPath)
	if err != nil {
		t.Fatal(err)
	}
	if !ok || newRoot.Path != canonicalNext || newRoot.ID == old.ID {
		t.Fatalf("new directory was not registered and selected: %+v", newRoot)
	}
	control.handle(context.Background(), rootCommand("select-folder",
		rootControlRequest{Name: "old", Path: oldPath, RequestID: "switch-back"}))
	response = controlResponse(t, &buf)
	if len(response["error"]) != 0 {
		t.Fatalf("switching back to existing registered root: %s", response["error"])
	}
	selected, ok := registry.Default()
	if !ok || selected.ID != old.ID || len(registry.List()) != 2 {
		t.Fatalf("switch duplicated an existing directory identity: %+v", selected)
	}
	content, err := os.ReadFile(filepath.Join(oldPath, "keep.txt"))
	if err != nil || string(content) != "remain" {
		t.Fatalf("switch changed source bytes: %q %v", content, err)
	}
}

func TestRootControlMigrationPreviewStartAndStatus(t *testing.T) {
	base := t.TempDir()
	data := filepath.Join(base, "data")
	oldPath := filepath.Join(base, "old")
	nextPath := filepath.Join(base, "next")
	for _, location := range []string{data, oldPath, nextPath, filepath.Join(oldPath, "Photos")} {
		if err := os.Mkdir(location, 0700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(oldPath, "Photos", "picture.txt"), []byte("unchanged"), 0600); err != nil {
		t.Fatal(err)
	}
	registry, err := roots.OpenWithProvider(data, storageidentity.SystemProvider{}, base)
	if err != nil {
		t.Fatal(err)
	}
	old, err := registry.Add(context.Background(), "old", oldPath)
	if err != nil {
		t.Fatal(err)
	}
	target, err := registry.Add(context.Background(), "next", nextPath)
	if err != nil {
		t.Fatal(err)
	}
	service := rootmigration.New(registry)
	var buf bytes.Buffer
	control := rootControl{registry: registry, output: &buf, migration: service}
	request := rootControlRequest{
		SourceID: old.ID, SourceGen: old.Generation,
		TargetID: target.ID, TargetGen: target.Generation,
		RequestID: "native",
	}
	control.handle(context.Background(), rootCommand("migration-preview", request))
	response := controlResponse(t, &buf)
	if len(response["error"]) != 0 {
		t.Fatalf("preview failed: %s", response["error"])
	}
	var previewStatus rootmigration.Status
	if err := json.Unmarshal(response["result"], &previewStatus); err != nil || previewStatus.Phase != "previewing" {
		t.Fatalf("preview not accepted: %+v %v", previewStatus, err)
	}
	previewDeadline := time.After(15 * time.Second)
	for service.Status().Phase == "previewing" {
		select {
		case <-previewDeadline:
			t.Fatal("preview still scanning")
		case <-time.After(25 * time.Millisecond):
		}
	}
	previewStatus = service.Status()
	if previewStatus.Phase != "previewed" || previewStatus.Preview.FilesToCopy != 1 || !previewStatus.Preview.HasEnoughSpace {
		t.Fatalf("invalid preview: %+v", previewStatus)
	}
	control.handle(context.Background(), rootCommand("migration-start", request))
	response = controlResponse(t, &buf)
	if len(response["error"]) != 0 {
		t.Fatalf("start failed: %s", response["error"])
	}
	deadline := time.After(15 * time.Second)
	for service.Status().Phase == "running" {
		select {
		case <-deadline:
			t.Fatal("migration still running")
		case <-time.After(25 * time.Millisecond):
		}
	}
	control.handle(context.Background(), rootCommand("migration-status", rootControlRequest{RequestID: "status"}))
	response = controlResponse(t, &buf)
	var status rootmigration.Status
	if err := json.Unmarshal(response["result"], &status); err != nil || status.Phase != "completed" {
		t.Fatalf("migration status: %+v %v", status, err)
	}
	for _, location := range []string{filepath.Join(oldPath, "Photos", "picture.txt"), filepath.Join(nextPath, "Photos", "picture.txt")} {
		body, err := os.ReadFile(location)
		if err != nil || string(body) != "unchanged" {
			t.Fatalf("migration lost data at %s: %q %v", location, body, err)
		}
	}
}
