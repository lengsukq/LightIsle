package cinema

import (
	"github.com/lengsukq/lightisle/core/internal/files"
	"os"
	"path/filepath"
	"testing"
)

func TestChangedCinemaDirectoryDoesNotLoseOtherViewingProgress(t *testing.T) {
	data := t.TempDir()
	fs, err := files.NewManager(data)
	if err != nil {
		t.Fatal(err)
	}
	defer fs.Close()
	for _, dir := range []string{"Movies_%", "Series"} {
		if err := fs.Mkdir(dir); err != nil {
			t.Fatal(err)
		}
	}
	first := filepath.Join(data, "SharedFiles", "Movies_%", "Movie.One.2020.mp4")
	other := filepath.Join(data, "SharedFiles", "Series", "Movie.Two.2021.mp4")
	for _, p := range []string{first, other} {
		if err := os.WriteFile(p, []byte("movie bytes"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	lib, err := Open(data, fs)
	if err != nil {
		t.Fatal(err)
	}
	defer lib.Close()
	if err = lib.StartScan(); err != nil {
		t.Fatal(err)
	}
	waitMetadataScan(t, lib)
	all, _, err := lib.List(4, "movie", "", 50, 0)
	if err != nil || len(all) != 2 {
		t.Fatalf("initial list %+v %v", all, err)
	}
	var otherID int64
	for _, v := range all {
		if v.Path == "Series/Movie.Two.2021.mp4" {
			otherID = v.ID
		}
	}
	if otherID == 0 {
		t.Fatalf("unrelated item not indexed: %+v", all)
	}
	if err = lib.SaveProgress(4, otherID, 33, 100, false); err != nil {
		t.Fatal(err)
	}
	if err = os.Remove(first); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(data, "SharedFiles", "Movies_%", "New.Movie.2024.mp4"), []byte("new"), 0600); err != nil {
		t.Fatal(err)
	}
	if err = lib.StartScanDirs([]string{"Movies_%"}); err != nil {
		t.Fatal(err)
	}
	waitMetadataScan(t, lib)
	kept, err := lib.Get(otherID, 4)
	if err != nil || kept.Position != 33 {
		t.Fatalf("partial scan lost unrelated viewing progress %+v %v", kept, err)
	}
	films, _, err := lib.List(4, "movie", "", 50, 0)
	if err != nil || len(films) != 2 {
		t.Fatalf("unexpected scoped rescan %+v %v", films, err)
	}
}

func TestUnicodePartialScanPrunesDeletedFilmAndKeepsPrefixSiblingProgress(t *testing.T) {
	data := t.TempDir()
	fs, err := files.NewManager(data)
	if err != nil {
		t.Fatal(err)
	}
	defer fs.Close()
	for _, dir := range []string{"电影🎬", "电影🎬精选"} {
		if err := fs.Mkdir(dir); err != nil {
			t.Fatal(err)
		}
	}
	removedPath := filepath.Join(data, "SharedFiles", "电影🎬", "Movie.One.2020.mp4")
	keptPath := filepath.Join(data, "SharedFiles", "电影🎬精选", "Movie.Two.2021.mp4")
	for _, p := range []string{removedPath, keptPath} {
		if err := os.WriteFile(p, []byte("synthetic movie"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	lib, err := Open(data, fs)
	if err != nil {
		t.Fatal(err)
	}
	defer lib.Close()
	if err := lib.StartScan(); err != nil {
		t.Fatal(err)
	}
	waitMetadataScan(t, lib)
	initial, _, err := lib.List(4, "movie", "", 20, 0)
	if err != nil || len(initial) != 2 {
		t.Fatalf("initial films = %+v, err=%v", initial, err)
	}
	var keepID int64
	for _, film := range initial {
		if film.Path == "电影🎬精选/Movie.Two.2021.mp4" {
			keepID = film.ID
		}
	}
	if keepID == 0 {
		t.Fatalf("prefix sibling film missing: %+v", initial)
	}
	if err := lib.SaveProgress(4, keepID, 33, 100, false); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(removedPath); err != nil {
		t.Fatal(err)
	}
	if err := lib.StartScanDirs([]string{"电影🎬"}); err != nil {
		t.Fatal(err)
	}
	waitMetadataScan(t, lib)
	after, _, err := lib.List(4, "movie", "", 20, 0)
	if err != nil || len(after) != 1 || after[0].ID != keepID || after[0].Path != "电影🎬精选/Movie.Two.2021.mp4" {
		t.Fatalf("partial scan removed prefix sibling or retained deleted film: %+v, err=%v", after, err)
	}
	retained, err := lib.Get(keepID, 4)
	if err != nil || retained.Position != 33 {
		t.Fatalf("partial scan lost sibling viewing progress: %+v, err=%v", retained, err)
	}
}
