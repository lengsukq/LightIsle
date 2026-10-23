package backup

import (
	"context"
	"database/sql"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/tasks"
	_ "github.com/mattn/go-sqlite3"
)

func TestTaskMetadataBackupRestoreNormalizesActiveRunsAndMigratesLegacyDB(t *testing.T) {
	t.Run("current schema preserves completed history and omits active runs", func(t *testing.T) {
		dataDir := t.TempDir()
		manager, err := files.NewManager(dataDir)
		if err != nil {
			t.Fatal(err)
		}
		defer manager.Close()
		journal, err := tasks.Open(dataDir)
		if err != nil {
			t.Fatal(err)
		}
		defer journal.Close()

		if err := journal.Start("gallery", "scan"); err != nil {
			t.Fatal(err)
		}
		if err := journal.Progress("gallery", 5, 50); err != nil {
			t.Fatal(err)
		}
		if err := journal.Finish("gallery", nil); err != nil {
			t.Fatal(err)
		}
		if err := journal.Start("gallery", "scan"); err != nil {
			t.Fatal(err)
		}
		if err := journal.Progress("gallery", 17, 170); err != nil {
			t.Fatal(err)
		}
		if err := journal.Start("cinema", "scan"); err != nil {
			t.Fatal(err)
		}
		if err := journal.Progress("cinema", 4, 40); err != nil {
			t.Fatal(err)
		}

		service := New(manager, dataDir)
		service.SetJournal(journal)
		defer service.Close()
		restoredMetadata := backupAndRestoreMetadata(t, service)

		recovered, err := tasks.Open(restoredMetadata)
		if err != nil {
			t.Fatal(err)
		}
		defer recovered.Close()
		runs, next, err := recovered.History("", 0, 100)
		if err != nil || next != 0 || len(runs) != 1 {
			t.Fatalf("restored history: runs=%+v next=%d err=%v", runs, next, err)
		}
		if runs[0].Kind != "gallery" || runs[0].Running || runs[0].LastError != "" ||
			runs[0].Progress != 5 || runs[0].Bytes != 50 || runs[0].Attempts != 1 {
			t.Fatalf("completed history was not preserved: %+v", runs[0])
		}

		states, err := recovered.List()
		if err != nil {
			t.Fatal(err)
		}
		byKind := make(map[string]tasks.State, len(states))
		for _, state := range states {
			byKind[state.Kind] = state
		}
		for _, item := range []struct {
			kind     string
			attempts int64
		}{
			{kind: "gallery", attempts: 2},
			{kind: "cinema", attempts: 1},
			{kind: "backup", attempts: 1},
		} {
			state, ok := byKind[item.kind]
			if !ok || state.Running || state.Processed != 0 || state.Bytes != 0 || state.StartedAt != 0 ||
				state.LastDone != 0 || state.LastError != "in_progress_not_restored_from_backup" || state.Attempts != item.attempts {
				t.Errorf("active %s summary was not normalized: %+v present=%v", item.kind, state, ok)
			}
		}
	})

	t.Run("legacy schema creates empty history without inventing runs", func(t *testing.T) {
		dataDir := t.TempDir()
		if err := os.MkdirAll(dataDir, 0700); err != nil {
			t.Fatal(err)
		}
		legacyPath := filepath.Join(dataDir, "tasks.sqlite")
		db, err := sql.Open("sqlite3", legacyPath)
		if err != nil {
			t.Fatal(err)
		}
		_, err = db.Exec(`CREATE TABLE task_journal (
			kind TEXT PRIMARY KEY, operation TEXT NOT NULL, running INTEGER NOT NULL,
			processed INTEGER NOT NULL DEFAULT 0, bytes INTEGER NOT NULL DEFAULT 0,
			started_at INTEGER NOT NULL DEFAULT 0, last_done INTEGER NOT NULL DEFAULT 0,
			last_error TEXT NOT NULL DEFAULT '', attempts INTEGER NOT NULL DEFAULT 0)`)
		if err == nil {
			_, err = db.Exec(`INSERT INTO task_journal(kind,operation,running,processed,bytes,started_at,last_done,last_error,attempts)
				VALUES('gallery','scan',1,17,200,123,0,'',7)`)
		}
		if err != nil {
			db.Close()
			t.Fatal(err)
		}
		if err := db.Close(); err != nil {
			t.Fatal(err)
		}

		manager, err := files.NewManager(dataDir)
		if err != nil {
			t.Fatal(err)
		}
		defer manager.Close()
		service := New(manager, dataDir)
		defer service.Close()
		restoredMetadata := backupAndRestoreMetadata(t, service)

		recovered, err := tasks.Open(restoredMetadata)
		if err != nil {
			t.Fatal(err)
		}
		defer recovered.Close()
		runs, _, err := recovered.History("", 0, 100)
		if err != nil || len(runs) != 0 {
			t.Fatalf("legacy migration fabricated history: %+v %v", runs, err)
		}
		states, err := recovered.List()
		if err != nil || len(states) != 1 {
			t.Fatalf("legacy summary after Open: %+v %v", states, err)
		}
		state := states[0]
		if state.Kind != "gallery" || state.Running || state.Processed != 0 || state.Bytes != 0 ||
			state.StartedAt != 0 || state.LastDone != 0 || state.LastError != "in_progress_not_restored_from_backup" || state.Attempts != 7 {
			t.Fatalf("legacy running summary was not normalized: %+v", state)
		}
	})
}

func backupAndRestoreMetadata(t *testing.T, service *Service) string {
	t.Helper()
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	destination, err := os.MkdirTemp(home, "lightisle-task-metadata-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(destination) })
	if err := service.StartBackup(destination); err != nil {
		t.Fatal(err)
	}
	created := await(t, service)
	if created.LastError != "" || created.LastSnapshot == "" {
		t.Fatalf("backup failed: %+v", created)
	}
	if err := service.StartRestore(created.LastSnapshot); err != nil {
		t.Fatal(err)
	}
	restored := await(t, service)
	if restored.LastError != "" || restored.RestoredMetadata == "" {
		t.Fatalf("restore failed: %+v", restored)
	}
	return restored.RestoredMetadata
}

func TestBackupJournalWriteErrorsAreVisibleInStatus(t *testing.T) {
	base := t.TempDir()
	manager, err := files.NewManager(base)
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()
	journal, err := tasks.Open(filepath.Join(base, "data"))
	if err != nil {
		t.Fatal(err)
	}
	defer journal.Close()

	service := New(manager)
	service.SetJournal(journal)
	defer service.Close()
	started := make(chan struct{})
	release := make(chan struct{})
	if err := service.start("backup", "synthetic", func(context.Context, string) (string, error) {
		close(started)
		<-release
		return "synthetic-snapshot", nil
	}); err != nil {
		t.Fatal(err)
	}
	<-started

	journalDB, err := sql.Open("sqlite3", filepath.Join(base, "data", "tasks.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	_, err = journalDB.Exec(`CREATE TRIGGER reject_progress BEFORE UPDATE OF progress ON task_runs
		BEGIN SELECT RAISE(ABORT, 'injected_progress_failure'); END`)
	if err == nil {
		_, err = journalDB.Exec(`CREATE TRIGGER reject_finish BEFORE UPDATE OF running ON task_runs
			WHEN OLD.running=1 AND NEW.running=0
			BEGIN SELECT RAISE(ABORT, 'injected_finish_failure'); END`)
	}
	closeErr := journalDB.Close()
	if err != nil {
		t.Fatal(err)
	}
	if closeErr != nil {
		t.Fatal(closeErr)
	}

	service.progress(32, 1024)
	close(release)
	finished := await(t, service)
	if finished.LastSnapshot != "synthetic-snapshot" ||
		!strings.Contains(finished.LastError, "task_journal_progress_failed") ||
		!strings.Contains(finished.LastError, "task_journal_finish_failed") {
		t.Fatalf("journal persistence failure was hidden by successful work: %+v", finished)
	}
}
