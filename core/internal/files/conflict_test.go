package files

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func newConflictTestManager(t *testing.T) (*Manager, string) {
	t.Helper()
	base := t.TempDir()
	m, err := NewManager(base)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { m.Close() })
	// NewManager roots the store at <base>/SharedFiles.
	share := filepath.Join(base, "SharedFiles")
	if err := os.MkdirAll(share, 0o755); err != nil {
		t.Fatal(err)
	}
	return m, share
}

func TestMoveConflictRename(t *testing.T) {
	m, base := newConflictTestManager(t)
	if err := os.WriteFile(filepath.Join(base, "movie.txt"), []byte("src"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(base, "dir"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(base, "dir", "movie (2).txt"), []byte("taken"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(base, "dir", "movie.txt"), []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}
	// (2) is taken → the item lands on (3); original target stays untouched.
	final, skipped, err := m.MoveWithOptions("movie.txt", filepath.Join("dir", "movie.txt"), ConflictRename)
	if err != nil || skipped || final != filepath.Join("dir", "movie (3).txt") {
		t.Fatalf("rename: %q %v %v", final, skipped, err)
	}
	data, err := os.ReadFile(filepath.Join(base, "dir", "movie (3).txt"))
	if err != nil || string(data) != "src" {
		t.Fatalf("moved content: %q %v", data, err)
	}
	data, _ = os.ReadFile(filepath.Join(base, "dir", "movie.txt"))
	if string(data) != "old" {
		t.Fatal("existing target was modified")
	}
}

func TestMoveConflictSkipAndRefuse(t *testing.T) {
	m, base := newConflictTestManager(t)
	if err := os.WriteFile(filepath.Join(base, "a.txt"), []byte("src"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(base, "b"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(base, "b", "a.txt"), []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}
	final, skipped, err := m.MoveWithOptions("a.txt", filepath.Join("b", "a.txt"), ConflictSkip)
	if err != nil || !skipped || final != filepath.Join("b", "a.txt") {
		t.Fatalf("skip: %q %v %v", final, skipped, err)
	}
	if data, _ := os.ReadFile(filepath.Join(base, "b", "a.txt")); string(data) != "old" {
		t.Fatal("skip modified the target")
	}
	if _, _, err := m.MoveWithOptions("a.txt", filepath.Join("b", "a.txt"), ConflictRefuse); !errors.Is(err, ErrExists) {
		t.Fatalf("refuse error = %v", err)
	}
	if _, _, err := m.MoveWithOptions("a.txt", filepath.Join("b", "a.txt"), "bogus"); err == nil {
		t.Fatal("invalid policy accepted")
	}
}

func TestCopyConflictRename(t *testing.T) {
	m, base := newConflictTestManager(t)
	if err := os.WriteFile(filepath.Join(base, "doc.pdf"), []byte("content"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(base, "out"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(base, "out", "doc.pdf"), []byte("existing"), 0o600); err != nil {
		t.Fatal(err)
	}
	final, skipped, err := m.CopyContextWithOptions(context.Background(), "doc.pdf", filepath.Join("out", "doc.pdf"), ConflictRename)
	if err != nil || skipped || final != filepath.Join("out", "doc (2).pdf") {
		t.Fatalf("copy rename: %q %v %v", final, skipped, err)
	}
	if data, _ := os.ReadFile(filepath.Join(base, "out", "doc (2).pdf")); string(data) != "content" {
		t.Fatal("copy content mismatch")
	}
}

func TestNextRenameCandidate(t *testing.T) {
	if candidate, err := NextRenameCandidate("a/b.tar.gz", 2); err != nil || candidate != "a/b.tar (2).gz" {
		t.Fatalf("candidate: %q %v", candidate, err)
	}
	// Reserved internal names are never produced.
	if _, err := NextRenameCandidate(".lightisle-parts", 2); err == nil {
		t.Fatal("reserved candidate accepted")
	}
}
