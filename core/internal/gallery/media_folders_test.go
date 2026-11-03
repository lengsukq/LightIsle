package gallery

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestGalleryScansPhotosAndLegacyButNotCinema(t *testing.T) {
	base := t.TempDir()
	store, err := files.NewManager(base)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	share := filepath.Join(base, "SharedFiles")
	for relative := range map[string]bool{
		"legacy.jpg": true, "图库/new.jpg": true, "影视/poster.jpg": true,
	} {
		if err := os.WriteFile(filepath.Join(share, relative), []byte("photo"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	gallery, err := Open(base, store)
	if err != nil {
		t.Fatal(err)
	}
	defer gallery.Close()
	if err := gallery.StartScan(); err != nil {
		t.Fatal(err)
	}
	until := time.Now().Add(10 * time.Second)
	for gallery.Status().Running && time.Now().Before(until) {
		time.Sleep(20 * time.Millisecond)
	}
	if status := gallery.Status(); status.Running || status.LastError != "" {
		t.Fatalf("scan failed %+v", status)
	}
	items, _, err := gallery.List(0, 100, 0, false)
	if err != nil || len(items) != 2 {
		t.Fatalf("expected 2 photos, got %+v %v", items, err)
	}
	paths := map[string]bool{}
	for _, item := range items {
		paths[item.Path] = true
	}
	if !paths["legacy.jpg"] || !paths["图库/new.jpg"] || paths["影视/poster.jpg"] {
		t.Fatalf("unexpected gallery scope: %v", paths)
	}
}
