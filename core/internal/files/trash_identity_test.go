package files

import (
	"encoding/json"
	"errors"
	"os"
	"path"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

type trashStatOverride struct {
	os.FileInfo
	stat *syscall.Stat_t
}

func (s trashStatOverride) Sys() any { return s.stat }

func TestTrashIdentitySurvivesDeviceNumberChange(t *testing.T) {
	name := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(name, []byte("content"), 0600); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(name)
	if err != nil {
		t.Fatal(err)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		t.Fatal("filesystem identity unavailable")
	}
	changed := *stat
	changed.Dev++
	reattached := trashStatOverride{FileInfo: info, stat: &changed}
	if original := trashObjectIdentity(info); original == "" || trashObjectIdentity(reattached) != original {
		t.Fatal("same inode and birth time should survive a changed device number")
	}
	if MediaFileIdentity(info) == MediaFileIdentity(reattached) {
		t.Fatal("existing media identity format unexpectedly changed")
	}
}

func TestTrashJournalPinsFileAndFolderIdentity(t *testing.T) {
	for _, directory := range []bool{false, true} {
		name := "file"
		if directory {
			name = "folder"
		}
		t.Run(name, func(t *testing.T) {
			root := t.TempDir()
			s, err := Open(root)
			if err != nil {
				t.Fatal(err)
			}
			defer s.Close()
			original := filepath.Join(root, name)
			if directory {
				if err := os.Mkdir(original, 0700); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(original, "content"), []byte("old"), 0600); err != nil {
					t.Fatal(err)
				}
			} else if err := os.WriteFile(original, []byte("old"), 0600); err != nil {
				t.Fatal(err)
			}
			if err := s.MoveToTrash(name); err != nil {
				t.Fatal(err)
			}
			entries, err := s.TrashList()
			if err != nil || len(entries) != 1 || entries[0].ObjectIdentity == "" {
				t.Fatalf("journal identity: %+v %v", entries, err)
			}
			public, err := json.Marshal(entries[0])
			if err != nil || strings.Contains(string(public), "objectIdentity") || strings.Contains(string(public), entries[0].ObjectIdentity) {
				t.Fatalf("identity leaked via public entry: %s %v", public, err)
			}
			id := entries[0].ID
			trash := filepath.Join(root, Trash, id)
			saved := filepath.Join(root, Trash, id+"-saved")
			if err := os.Rename(trash, saved); err != nil {
				t.Fatal(err)
			}
			if directory {
				if err := os.Mkdir(trash, 0700); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(trash, "content"), []byte("replacement"), 0600); err != nil {
					t.Fatal(err)
				}
			} else if err := os.WriteFile(trash, []byte("replacement"), 0600); err != nil {
				t.Fatal(err)
			}
			if err := s.Restore(id); !errors.Is(err, ErrTrashChanged) {
				t.Fatalf("restore replacement: %v", err)
			}
			if err := s.Purge(id); !errors.Is(err, ErrTrashChanged) {
				t.Fatalf("purge replacement: %v", err)
			}
			if _, err := os.Stat(saved); err != nil {
				t.Fatalf("original lost: %v", err)
			}
			if _, err := os.Stat(trash); err != nil {
				t.Fatalf("replacement lost: %v", err)
			}
			if _, err := os.Stat(original); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("unexpected restore: %v", err)
			}
			if err := os.RemoveAll(trash); err != nil {
				t.Fatal(err)
			}
			if err := os.Rename(saved, trash); err != nil {
				t.Fatal(err)
			}
			if err := s.Restore(id); err != nil {
				t.Fatalf("restore original: %v", err)
			}
		})
	}
}

func TestTrashReportsSourceReplacementDuringMove(t *testing.T) {
	root := t.TempDir()
	s, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if err := os.WriteFile(filepath.Join(root, "file"), []byte("original"), 0600); err != nil {
		t.Fatal(err)
	}
	s.rename = func(from, to string) error {
		if from == "file" {
			if err := os.Rename(filepath.Join(root, from), filepath.Join(root, "saved")); err != nil {
				return err
			}
			if err := os.WriteFile(filepath.Join(root, from), []byte("replacement"), 0600); err != nil {
				return err
			}
		}
		return s.root.Rename(from, to)
	}
	if err := s.MoveToTrash("file"); !errors.Is(err, ErrTrashChanged) {
		t.Fatalf("replacement not reported: %v", err)
	}
	entries, err := s.TrashList()
	if err != nil || len(entries) != 1 {
		t.Fatalf("missing recovery journal: %+v %v", entries, err)
	}
	if err := s.Restore(entries[0].ID); !errors.Is(err, ErrTrashChanged) {
		t.Fatalf("replacement restored: %v", err)
	}
	if got, err := os.ReadFile(filepath.Join(root, "saved")); err != nil || string(got) != "original" {
		t.Fatalf("original lost: %q %v", got, err)
	}
	if got, err := s.root.ReadFile(path.Join(Trash, entries[0].ID)); err != nil || string(got) != "replacement" {
		t.Fatalf("replacement lost: %q %v", got, err)
	}
}

func TestTrashRejectsReplacementSymlink(t *testing.T) {
	root := t.TempDir()
	s, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if err := os.WriteFile(filepath.Join(root, "file"), []byte("original"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := s.MoveToTrash("file"); err != nil {
		t.Fatal(err)
	}
	entries, err := s.TrashList()
	if err != nil || len(entries) != 1 {
		t.Fatalf("trash: %+v %v", entries, err)
	}
	id := entries[0].ID
	trash := filepath.Join(root, Trash, id)
	saved := filepath.Join(root, Trash, id+"-saved")
	if err := os.Rename(trash, saved); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(saved, trash); err != nil {
		t.Fatal(err)
	}
	if err := s.Restore(id); !errors.Is(err, ErrTrashChanged) {
		t.Fatalf("restored a link: %v", err)
	}
	if err := s.Purge(id); !errors.Is(err, ErrTrashChanged) {
		t.Fatalf("purged a link: %v", err)
	}
	if data, err := os.ReadFile(saved); err != nil || string(data) != "original" {
		t.Fatalf("link target changed: %q %v", data, err)
	}
}

func TestTrashJournalLegacyAndCorruptIdentity(t *testing.T) {
	for _, corrupt := range []bool{false, true} {
		name := "legacy"
		if corrupt {
			name = "corrupt"
		}
		t.Run(name, func(t *testing.T) {
			root := t.TempDir()
			s, err := Open(root)
			if err != nil {
				t.Fatal(err)
			}
			defer s.Close()
			if err := os.WriteFile(filepath.Join(root, "file"), []byte("original"), 0600); err != nil {
				t.Fatal(err)
			}
			if err := s.MoveToTrash("file"); err != nil {
				t.Fatal(err)
			}
			entries, err := s.TrashList()
			if err != nil || len(entries) != 1 {
				t.Fatalf("trash: %+v %v", entries, err)
			}
			id := entries[0].ID
			journalPath := filepath.Join(root, Trash, id+".json")
			data, err := os.ReadFile(journalPath)
			if err != nil {
				t.Fatal(err)
			}
			var journal map[string]any
			if err := json.Unmarshal(data, &journal); err != nil {
				t.Fatal(err)
			}
			delete(journal, "objectIdentity")
			if corrupt {
				journal["objectIdentity"] = "not-an-identity"
			}
			data, err = json.Marshal(journal)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(journalPath, data, 0600); err != nil {
				t.Fatal(err)
			}
			if corrupt {
				if err := s.Purge(id); !errors.Is(err, ErrPath) {
					t.Fatalf("corrupt journal allowed purge: %v", err)
				}
				if got, err := s.root.ReadFile(path.Join(Trash, id)); err != nil || string(got) != "original" {
					t.Fatalf("corrupt journal lost content: %q %v", got, err)
				}
			} else if err := s.Restore(id); err != nil {
				t.Fatalf("legacy journal could not restore: %v", err)
			}
		})
	}
}
