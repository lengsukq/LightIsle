package tasks

import (
	"errors"
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
}
