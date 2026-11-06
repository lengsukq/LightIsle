//go:build darwin

package files

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestRemoveEmptyDirectoryNeverRemovesContentsOrLinks(t *testing.T) {
	dir := t.TempDir()
	root, err := os.OpenRoot(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	manager, err := NewPinnedManager(root)
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()
	if err := os.Mkdir(filepath.Join(dir, "album"), 0700); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(dir, "album", "photo.jpg")
	if err := os.WriteFile(file, []byte("original"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := manager.RemoveEmptyDirectory("album"); !errors.Is(err, ErrDirectoryNotEmpty) {
		t.Fatalf("nonempty removal: %v", err)
	}
	if data, err := os.ReadFile(file); err != nil || string(data) != "original" {
		t.Fatalf("file harmed: %q %v", data, err)
	}
	if err := os.Remove(file); err != nil {
		t.Fatal(err)
	}
	if err := manager.RemoveEmptyDirectory("album"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "album")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("empty album still present: %v", err)
	}
	if err := os.Mkdir(filepath.Join(dir, "target"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("target", filepath.Join(dir, "link")); err != nil {
		t.Fatal(err)
	}
	if err := manager.RemoveEmptyDirectory("link"); err == nil {
		t.Fatal("removed symlink")
	}
	if _, err := os.Stat(filepath.Join(dir, "target")); err != nil {
		t.Fatalf("symlink target affected: %v", err)
	}
}
