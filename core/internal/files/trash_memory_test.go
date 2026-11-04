package files

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/sys/unix"
)

func TestTrashJournalRejectsOversizeAndSpecialFilesWithoutTouchingContents(t *testing.T) {
	for _, kind := range []string{"oversize", "symlink", "fifo"} {
		t.Run(kind, func(t *testing.T) {
			root := t.TempDir()
			s, err := Open(root)
			if err != nil {
				t.Fatal(err)
			}
			defer s.Close()
			if err := os.WriteFile(filepath.Join(root, "original.txt"), []byte("keep original"), 0600); err != nil {
				t.Fatal(err)
			}
			if err := s.MoveToTrash("original.txt"); err != nil {
				t.Fatal(err)
			}
			entries, err := s.TrashList()
			if err != nil || len(entries) != 1 {
				t.Fatalf("initial trash: %v %v", entries, err)
			}
			entry := entries[0]
			journal := filepath.Join(root, Trash, entry.ID+".json")
			if err := os.Remove(journal); err != nil {
				t.Fatal(err)
			}
			switch kind {
			case "oversize":
				f, err := os.Create(journal)
				if err != nil {
					t.Fatal(err)
				}
				err = f.Truncate(1 << 30) // sparse; no large buffer or media fixture
				f.Close()
				if err != nil {
					t.Fatal(err)
				}
			case "symlink":
				if err := os.Symlink(entry.ID, journal); err != nil {
					t.Fatal(err)
				}
			case "fifo":
				if err := unix.Mkfifo(journal, 0600); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := s.TrashInfo(entry.ID); err == nil {
				t.Fatal("invalid journal accepted")
			}
			if err := s.Restore(entry.ID); err == nil {
				t.Fatal("invalid journal restored")
			}
			entries, err = s.TrashList()
			if err != nil || len(entries) != 0 {
				t.Fatalf("invalid journal listed: %v %v", entries, err)
			}
			if data, err := os.ReadFile(filepath.Join(root, Trash, entry.ID)); err != nil || string(data) != "keep original" {
				t.Fatalf("original touched: %q %v", data, err)
			}
			if _, err := os.Stat(filepath.Join(root, "original.txt")); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("unexpected restore: %v", err)
			}
		})
	}
}
