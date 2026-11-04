package downloads

import (
	"errors"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestTaskUpdateFieldsAllowOnlyExplicitTaskStateColumns(t *testing.T) {
	sets, values, err := taskUpdateFields("status", StatusRunning, "gid", "test-gid", "total_bytes", int64(42))
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(sets, []string{"status=?", "gid=?", "total_bytes=?"}) {
		t.Fatalf("unexpected update fields: %v", sets)
	}
	if !reflect.DeepEqual(values, []any{StatusRunning, "test-gid", int64(42)}) {
		t.Fatalf("unexpected bind args: %v", values)
	}
}

func TestPolledProgressWritesOnlyChangesAndRejectsStaleEngine(t *testing.T) {
	dir := t.TempDir()
	store, err := files.Open(filepath.Join(dir, "share"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	m, err := New(testOptions(t, dir, store))
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	if _, err := m.db.Exec(`INSERT INTO download_tasks(id,owner,url,destination,status,gid,total_bytes,completed_bytes,created_at,updated_at)
		VALUES('poll',7,'https://example.invalid/file','dl','paused','current',100,10,1,1);
		CREATE TABLE update_count(n INTEGER);
		INSERT INTO update_count VALUES(0);
		CREATE TRIGGER count_task_updates AFTER UPDATE ON download_tasks BEGIN UPDATE update_count SET n=n+1; END`); err != nil {
		t.Fatal(err)
	}
	for range 5 {
		if err := m.updatePolledProgress("poll", "current", StatusPaused, 100, 10); err != nil {
			t.Fatal(err)
		}
	}
	var updates, updatedAt int64
	if err := m.db.QueryRow("SELECT n FROM update_count").Scan(&updates); err != nil || updates != 0 {
		t.Fatalf("idle writes=%d: %v", updates, err)
	}
	if err := m.db.QueryRow("SELECT updated_at FROM download_tasks WHERE id='poll'").Scan(&updatedAt); err != nil || updatedAt != 1 {
		t.Fatalf("idle timestamp=%d: %v", updatedAt, err)
	}
	if err := m.updatePolledProgress("poll", "current", StatusRunning, 100, 20); err != nil {
		t.Fatal(err)
	}
	if err := m.updatePolledProgress("poll", "old", StatusPaused, 100, 10); err != nil {
		t.Fatal(err)
	}
	if err := m.db.QueryRow("SELECT n FROM update_count").Scan(&updates); err != nil || updates != 1 {
		t.Fatalf("change/stale writes=%d: %v", updates, err)
	}
	if err := m.update("poll", "status", StatusCancelled); err != nil {
		t.Fatal(err)
	}
	if err := m.updatePolledProgress("poll", "current", StatusRunning, 100, 99); err != nil {
		t.Fatal(err)
	}
	task, _, err := m.rowByIDUnscoped("poll")
	if err != nil || task.Status != StatusCancelled || task.CompletedBytes != 20 {
		t.Fatalf("late poll revived task: %+v %v", task, err)
	}
}

func TestTaskUpdateFieldsRejectsUnscopedOrSQLIdentiferInputs(t *testing.T) {
	tests := []struct {
		name   string
		values []any
	}{
		{"empty update", nil},
		{"odd arguments", []any{"status"}},
		{"non-string column", []any{1, "value"}},
		{"owner mutation", []any{"owner", 999}},
		{"root mutation", []any{"root_binding", "{}"}},
		{"SQL statement injection", []any{"status=?, owner=999 --", StatusCompleted}},
		{"unsupported column", []any{"created_at", int64(1)}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, _, err := taskUpdateFields(test.values...)
			if !errors.Is(err, ErrInput) {
				t.Fatalf("expected ErrInput, got %v", err)
			}
		})
	}
}
