package pathutil

import (
	"os"
	"path/filepath"
	"testing"
)

func TestOverlap(t *testing.T) {
	if !Overlap("/a/b", "/a/b") {
		t.Fatal("identical paths should overlap")
	}
	if !Overlap("/a/b", "/a/b/c") || !Overlap("/a/b/c", "/a/b") {
		t.Fatal("parent/child paths should overlap")
	}
	if Overlap("/a/b", "/a/bc") {
		t.Fatal("sibling prefix paths must not overlap")
	}
}

func TestFileExistsRegular(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "sample.txt")
	if err := os.WriteFile(file, []byte("ok"), 0600); err != nil {
		t.Fatal(err)
	}
	if !FileExistsRegular(file) {
		t.Fatal("expected regular file to exist")
	}
	if FileExistsRegular(dir) {
		t.Fatal("directory must not report as regular file")
	}
	if FileExistsRegular(filepath.Join(dir, "missing.txt")) {
		t.Fatal("missing file must return false")
	}
}
