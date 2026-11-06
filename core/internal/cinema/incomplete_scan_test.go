package cinema

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestIncompleteMultiDirectoryScanDoesNotMarkUnseenFilmMissing(t *testing.T) {
	lib, root, _ := batchTestLibrary(t)
	if err := os.Mkdir(filepath.Join(root, "a-films"), 0700); err != nil {
		t.Fatal(err)
	}
	name := filepath.Join(root, "a-films", "Movie.2020.mp4")
	if err := os.WriteFile(name, []byte("movie"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := lib.StartScan(); err != nil {
		t.Fatal(err)
	}
	waitMetadataScan(t, lib)
	items, _, err := lib.List(42, "movie", "", 20, 0)
	if err != nil || len(items) != 1 {
		t.Fatalf("initial media: %+v %v", items, err)
	}
	id := items[0].ID
	if err := lib.SaveProgress(42, id, 33, 100, false); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(name, filepath.Join(t.TempDir(), "Movie.mp4")); err != nil {
		t.Fatal(err)
	}
	if err := lib.StartScanDirs([]string{"a-films", "z-unreadable"}); err != nil {
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
	var progress float64
	err = lib.db.QueryRow(`SELECT f.missing_path,p.position FROM films f JOIN watch_progress p ON p.film_id=f.id WHERE f.id=? AND p.user_id=42`, id).Scan(&missing, &progress)
	if err != nil || missing != "" || progress != 33 {
		t.Fatalf("incomplete scan changed unseen film: missing=%q progress=%v err=%v", missing, progress, err)
	}
}
