//go:build darwin

package files

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestMediaIdentityMatchesScanAndSurvivesRename(t *testing.T) {
	dir := t.TempDir()
	name := filepath.Join(dir, "one.jpg")
	if err := os.WriteFile(name, []byte("photo"), 0600); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(name)
	if err != nil {
		t.Fatal(err)
	}
	identity := MediaFileIdentity(info)
	if identity == "" {
		t.Fatal("file identity unavailable")
	}
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
	found := false
	if err := manager.ScanDirectory(context.Background(), ".", func(entries []Entry) error {
		for _, entry := range entries {
			if entry.Name == "one.jpg" {
				found = true
				if entry.Identity != identity || !entry.SingleLink {
					t.Fatalf("scan identity %q differs from stat %q", entry.Identity, identity)
				}
			}
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if !found {
		t.Fatal("scan did not find the file")
	}
	other := filepath.Join(dir, "renamed.jpg")
	if err := os.Rename(name, other); err != nil {
		t.Fatal(err)
	}
	info, err = os.Stat(other)
	if err != nil || MediaFileIdentity(info) != identity {
		t.Fatalf("identity changed on rename: %v", err)
	}
	if err := os.WriteFile(name, []byte("photo"), 0600); err != nil {
		t.Fatal(err)
	}
	info, err = os.Stat(name)
	if err != nil || MediaFileIdentity(info) == identity {
		t.Fatalf("replacement inherited identity: %v", err)
	}
}
