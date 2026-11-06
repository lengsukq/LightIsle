package gallery

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestIncompleteMultiDirectoryScanDoesNotMarkUnseenPhotoMissing(t *testing.T) {
	lib, root, _ := batchTestLibrary(t)
	if err := os.Mkdir(filepath.Join(root, "a-photos"), 0700); err != nil {
		t.Fatal(err)
	}
	name := filepath.Join(root, "a-photos", "keep.jpg")
	if err := os.WriteFile(name, []byte("photo"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := lib.StartScan(); err != nil {
		t.Fatal(err)
	}
	waitPartialPhotoScan(t, lib)
	items, _, err := lib.List(0, 20, 0, false)
	if err != nil || len(items) != 1 {
		t.Fatalf("initial media: %+v %v", items, err)
	}
	id := items[0].ID
	if err := lib.Favorite(id, true); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(name, filepath.Join(t.TempDir(), "keep.jpg")); err != nil {
		t.Fatal(err)
	}
	if err := lib.StartScanDirs([]string{"a-photos", "z-unreadable"}); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(10 * time.Second)
	for lib.Status().Running && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if status := lib.Status(); status.Running || status.LastError == "" {
		t.Fatalf("incomplete scan reported success: %+v", status)
	}
	var missing string
	var favorite bool
	if err := lib.db.QueryRow(`SELECT missing_path, favorite FROM assets WHERE id=?`, id).Scan(&missing, &favorite); err != nil || missing != "" || !favorite {
		t.Fatalf("incomplete scan changed unseen photo: missing=%q favorite=%v err=%v", missing, favorite, err)
	}
}
