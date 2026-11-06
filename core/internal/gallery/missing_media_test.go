package gallery

import (
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/mediapending"
)

func TestMissingPhotoRetainsUserDataAndRequiresFileIdentity(t *testing.T) {
	lib, root, _ := batchTestLibrary(t, "photo.jpg")
	scan := func() {
		t.Helper()
		if err := lib.StartScan(); err != nil {
			t.Fatal(err)
		}
		waitPartialPhotoScan(t, lib)
	}
	scan()
	assets, _, err := lib.List(0, 20, 0, false)
	if err != nil || len(assets) != 1 {
		t.Fatalf("initial assets: %+v %v", assets, err)
	}
	id := assets[0].ID
	if err := lib.Favorite(id, true); err != nil {
		t.Fatal(err)
	}
	if err := lib.PersonalFavorite(42, id, true); err != nil {
		t.Fatal(err)
	}
	album, err := lib.CreateAlbum("Family")
	if err != nil {
		t.Fatal(err)
	}
	if err := lib.AddToAlbum(album.ID, id); err != nil {
		t.Fatal(err)
	}
	name := filepath.Join(root, "photo.jpg")
	info, err := os.Stat(name)
	if err != nil {
		t.Fatal(err)
	}
	saved := filepath.Join(t.TempDir(), "saved.jpg")
	if err := os.Rename(name, saved); err != nil {
		t.Fatal(err)
	}
	scan()
	assets, _, err = lib.List(0, 20, 0, false)
	if err != nil || len(assets) != 0 {
		t.Fatalf("missing photo visible: %+v %v", assets, err)
	}
	var missing string
	var albumRows, favoriteRows int
	if err := lib.db.QueryRow(`SELECT missing_path FROM assets WHERE id=?`, id).Scan(&missing); err != nil || missing != "photo.jpg" {
		t.Fatalf("missing record: %q %v", missing, err)
	}
	if err := lib.db.QueryRow(`SELECT COUNT(*) FROM album_items WHERE asset_id=?`, id).Scan(&albumRows); err != nil || albumRows != 1 {
		t.Fatalf("album lost: %d %v", albumRows, err)
	}
	if err := lib.db.QueryRow(`SELECT COUNT(*) FROM personal_favorites WHERE asset_id=?`, id).Scan(&favoriteRows); err != nil || favoriteRows != 1 {
		t.Fatalf("favorite lost: %d %v", favoriteRows, err)
	}
	if err := os.WriteFile(name, []byte("synthetic"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(name, info.ModTime(), info.ModTime()); err != nil {
		t.Fatal(err)
	}
	scan()
	assets, _, err = lib.List(0, 20, 0, false)
	if err != nil || len(assets) != 1 || assets[0].ID == id || assets[0].Favorite {
		t.Fatalf("replacement inherited metadata: %+v %v", assets, err)
	}
	if err := os.Remove(name); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(saved, name); err != nil {
		t.Fatal(err)
	}
	scan()
	assets, _, err = lib.List(0, 20, 0, false)
	if err != nil || len(assets) != 1 || assets[0].ID != id || !assets[0].Favorite {
		t.Fatalf("original not restored: %+v %v", assets, err)
	}
}

func TestPhotoRenameKeepsUserData(t *testing.T) {
	lib, root, _ := batchTestLibrary(t, "photo.jpg")
	scan := func() {
		t.Helper()
		if err := lib.StartScan(); err != nil {
			t.Fatal(err)
		}
		waitPartialPhotoScan(t, lib)
	}
	scan()
	assets, _, err := lib.List(0, 20, 0, false)
	if err != nil || len(assets) != 1 {
		t.Fatalf("initial: %+v %v", assets, err)
	}
	id := assets[0].ID
	if err := lib.Favorite(id, true); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(root, "album"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(filepath.Join(root, "photo.jpg"), filepath.Join(root, "album", "renamed.jpg")); err != nil {
		t.Fatal(err)
	}
	scan()
	assets, _, err = lib.List(0, 20, 0, false)
	if err != nil || len(assets) != 1 || assets[0].ID != id || !assets[0].Favorite || assets[0].Path != "album/renamed.jpg" {
		t.Fatalf("rename lost metadata: %+v %v", assets, err)
	}
	missing, _, err := lib.MissingMedia([]string{"."}, 0, 20)
	if err != nil || len(missing) != 0 {
		t.Fatalf("rename marked missing: %+v %v", missing, err)
	}
}

func TestLegacyPhotoIdentityIsNotGuessed(t *testing.T) {
	lib, root, _ := batchTestLibrary(t, "photo.jpg")
	scan := func() {
		t.Helper()
		if err := lib.StartScan(); err != nil {
			t.Fatal(err)
		}
		waitPartialPhotoScan(t, lib)
	}
	scan()
	assets, _, err := lib.List(0, 20, 0, false)
	if err != nil || len(assets) != 1 {
		t.Fatalf("initial: %+v %v", assets, err)
	}
	id := assets[0].ID
	if err := lib.Favorite(id, true); err != nil {
		t.Fatal(err)
	}
	if err := lib.PersonalFavorite(42, id, true); err != nil {
		t.Fatal(err)
	}
	album, err := lib.CreateAlbum("Keep")
	if err != nil {
		t.Fatal(err)
	}
	if err := lib.AddToAlbum(album.ID, id); err != nil {
		t.Fatal(err)
	}
	if _, err := lib.db.Exec(`UPDATE assets SET file_identity='' WHERE id=?`, id); err != nil {
		t.Fatal(err)
	}
	scan()
	assets, _, err = lib.List(0, 20, 0, false)
	if err != nil || len(assets) != 1 || assets[0].ID == id || assets[0].Favorite {
		t.Fatalf("unverified photo inherited data: %+v %v", assets, err)
	}
	missing, _, err := lib.MissingMedia([]string{"."}, 0, 20)
	if err != nil || len(missing) != 1 || missing[0].ID != id || missing[0].Reason != "identity_unverified" {
		t.Fatalf("legacy data not available for review: %+v %v", missing, err)
	}
	if err := lib.AttachMissing(id, []string{"someone-else"}); !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("foreign owner attached: %v", err)
	}
	name, saved := filepath.Join(root, "photo.jpg"), filepath.Join(t.TempDir(), "saved.jpg")
	if err := os.Rename(name, saved); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(name, []byte("different"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := lib.AttachMissing(id, []string{"."}); !errors.Is(err, mediapending.ErrTargetUnavailable) {
		t.Fatalf("changed target accepted: %v", err)
	}
	if err := os.Remove(name); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(saved, name); err != nil {
		t.Fatal(err)
	}
	if err := lib.AttachMissing(id, []string{"."}); err != nil {
		t.Fatal(err)
	}
	assets, _, err = lib.List(0, 20, album.ID, true)
	if err != nil || len(assets) != 1 || !assets[0].Favorite {
		t.Fatalf("metadata not attached: %+v %v", assets, err)
	}
	var count int
	if err := lib.db.QueryRow(`SELECT COUNT(*) FROM personal_favorites WHERE user_id=42 AND asset_id=?`, assets[0].ID).Scan(&count); err != nil || count != 1 {
		t.Fatalf("personal favorite not attached: %d %v", count, err)
	}
}
