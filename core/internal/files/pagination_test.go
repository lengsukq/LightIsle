package files

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func newSortTestStore(t *testing.T) (*Store, string) {
	t.Helper()
	base := t.TempDir()
	s, err := Open(base)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s, base
}

func writeTestFile(t *testing.T, base, name string, size int, mod time.Time) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(base, name), make([]byte, size), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(filepath.Join(base, name), mod, mod); err != nil {
		t.Fatal(err)
	}
}

func TestPageSortedNameCompat(t *testing.T) {
	s, base := newSortTestStore(t)
	writeTestFile(t, base, "c.txt", 10, time.Unix(300, 0))
	writeTestFile(t, base, "a.txt", 30, time.Unix(100, 0))
	writeTestFile(t, base, "b.txt", 20, time.Unix(200, 0))

	entries, next, err := s.PageSorted(".", "", 2, SortName, false)
	if err != nil || len(entries) != 2 || entries[0].Name != "a.txt" || entries[1].Name != "b.txt" || next != "b.txt" {
		t.Fatalf("page1: %+v next=%q err=%v", entries, next, err)
	}
	entries, next, err = s.PageSorted(".", next, 2, SortName, false)
	if err != nil || len(entries) != 1 || entries[0].Name != "c.txt" || next != "" {
		t.Fatalf("page2: %+v next=%q err=%v", entries, next, err)
	}
	// The legacy Page must behave identically.
	legacy, legacyNext, err := s.Page(".", "", 2)
	if err != nil || legacyNext != "b.txt" || legacy[0].Name != "a.txt" {
		t.Fatalf("legacy: %+v %q %v", legacy, legacyNext, err)
	}
}

func TestPageSortedSizeAndMtime(t *testing.T) {
	s, base := newSortTestStore(t)
	baseTime := time.Unix(1000, 0)
	writeTestFile(t, base, "small.txt", 10, baseTime)
	writeTestFile(t, base, "large.txt", 300, baseTime.Add(time.Second))
	writeTestFile(t, base, "mid.txt", 20, baseTime.Add(-time.Second))
	// Same size as small, different name: the name tiebreaker must keep the
	// cursor stable across pages.
	writeTestFile(t, base, "small-2.txt", 10, baseTime)

	entries, next, err := s.PageSorted(".", "", 2, SortSize, false)
	if err != nil || len(entries) != 2 {
		t.Fatalf("size page1: %+v %v", entries, err)
	}
	if entries[0].Name != "small-2.txt" || entries[1].Name != "small.txt" {
		t.Fatalf("tiebreaker order: %+v", entries)
	}
	page2, next, err := s.PageSorted(".", next, 10, SortSize, false)
	if err != nil || len(page2) != 2 || page2[0].Name != "mid.txt" || page2[1].Name != "large.txt" || next != "" {
		t.Fatalf("size page2: %+v next=%q err=%v", page2, next, err)
	}
	// Descending mtime: newest first, composite cursor.
	entries, next, err = s.PageSorted(".", "", 1, SortModified, true)
	if err != nil || len(entries) != 1 || entries[0].Name != "large.txt" {
		t.Fatalf("mtime desc page1: %+v %v", entries, err)
	}
	page2, next, err = s.PageSorted(".", next, 10, SortModified, true)
	if err != nil || len(page2) != 3 || page2[0].Name != "small.txt" || page2[1].Name != "small-2.txt" || page2[2].Name != "mid.txt" || next != "" {
		t.Fatalf("mtime desc page2: %+v next=%q err=%v", page2, next, err)
	}
}

func TestPageSortedRejectsBadCursor(t *testing.T) {
	s, base := newSortTestStore(t)
	writeTestFile(t, base, "a.txt", 1, time.Unix(1, 0))
	// A composite cursor must carry the fixed-width numeric prefix.
	if _, _, err := s.PageSorted(".", "short", 10, SortSize, false); err == nil {
		t.Fatal("short composite cursor accepted")
	}
	// A cursor name component must still validate.
	if _, _, err := s.PageSorted(".", "00000000000000000000../escape", 10, SortSize, false); err == nil {
		t.Fatal("path traversal in composite cursor accepted")
	}
	if _, _, err := s.PageSorted(".", "a.txt", 10, SortSize, false); err == nil {
		t.Fatal("plain name cursor accepted for size sort")
	}
	if _, _, err := s.PageSorted(".", "", 10, "bogus", false); err == nil {
		t.Fatal("unknown sort key accepted")
	}
}

func TestPageSortedDescFirstPage(t *testing.T) {
	s, base := newSortTestStore(t)
	writeTestFile(t, base, "a.txt", 1, time.Unix(1, 0))
	writeTestFile(t, base, "b.txt", 1, time.Unix(2, 0))
	entries, _, err := s.PageSorted(".", "", 10, SortName, true)
	if err != nil || len(entries) != 2 || entries[0].Name != "b.txt" || entries[1].Name != "a.txt" {
		t.Fatalf("desc: %+v %v", entries, err)
	}
}
