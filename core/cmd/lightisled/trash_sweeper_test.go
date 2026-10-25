package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/tasks"
)

func alertActive(t *testing.T, journal *tasks.Journal, code string) bool {
	t.Helper()
	alerts, err := journal.Alerts(true)
	if err != nil {
		t.Fatal(err)
	}
	for _, alert := range alerts {
		if alert.Code == code {
			return true
		}
	}
	return false
}

// A round with items that keep failing to purge must raise (or keep)
// trash_cleanup_failed; a later clean round clears it again.
func TestRunTrashSweepKeepsAlertOnStuckItems(t *testing.T) {
	dataDir := t.TempDir()
	m, err := files.NewManager(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	trashDir := filepath.Join(dataDir, "SharedFiles", files.Trash)
	if err := os.MkdirAll(trashDir, 0o700); err != nil {
		t.Fatal(err)
	}
	stale := time.Now().Add(-48 * time.Hour)
	entry := files.TrashEntry{
		ID:           fmt.Sprintf("%032x", 7),
		OriginalPath: "old/stuck.txt",
		Name:         "stuck.txt",
		DeletedAt:    stale.UTC(),
	}
	data, err := json.Marshal(entry)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(trashDir, entry.ID+".json"), data, 0o600); err != nil {
		t.Fatal(err)
	}
	content := filepath.Join(trashDir, entry.ID)
	inner := filepath.Join(content, "inner")
	if err := os.MkdirAll(inner, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(inner, "x.txt"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(inner, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(inner, 0o700) })

	journal, err := tasks.Open(filepath.Join(dataDir, "tasks"))
	if err != nil {
		t.Fatal(err)
	}
	defer journal.Close()
	retention := tasks.OpenRetentionStore(filepath.Join(dataDir, "retention.json"))
	if _, err := retention.Set(tasks.Retention{Enabled: true, Days: 1}); err != nil {
		t.Fatal(err)
	}

	runTrashSweep(m, retention, journal)
	if !alertActive(t, journal, "trash_cleanup_failed") {
		t.Fatal("stuck purge must keep trash_cleanup_failed raised")
	}
	runs, _, err := journal.History("trash", 0, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(runs) != 1 || runs[0].LastError != "trash_cleanup_partial_failure" {
		t.Fatalf("partial cleanup must remain visible in task history: %+v", runs)
	}

	// Unblock the item and run a clean round: the alert must clear.
	if err := os.Chmod(inner, 0o700); err != nil {
		t.Fatal(err)
	}
	runTrashSweep(m, retention, journal)
	if alertActive(t, journal, "trash_cleanup_failed") {
		t.Fatal("clean round must clear trash_cleanup_failed")
	}
	runs, _, err = journal.History("trash", 0, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(runs) != 2 || runs[0].LastError != "" {
		t.Fatalf("successful retry must be recorded separately: %+v", runs)
	}
}
