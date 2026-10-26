package backup

import (
	"context"
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
	_ "github.com/mattn/go-sqlite3"
)

func TestMetadataOnlyBackupAndRestoreNeverCopiesSharedFiles(t *testing.T) {
	shareDir := t.TempDir()
	dataDir := t.TempDir()
	manager, err := files.NewManager(shareDir)
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()
	if err := os.Mkdir(filepath.Join(shareDir, "videos"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(shareDir, "videos", "original.mkv"), []byte("not-a-backup"), 0600); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite3", filepath.Join(dataDir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec("CREATE TABLE users (name TEXT); INSERT INTO users VALUES('owner')"); err != nil {
		t.Fatal(err)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	destination, err := os.MkdirTemp(home, "lightisle-metadata-only-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(destination)
	service := New(manager, dataDir)
	defer service.Close()

	if err := service.StartMetadataBackup(destination); err != nil {
		t.Fatal(err)
	}
	completed := await(t, service)
	if completed.LastError != "" || completed.LastSnapshot == "" {
		t.Fatalf("backup failed: %+v", completed)
	}
	manifestRoot, err := os.OpenRoot(completed.LastSnapshot)
	if err != nil {
		t.Fatal(err)
	}
	manifest, err := parseManifest(manifestRoot)
	manifestRoot.Close()
	if err != nil || manifest.BackupType != MetadataBackupType || len(manifest.Files) != 0 ||
		len(manifest.Dirs) != 0 || len(manifest.Metadata) != 1 {
		t.Fatalf("not a metadata-only snapshot: %+v %v", manifest, err)
	}
	if _, err := os.Stat(filepath.Join(completed.LastSnapshot, "data")); !os.IsNotExist(err) {
		t.Fatalf("shared data unexpectedly present: %v", err)
	}
	verified, err := VerifySnapshot(context.Background(), completed.LastSnapshot)
	if err != nil || !verified.Verified || verified.Files != 0 || verified.MetadataFiles != 1 {
		t.Fatalf("metadata-only integrity check failed: %+v %v", verified, err)
	}
	listed, err := service.ListSnapshots(context.Background(), destination)
	if err != nil || len(listed.Snapshots) != 1 || listed.Snapshots[0].BackupType != MetadataBackupType {
		t.Fatalf("metadata snapshot inventory failed: %+v %v", listed, err)
	}
	if err := service.StartRestore(completed.LastSnapshot); err != nil {
		t.Fatal(err)
	}
	restored := await(t, service)
	if restored.LastError != "" || restored.RestoredMetadata == "" {
		t.Fatalf("restore failed: %+v", restored)
	}
	entries, err := os.ReadDir(shareDir)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if len(entry.Name()) >= len("LightIsle-Restored-") && entry.Name()[:len("LightIsle-Restored-")] == "LightIsle-Restored-" {
			t.Fatalf("metadata-only restore created a shared-file recovery folder: %s", entry.Name())
		}
	}
	var count int
	recovered, err := sql.Open("sqlite3", filepath.Join(restored.RestoredMetadata, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer recovered.Close()
	if err := recovered.QueryRow("SELECT count(*) FROM users").Scan(&count); err != nil || count != 1 {
		t.Fatalf("staged metadata was not restored: %d %v", count, err)
	}
	content, err := os.ReadFile(filepath.Join(shareDir, "videos", "original.mkv"))
	if err != nil || string(content) != "not-a-backup" {
		t.Fatalf("original media changed: %q %v", content, err)
	}
}

func TestMetadataWeeklyScheduleKeepsFiveAndDoesNotDeleteLegacyCompleteSnapshot(t *testing.T) {
	shareDir := t.TempDir()
	dataDir := t.TempDir()
	manager, err := files.NewManager(shareDir)
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()
	root, online := manager.State()
	if !online {
		t.Fatal("share root is offline")
	}
	if err := os.WriteFile(filepath.Join(root, "important.jpg"), []byte("photo"), 0600); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite3", filepath.Join(dataDir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec("CREATE TABLE users (name TEXT); INSERT INTO users VALUES('owner')"); err != nil {
		t.Fatal(err)
	}
	db.Close()
	home, _ := os.UserHomeDir()
	destination, err := os.MkdirTemp(home, "lightisle-weekly-five-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(destination)
	service := New(manager, dataDir)
	defer service.Close()
	schedule, err := NewScheduler(service, dataDir)
	if err != nil {
		t.Fatal(err)
	}
	defer schedule.Close()
	if err := schedule.ConfigureWithRetention(destination, 168, 5); err != nil {
		t.Fatal(err)
	}
	oldPlanID := schedule.Status().PlanID
	schedule.runDue(time.Unix(schedule.Status().NextRun+1, 0))
	oldBackup := await(t, service)
	if oldBackup.LastError != "" {
		t.Fatalf("legacy backup failed: %+v", oldBackup)
	}
	legacySnapshot := oldBackup.LastSnapshot
	if err := schedule.ConfigureMetadataWeekly(destination, 5); err != nil {
		t.Fatal(err)
	}
	plan := schedule.Status()
	if plan.BackupType != MetadataBackupType || plan.EveryHours != 168 || plan.RetentionCount != 5 ||
		plan.PlanID == oldPlanID || !plan.Enabled {
		t.Fatalf("metadata plan replaced legacy plan incorrectly: %+v", plan)
	}
	for i := 0; i < 6; i++ {
		schedule.runDue(time.Unix(schedule.Status().NextRun+1, 0))
		st := await(t, service)
		if st.LastError != "" || st.LastSnapshot == "" {
			t.Fatalf("scheduled metadata attempt %d failed: %+v", i, st)
		}
	}
	if _, err := os.Stat(legacySnapshot); err != nil {
		t.Fatalf("switching plan deleted old complete backup: %v", err)
	}
	items, err := service.ListSnapshots(context.Background(), destination)
	if err != nil {
		t.Fatal(err)
	}
	metadata := 0
	complete := 0
	for _, record := range items.Snapshots {
		if record.Integrity != "not_verified" {
			t.Fatalf("invalid inventory entry: %+v", record)
		}
		if record.BackupType == MetadataBackupType {
			metadata++
		} else {
			complete++
		}
	}
	if metadata != 5 || complete != 1 {
		t.Fatalf("retention should keep five config backups and the legacy snapshot: metadata=%d complete=%d", metadata, complete)
	}
}

func TestMetadataOnlyManifestRejectsFilePayload(t *testing.T) {
	manifest := Manifest{Format: format, BackupType: MetadataBackupType, Created: 10, Source: "Root",
		Files:    []File{{Path: "movie.mkv", Size: 0, SHA256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}},
		Metadata: []File{{Path: "accounts.sqlite", Size: 0, SHA256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}
	if err := validateInventoryManifest(manifest); err == nil {
		t.Fatal("metadata backup containing shared files was accepted")
	}
	manifest.Files = nil
	if err := validateInventoryManifest(manifest); err != nil {
		t.Fatal(err)
	}
	manifest.Metadata = []File{{Path: "backup-schedule.json", Size: 0, SHA256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}
	if err := validateInventoryManifest(manifest); err == nil {
		t.Fatal("metadata-only snapshot without accounts.sqlite was accepted")
	}
	manifest.Metadata[0].Path = "accounts.sqlite"
	encoded, _ := json.Marshal(manifest)
	if !json.Valid(encoded) {
		t.Fatal("invalid manifest JSON")
	}
}
