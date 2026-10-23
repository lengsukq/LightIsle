package tasks

import (
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestJournalCrashMarksInterruptedAndKeepsHistory(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "data")
	first, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := first.Start("cinema", "scan"); err != nil {
		t.Fatal(err)
	}
	if err := first.Start("cinema", "scan"); !errors.Is(err, ErrRunning) {
		t.Fatalf("duplicated scan: %v", err)
	}
	if err := first.Progress("cinema", 120, 123456); err != nil {
		t.Fatal(err)
	}
	if err := first.Close(); err != nil {
		t.Fatal(err)
	}
	restarted, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer restarted.Close()
	all, err := restarted.List()
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 1 || all[0].Running || all[0].LastError != "interrupted_by_restart" || all[0].Processed != 120 {
		t.Fatalf("crash recovery state: %+v", all)
	}
	runs, _, err := restarted.History("", 0, 20)
	if err != nil || len(runs) != 1 || runs[0].Running || runs[0].LastError != "interrupted_by_restart" || runs[0].Progress != 120 {
		t.Fatalf("crash recovery history: %+v %v", runs, err)
	}
	if err := restarted.Start("cinema", "scan"); err != nil {
		t.Fatal(err)
	}
	if err := restarted.Progress("cinema", 250, 500); err != nil {
		t.Fatal(err)
	}
	if err := restarted.Finish("cinema", nil); err != nil {
		t.Fatal(err)
	}
	all, err = restarted.List()
	if err != nil || len(all) != 1 || all[0].LastError != "" || all[0].Running || all[0].Attempts != 2 || all[0].Processed != 250 {
		t.Fatalf("retry not persisted: %+v %v", all, err)
	}
	runs, _, err = restarted.History("cinema", 0, 20)
	if err != nil || len(runs) != 2 || runs[0].Attempts != 2 || runs[0].Progress != 250 || runs[0].LastError != "" ||
		runs[1].Attempts != 1 || runs[1].LastError != "interrupted_by_restart" || runs[1].Progress != 120 {
		t.Fatalf("retry history lost an attempt: %+v %v", runs, err)
	}
}

func TestJournalHistoryCursorAndKindFilter(t *testing.T) {
	j, err := Open(filepath.Join(t.TempDir(), "data"))
	if err != nil {
		t.Fatal(err)
	}
	defer j.Close()
	for _, item := range []struct{ kind, operation string }{
		{"gallery", "scan"}, {"cinema", "scan"}, {"gallery", "reconcile"}, {"backup", "backup"}, {"gallery", "scan"},
	} {
		if err := j.Start(item.kind, item.operation); err != nil {
			t.Fatal(err)
		}
		if err := j.Finish(item.kind, nil); err != nil {
			t.Fatal(err)
		}
	}
	first, cursor, err := j.History("", 0, 2)
	if err != nil || len(first) != 2 || cursor != first[1].ID || first[0].ID <= first[1].ID {
		t.Fatalf("first history page: %+v cursor=%d err=%v", first, cursor, err)
	}
	second, next, err := j.History("", cursor, 2)
	if err != nil || len(second) != 2 || second[0].ID >= first[1].ID || next != second[1].ID {
		t.Fatalf("second history page: %+v cursor=%d err=%v", second, next, err)
	}
	third, next, err := j.History("", next, 2)
	if err != nil || len(third) != 1 || next != 0 {
		t.Fatalf("final history page: %+v cursor=%d err=%v", third, next, err)
	}
	filtered, next, err := j.History("gallery", 0, 100)
	if err != nil || len(filtered) != 3 || next != 0 {
		t.Fatalf("filtered history: %+v cursor=%d err=%v", filtered, next, err)
	}
	if _, _, err := j.History("unknown", 0, 20); err == nil {
		t.Fatal("unknown task kind accepted")
	}
	if _, _, err := j.History("", 0, 101); err == nil {
		t.Fatal("oversized history page accepted")
	}
}

func TestJournalHistoryMigrationDoesNotInventPastRuns(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "data")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite3", "file:"+filepath.Join(dir, "tasks.sqlite"))
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
			VALUES('gallery','scan',1,17,2048,123,0,'',7)`)
	}
	if err != nil {
		db.Close()
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	j, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer j.Close()
	state, err := j.List()
	if err != nil || len(state) != 1 || state[0].Running || state[0].Attempts != 7 || state[0].LastError != "interrupted_by_restart" {
		t.Fatalf("legacy summary migration: %+v %v", state, err)
	}
	runs, _, err := j.History("", 0, 20)
	if err != nil || len(runs) != 0 {
		t.Fatalf("migration fabricated run history: %+v %v", runs, err)
	}
	if err := j.Start("gallery", "scan"); err != nil {
		t.Fatal(err)
	}
	runs, _, err = j.History("gallery", 0, 20)
	if err != nil || len(runs) != 1 || runs[0].Attempts != 8 || !runs[0].Running {
		t.Fatalf("new history after migration: %+v %v", runs, err)
	}
}

func TestJournalHistoryKeepsAtMostGlobalLimit(t *testing.T) {
	j, err := Open(filepath.Join(t.TempDir(), "data"))
	if err != nil {
		t.Fatal(err)
	}
	defer j.Close()
	for i := 0; i < maxHistoryRows+1; i++ {
		if err := j.Start("gallery", "scan"); err != nil {
			t.Fatalf("start %d: %v", i, err)
		}
		if err := j.Finish("gallery", nil); err != nil {
			t.Fatalf("finish %d: %v", i, err)
		}
	}
	rows, err := j.db.Query("SELECT COUNT(*) FROM task_runs")
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	if !rows.Next() {
		t.Fatal("missing history count")
	}
	var count int
	if err := rows.Scan(&count); err != nil || count != maxHistoryRows {
		t.Fatalf("retained %d history rows, err=%v", count, err)
	}
}
