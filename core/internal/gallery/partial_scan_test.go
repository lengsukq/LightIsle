package gallery

import (
	"github.com/lengsukq/lightisle/core/internal/files"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func waitPartialPhotoScan(t *testing.T, lib *Library) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for lib.Status().Running && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if st := lib.Status(); st.Running || st.LastError != "" {
		t.Fatalf("photo scan failed: %+v", st)
	}
}
func TestChangedDirectoryPreservesUnrelatedAlbumsAndFavorites(t *testing.T) {
	data := t.TempDir()
	fs, err := files.NewManager(data)
	if err != nil {
		t.Fatal(err)
	}
	defer fs.Close()
	for _, dir := range []string{"A_%", "Other"} {
		if err := fs.Mkdir(dir); err != nil {
			t.Fatal(err)
		}
	}
	original := filepath.Join(data, "SharedFiles", "A_%", "one.jpg")
	unrelated := filepath.Join(data, "SharedFiles", "Other", "two.jpg")
	for _, p := range []string{original, unrelated} {
		if err := os.WriteFile(p, []byte("synthetic photo"), 0600); err != nil {
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
	waitPartialPhotoScan(t, lib)
	all, _, err := lib.List(0, 50, 0, false)
	if err != nil || len(all) != 2 {
		t.Fatalf("initial assets %+v %v", all, err)
	}
	var otherID int64
	for _, a := range all {
		if a.Path == "Other/two.jpg" {
			otherID = a.ID
		}
	}
	if otherID == 0 {
		t.Fatalf("other photo absent %+v", all)
	}
	if err := lib.Favorite(otherID, true); err != nil {
		t.Fatal(err)
	}
	album, err := lib.CreateAlbum("Private keep")
	if err != nil {
		t.Fatal(err)
	}
	if err = lib.AddToAlbum(album.ID, otherID); err != nil {
		t.Fatal(err)
	}
	if err = os.Remove(original); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(data, "SharedFiles", "A_%", "three.jpg"), []byte("different"), 0600); err != nil {
		t.Fatal(err)
	}
	if err = lib.StartScanDirs([]string{"A_%"}); err != nil {
		t.Fatal(err)
	}
	waitPartialPhotoScan(t, lib)
	after, _, err := lib.List(0, 50, 0, false)
	if err != nil || len(after) != 2 {
		t.Fatalf("wrong partial count %+v %v", after, err)
	}
	retained, _, err := lib.List(0, 50, album.ID, true)
	if err != nil || len(retained) != 1 || retained[0].ID != otherID {
		t.Fatalf("partial scan erased out-of-scope album or favorite %+v %v", retained, err)
	}
	if err = lib.StartScanDirs([]string{"missing"}); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for lib.Status().Running && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if st := lib.Status(); st.LastError == "" {
		t.Fatalf("nonexistent subtree must not prune: %+v", st)
	}
	left, _, err := lib.List(0, 50, 0, false)
	if err != nil || len(left) != 2 {
		t.Fatalf("error scan deleted assets %+v %v", left, err)
	}
}

func TestUnicodePartialScanPrunesDeletedFilesAndKeepsPrefixSibling(t *testing.T) {
	data := t.TempDir()
	fs, err := files.NewManager(data)
	if err != nil {
		t.Fatal(err)
	}
	defer fs.Close()
	for _, dir := range []string{"相册🎞", "相册🎞精选"} {
		if err := fs.Mkdir(dir); err != nil {
			t.Fatal(err)
		}
	}
	removedPath := filepath.Join(data, "SharedFiles", "相册🎞", "removed.jpg")
	keptPath := filepath.Join(data, "SharedFiles", "相册🎞精选", "keep.jpg")
	for _, p := range []string{removedPath, keptPath} {
		if err := os.WriteFile(p, []byte("synthetic photo"), 0600); err != nil {
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
	waitPartialPhotoScan(t, lib)
	initial, _, err := lib.List(0, 20, 0, false)
	if err != nil || len(initial) != 2 {
		t.Fatalf("initial assets = %+v, err=%v", initial, err)
	}
	var keepID int64
	for _, asset := range initial {
		if asset.Path == "相册🎞精选/keep.jpg" {
			keepID = asset.ID
		}
	}
	if keepID == 0 {
		t.Fatalf("prefix sibling asset missing: %+v", initial)
	}
	if err := lib.Favorite(keepID, true); err != nil {
		t.Fatal(err)
	}
	album, err := lib.CreateAlbum("Keep Unicode sibling")
	if err != nil {
		t.Fatal(err)
	}
	if err := lib.AddToAlbum(album.ID, keepID); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(removedPath); err != nil {
		t.Fatal(err)
	}
	if err := lib.StartScanDirs([]string{"相册🎞"}); err != nil {
		t.Fatal(err)
	}
	waitPartialPhotoScan(t, lib)
	after, _, err := lib.List(0, 20, 0, false)
	if err != nil || len(after) != 1 || after[0].ID != keepID || after[0].Path != "相册🎞精选/keep.jpg" {
		t.Fatalf("partial scan removed prefix sibling or retained deleted asset: %+v, err=%v", after, err)
	}
	retained, _, err := lib.List(0, 20, album.ID, true)
	if err != nil || len(retained) != 1 || retained[0].ID != keepID {
		t.Fatalf("partial scan lost sibling album/favorite: %+v, err=%v", retained, err)
	}
}
