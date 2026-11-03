package files

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestDefaultMediaFoldersForPinnedAndLegacyRoots(t *testing.T) {
	for _, pinned := range []bool{false, true} {
		t.Run(map[bool]string{false: "legacy", true: "pinned"}[pinned], func(t *testing.T) {
			share := t.TempDir()
			if err := os.WriteFile(filepath.Join(share, "old-file.txt"), []byte("preserve"), 0600); err != nil {
				t.Fatal(err)
			}
			var m *Manager
			var err error
			if pinned {
				root, e := os.OpenRoot(share)
				if e != nil {
					t.Fatal(e)
				}
				defer root.Close()
				m, err = NewPinnedManager(root)
			} else {
				m = &Manager{}
				m.store, err = openExisting(share)
			}
			if err != nil {
				t.Fatal(err)
			}
			defer m.Close()
			for _, name := range []string{MediaPhotosDir, MediaMoviesDir} {
				// A legacy helper constructed without a persisted hardware
				// binding is not an online Manager; inspect its verified
				// anchored Store directly.
				info, e := m.store.Stat(name)
				if e != nil || !info.IsDir() {
					t.Fatalf("missing %s: %v", name, e)
				}
			}
			if err := ensureDefaultMediaFolders(m.store); err != nil {
				t.Fatalf("not idempotent: %v", err)
			}
			data, e := os.ReadFile(filepath.Join(share, "old-file.txt"))
			if e != nil || string(data) != "preserve" {
				t.Fatalf("legacy file changed: %q %v", data, e)
			}
		})
	}
}

func TestDefaultMediaFoldersNeverOverwriteSymlinkOrFile(t *testing.T) {
	for _, special := range []string{"file", "symlink"} {
		t.Run(special, func(t *testing.T) {
			root := t.TempDir()
			store, err := Open(root)
			if err != nil {
				t.Fatal(err)
			}
			defer store.Close()
			target := filepath.Join(root, "original.txt")
			if err := os.WriteFile(target, []byte("untouched"), 0600); err != nil {
				t.Fatal(err)
			}
			if special == "file" {
				if err := os.WriteFile(filepath.Join(root, MediaPhotosDir), []byte("occupied"), 0600); err != nil {
					t.Fatal(err)
				}
			} else {
				if err := os.Symlink(target, filepath.Join(root, MediaPhotosDir)); err != nil {
					t.Fatal(err)
				}
			}
			err = ensureDefaultMediaFolders(store)
			if err == nil {
				t.Fatal("collision accepted")
			}
			if special == "file" && !errors.Is(err, ErrType) {
				t.Fatalf("expected type conflict: %v", err)
			}
			data, e := os.ReadFile(target)
			if e != nil || string(data) != "untouched" {
				t.Fatalf("existing file damaged: %v", e)
			}
		})
	}
}
