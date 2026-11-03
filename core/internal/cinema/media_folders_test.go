package cinema

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestCinemaScansMoviesAndLegacyButNotPhotoClips(t *testing.T) {
	base := t.TempDir()
	store, err := files.NewManager(base)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	share := filepath.Join(base, "SharedFiles")
	for relative := range map[string]bool{
		"legacy.mp4": true, "影视/film.mp4": true, "图库/live-photo.mp4": true,
	} {
		if err := os.WriteFile(filepath.Join(share, relative), []byte("video"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	library, err := Open(base, store)
	if err != nil {
		t.Fatal(err)
	}
	defer library.Close()
	if err := library.StartScan(); err != nil {
		t.Fatal(err)
	}
	until := time.Now().Add(10 * time.Second)
	for library.Status().Running && time.Now().Before(until) {
		time.Sleep(20 * time.Millisecond)
	}
	if status := library.Status(); status.Running || status.LastError != "" {
		t.Fatalf("scan failed %+v", status)
	}
	movies, _, err := library.List(1, "", "", 100, 0)
	if err != nil || len(movies) != 2 {
		t.Fatalf("expected 2 movies, got %+v %v", movies, err)
	}
	paths := map[string]bool{}
	for _, movie := range movies {
		paths[movie.Path] = true
	}
	if !paths["legacy.mp4"] || !paths["影视/film.mp4"] || paths["图库/live-photo.mp4"] {
		t.Fatalf("unexpected cinema scope: %v", paths)
	}
}
