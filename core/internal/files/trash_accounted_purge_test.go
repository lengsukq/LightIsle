package files

import (
	"errors"
	"os"
	"path"
	"path/filepath"
	"testing"
)

func TestAccountedTrashPurgeInspectsOriginalBeforeCommit(t *testing.T) {
	for _, directory := range []bool{false, true} {
		name, file := "file", "file"
		if directory {
			name, file = "folder", "folder/nested/file"
		}
		t.Run(name, func(t *testing.T) {
			root := t.TempDir()
			s, err := Open(root)
			if err != nil {
				t.Fatal(err)
			}
			defer s.Close()
			if err := os.MkdirAll(filepath.Dir(filepath.Join(root, file)), 0700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(root, file), []byte("data"), 0600); err != nil {
				t.Fatal(err)
			}
			info, err := os.Stat(filepath.Join(root, file))
			if err != nil {
				t.Fatal(err)
			}
			want := MediaFileIdentity(info)
			if err := s.MoveToTrash(name); err != nil {
				t.Fatal(err)
			}
			entries, err := s.TrashList()
			if err != nil || len(entries) != 1 {
				t.Fatalf("trash: %+v %v", entries, err)
			}
			id := entries[0].ID
			committed := false
			err = s.PurgeWithAccounting(id, func(entry TrashEntry, inspect func(string) (TrashFileInspection, error)) (func() error, error) {
				relative := "."
				if directory {
					relative = "nested/file"
				}
				found, err := inspect(relative)
				if err != nil || found.Identity != want || found.Size != 4 {
					t.Fatalf("inspect: %+v %v", found, err)
				}
				return func() error {
					if _, err := s.root.Lstat(path.Join(Trash, id)); !errors.Is(err, os.ErrNotExist) {
						t.Fatalf("commit before deletion: %v", err)
					}
					committed = true
					return nil
				}, nil
			})
			if err != nil || !committed {
				t.Fatalf("purge: %v, committed %v", err, committed)
			}
			if _, err := s.root.Lstat(path.Join(Trash, id+".json")); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("journal remains: %v", err)
			}
		})
	}
}

func TestAccountedTrashPurgeRejectsReplacedNestedFileAndSymlink(t *testing.T) {
	for _, symlink := range []bool{false, true} {
		name := "replacement"
		if symlink {
			name = "symlink"
		}
		t.Run(name, func(t *testing.T) {
			root := t.TempDir()
			s, err := Open(root)
			if err != nil {
				t.Fatal(err)
			}
			defer s.Close()
			if err := os.Mkdir(filepath.Join(root, "folder"), 0700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(root, "folder", "file"), []byte("original"), 0600); err != nil {
				t.Fatal(err)
			}
			if err := s.MoveToTrash("folder"); err != nil {
				t.Fatal(err)
			}
			items, err := s.TrashList()
			if err != nil || len(items) != 1 {
				t.Fatalf("trash: %+v %v", items, err)
			}
			id := items[0].ID
			file := filepath.Join(root, Trash, id, "file")
			saved := filepath.Join(root, "saved")
			err = s.PurgeWithAccounting(id, func(_ TrashEntry, inspect func(string) (TrashFileInspection, error)) (func() error, error) {
				if _, err := inspect("file"); err != nil {
					t.Fatal(err)
				}
				if err := os.Rename(file, saved); err != nil {
					t.Fatal(err)
				}
				if symlink {
					if err := os.Symlink(saved, file); err != nil {
						t.Fatal(err)
					}
				} else if err := os.WriteFile(file, []byte("replacement"), 0600); err != nil {
					t.Fatal(err)
				}
				return func() error { t.Fatal("accounting committed after replacement"); return nil }, nil
			})
			if !errors.Is(err, ErrTrashChanged) {
				t.Fatalf("replacement accepted: %v", err)
			}
			if got, err := os.ReadFile(saved); err != nil || string(got) != "original" {
				t.Fatalf("original lost: %q %v", got, err)
			}
			if _, err := os.Lstat(file); err != nil {
				t.Fatalf("replacement lost: %v", err)
			}
		})
	}
}

func TestAccountedTrashPurgeRejectsLinksAndKeepsJournalOnCommitFailure(t *testing.T) {
	root := t.TempDir()
	s, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if err := os.WriteFile(filepath.Join(root, "file"), []byte("original"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Link(filepath.Join(root, "file"), filepath.Join(root, "hardlink")); err != nil {
		t.Fatal(err)
	}
	if err := s.MoveToTrash("file"); err != nil {
		t.Fatal(err)
	}
	items, err := s.TrashList()
	if err != nil || len(items) != 1 {
		t.Fatalf("trash: %+v %v", items, err)
	}
	id := items[0].ID
	prepare := func(_ TrashEntry, inspect func(string) (TrashFileInspection, error)) (func() error, error) {
		_, err := inspect(".")
		return func() error { return errors.New("injected ledger failure") }, err
	}
	if err := s.PurgeWithAccounting(id, prepare); !errors.Is(err, ErrTrashIdentityUnknown) {
		t.Fatalf("hardlink accepted: %v", err)
	}
	if err := os.Remove(filepath.Join(root, "hardlink")); err != nil {
		t.Fatal(err)
	}
	if err := s.PurgeWithAccounting(id, prepare); !errors.Is(err, ErrTrashAccountingUncertain) {
		t.Fatalf("commit failure not uncertain: %v", err)
	}
	if _, err := s.root.Lstat(path.Join(Trash, id+".json")); err != nil {
		t.Fatalf("recovery journal lost: %v", err)
	}
	if _, err := s.root.Lstat(path.Join(Trash, id)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("content should have been removed: %v", err)
	}
	if _, err := s.readTrashJournal(id); err != nil {
		t.Fatalf("journal invalid: %v", err)
	}
}
