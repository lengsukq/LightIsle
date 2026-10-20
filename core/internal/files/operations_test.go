package files

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestMoveCopySearchPurge(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "share"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if err = s.Mkdir("photos"); err != nil {
		t.Fatal(err)
	}
	if _, err = s.Upload("photos/a.txt", bytes.NewBufferString("original")); err != nil {
		t.Fatal(err)
	}
	if err = s.Copy("photos/a.txt", "photos/b.txt"); err != nil {
		t.Fatal(err)
	}
	if err = s.Copy("photos/a.txt", "photos/b.txt"); !errors.Is(err, ErrExists) {
		t.Fatalf("overwrite allowed %v", err)
	}
	if err = s.Move("photos/b.txt", "photos/c.txt"); err != nil {
		t.Fatal(err)
	}
	f, _, err := s.Read("photos/c.txt")
	if err != nil {
		t.Fatal(err)
	}
	data := make([]byte, 8)
	_, _ = f.Read(data)
	f.Close()
	if string(data) != "original" {
		t.Fatalf("copy data mismatch %q", data)
	}
	found, _, err := s.Search(".", "c.txt", 10)
	if err != nil || len(found) != 1 {
		t.Fatalf("search %+v %v", found, err)
	}
	if err = s.Move("photos", "photos/sub"); !errors.Is(err, ErrPath) {
		t.Fatalf("self nesting allowed: %v", err)
	}
	if err = s.Move("photos/c.txt", "photos/a.txt"); !errors.Is(err, ErrExists) {
		t.Fatalf("move overwrite allowed: %v", err)
	}
	if err = s.MoveToTrash("photos/c.txt"); err != nil {
		t.Fatal(err)
	}
	items, err := s.TrashList()
	if err != nil || len(items) != 1 {
		t.Fatalf("trash %+v %v", items, err)
	}
	if err = s.Purge(items[0].ID); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.Read("photos/c.txt"); !os.IsNotExist(err) {
		t.Fatalf("purged file remains %v", err)
	}
}
