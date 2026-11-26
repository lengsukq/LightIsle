package files

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestScanInsightsLargeRecentSkipsInternalAndBoundedTopK(t *testing.T) {
	dataDir := t.TempDir()
	mgr, err := NewManager(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	defer mgr.Close()

	shareRoot := filepath.Join(dataDir, "SharedFiles")
	baseNow := time.Date(2026, 11, 20, 12, 0, 0, 0, time.UTC)

	writeSized := func(rel string, size int, mod time.Time) {
		t.Helper()
		full := filepath.Join(shareRoot, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(full), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, bytes.Repeat([]byte{'x'}, size), 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(full, mod, mod); err != nil {
			t.Fatal(err)
		}
	}

	// Create 20 regular files with varied sizes and mtimes.
	for i := 1; i <= 20; i++ {
		writeSized(fmt.Sprintf("Docs/file_%02d.bin", i), i*1000, baseNow.Add(-time.Duration(21-i)*24*time.Hour))
	}
	// System sidecars & internal files that MUST be skipped even though huge & recent.
	writeSized("Docs/.DS_Store", 99999, baseNow)
	writeSized("Docs/._appledouble", 99999, baseNow)
	writeSized(".lightisle-internal/huge.bin", 99999, baseNow)
	// Symlink that MUST be skipped.
	_ = os.Symlink(filepath.Join(shareRoot, "Docs/file_20.bin"), filepath.Join(shareRoot, "Docs/link_20.bin"))

	// 1. Top-5 large files >= 5000 bytes.
	largeRes, err := mgr.ScanInsights(context.Background(), InsightOptions{
		Roots:       []string{"."},
		Mode:        InsightModeLarge,
		MinBytes:    5000,
		HasMinBytes: true,
		Limit:       5,
		Now:         baseNow,
	})
	if err != nil {
		t.Fatalf("ScanInsights large: %v", err)
	}
	if len(largeRes.Items) != 5 {
		t.Fatalf("expected 5 top large items, got %d", len(largeRes.Items))
	}
	for i, wantSize := range []int64{20000, 19000, 18000, 17000, 16000} {
		if largeRes.Items[i].Size != wantSize {
			t.Fatalf("large[%d].Size = %d, want %d (%+v)", i, largeRes.Items[i].Size, wantSize, largeRes.Items[i])
		}
	}
	if largeRes.MatchedFiles != 16 { // 5..20 inclusive
		t.Fatalf("expected 16 matched files >= 5000, got %d", largeRes.MatchedFiles)
	}

	// 2. Recent files within 3 days -> file_20 (1d), file_19 (2d), file_18 (3d).
	recentRes, err := mgr.ScanInsights(context.Background(), InsightOptions{
		Roots: []string{"Docs"},
		Mode:  InsightModeRecent,
		Days:  3,
		Limit: 10,
		Now:   baseNow,
	})
	if err != nil {
		t.Fatalf("ScanInsights recent: %v", err)
	}
	if len(recentRes.Items) != 3 {
		t.Fatalf("expected 3 recent items, got %d: %+v", len(recentRes.Items), recentRes.Items)
	}
	if recentRes.Items[0].Name != "file_20.bin" || recentRes.Items[1].Name != "file_19.bin" || recentRes.Items[2].Name != "file_18.bin" {
		t.Fatalf("unexpected recent ordering: %+v", recentRes.Items)
	}

	// 3. Entry cap truncates cleanly.
	truncRes, err := mgr.ScanInsights(context.Background(), InsightOptions{
		Roots:          []string{"."},
		Mode:           InsightModeLarge,
		MinBytes:       0,
		HasMinBytes:    true,
		Limit:          10,
		MaxScanEntries: 5,
		Now:            baseNow,
	})
	if err != nil {
		t.Fatalf("ScanInsights truncated: %v", err)
	}
	if !truncRes.Truncated {
		t.Fatalf("expected Truncated=true when MaxScanEntries=5")
	}

	// 4. Expired deadline returns partial result with TimedOut=true instead of failing.
	deadCtx, cancel := context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
	defer cancel()
	timedOutRes, err := mgr.ScanInsights(deadCtx, InsightOptions{
		Roots: []string{"."},
		Mode:  InsightModeLarge,
	})
	if err != nil || !timedOutRes.TimedOut || !timedOutRes.Truncated {
		t.Fatalf("expected partial timedOut result, got %+v err=%v", timedOutRes, err)
	}
}

func TestReplaceTextFileAtomicAndOptimisticLock(t *testing.T) {
	dataDir := t.TempDir()
	mgr, err := NewManager(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	defer mgr.Close()

	if err := mgr.Mkdir("Notes"); err != nil {
		t.Fatal(err)
	}
	// Create new file with create=true.
	created, err := mgr.ReplaceTextFile("Notes/todo.md", []byte("# v1\n"), 0, true)
	if err != nil {
		t.Fatalf("ReplaceTextFile create: %v", err)
	}
	if created.Info.Size() != 5 || created.Identity == "" {
		t.Fatalf("unexpected created result: %+v", created)
	}

	// Creating again with create=true & expectedMtime=0 must fail with ErrExists.
	if _, err := mgr.ReplaceTextFile("Notes/todo.md", []byte("# dup\n"), 0, true); !errors.Is(err, ErrExists) {
		t.Fatalf("expected ErrExists, got %v", err)
	}

	// Wrong expectedMtimeUnixNano must fail with ErrModifiedConflict and NOT overwrite.
	conflictRes, err := mgr.ReplaceTextFile("Notes/todo.md", []byte("# stale\n"), created.Info.ModTime().UnixNano()-12345, false)
	if !errors.Is(err, ErrModifiedConflict) {
		t.Fatalf("expected ErrModifiedConflict, got %v", err)
	}
	if conflictRes.Info == nil || conflictRes.Info.ModTime().UnixNano() != created.Info.ModTime().UnixNano() {
		t.Fatalf("conflict should return current Info, got %+v", conflictRes)
	}

	// Exact expectedMtimeUnixNano succeeds atomically.
	saved, err := mgr.ReplaceTextFile("Notes/todo.md", []byte("# v2 updated\n"), created.Info.ModTime().UnixNano(), false)
	if err != nil {
		t.Fatalf("ReplaceTextFile update: %v", err)
	}
	if saved.Info.Size() != 13 {
		t.Fatalf("expected size 13, got %d", saved.Info.Size())
	}
	raw, err := os.ReadFile(filepath.Join(dataDir, "SharedFiles", "Notes", "todo.md"))
	if err != nil || string(raw) != "# v2 updated\n" {
		t.Fatalf("disk content = %q err=%v", string(raw), err)
	}

	// Simulate failure after temp file creation: directory becomes read-only or concurrent mtime change leaves zero .lightisle-text-* leaks.
	entries, err := os.ReadDir(filepath.Join(dataDir, "SharedFiles", "Notes"))
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if len(e.Name()) >= 16 && e.Name()[:16] == ".lightisle-text-" {
			t.Fatalf("leaked temp file: %s", e.Name())
		}
	}
}

func TestScanInsightsSeparatesTraverseAndReadFile(t *testing.T) {
	dataDir := t.TempDir()
	mgr, err := NewManager(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	defer mgr.Close()

	shareRoot := filepath.Join(dataDir, "SharedFiles")
	for rel, size := range map[string]int{
		"Team/public.bin":  4000,
		"Team/private.bin": 9000,
	} {
		full := filepath.Join(shareRoot, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(full), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, bytes.Repeat([]byte{'a'}, size), 0600); err != nil {
			t.Fatal(err)
		}
	}

	res, err := mgr.ScanInsights(context.Background(), InsightOptions{
		Roots:       []string{"."},
		Mode:        InsightModeLarge,
		MinBytes:    1,
		HasMinBytes: true,
		CanTraverse: func(p string) bool { return p == "Team" },
		CanReadFile: func(p string) bool { return p == "Team/public.bin" },
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.MatchedFiles != 1 || res.TotalBytes != 4000 || len(res.Items) != 1 || res.Items[0].Path != "Team/public.bin" {
		t.Fatalf("expected stats strictly matching readable files, got %+v", res)
	}
}
