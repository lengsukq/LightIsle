package backup

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestMetadataReadRejectsReplacementAndOversizedReceipt(t *testing.T) {
	dir := t.TempDir()
	const name = "receipt.json"
	target := filepath.Join(dir, name)
	if err := os.WriteFile(target, []byte("original"), 0600); err != nil {
		t.Fatal(err)
	}
	root, err := os.OpenRoot(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	info, err := root.Lstat(name)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(target, filepath.Join(dir, "old")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, []byte("replaced"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := readRootFileWithIdentity(root, name, 256<<10, info); !errors.Is(err, ErrInvalid) {
		t.Fatalf("replacement read after identity check: %v", err)
	}
	if err := os.Truncate(target, (256<<10)+1); err != nil {
		t.Fatal(err)
	}
	if _, err := readRootFileBounded(root, name, 256<<10); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("oversized receipt accepted: %v", err)
	}
}
