package gallery

import (
	"database/sql"
	"errors"
	"io"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestAlbumEditingPreservesOriginalAndSharedFavorite(t *testing.T) {
	dir := t.TempDir()
	storage, err := files.NewManager(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer storage.Close()
	const original = "the original photo must survive album editing"
	if _, err := storage.Upload("kept.jpg", strings.NewReader(original)); err != nil {
		t.Fatal(err)
	}
	library, err := Open(dir, storage)
	if err != nil {
		t.Fatal(err)
	}
	defer library.Close()
	share, _ := storage.State()
	result, err := library.db.Exec(`INSERT INTO assets(share,path,type,size,modified,taken_at,favorite)
		VALUES(?,'kept.jpg','photo',?,0,0,1)`, share, len(original))
	if err != nil {
		t.Fatal(err)
	}
	assetID, _ := result.LastInsertId()
	album, err := library.CreateAlbum("旅行")
	if err != nil {
		t.Fatal(err)
	}
	if err := library.AddToAlbum(album.ID, assetID); err != nil {
		t.Fatal(err)
	}
	renamed, err := library.RenameAlbum(album.ID, "  旅行精选  ")
	if err != nil || renamed.Name != "旅行精选" || renamed.Count != 1 || renamed.ID != album.ID {
		t.Fatalf("rename lost album membership: %+v %v", renamed, err)
	}
	if _, err := library.RenameAlbum(album.ID, renamed.Name); err != nil {
		t.Fatalf("unchanged name rejected: %v", err)
	}
	if err := library.RemoveFromAlbum(album.ID, assetID); err != nil {
		t.Fatal(err)
	}
	if err := library.RemoveFromAlbum(album.ID, assetID); !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("missing membership should be not found: %v", err)
	}
	items, _, err := library.List(0, 20, album.ID, false)
	if err != nil || len(items) != 0 {
		t.Fatalf("removed photo still appears in album: %+v %v", items, err)
	}
	if err := library.AddToAlbum(album.ID, assetID); err != nil {
		t.Fatal(err)
	}
	if err := library.DeleteAlbum(album.ID); err != nil {
		t.Fatal(err)
	}
	var membershipCount int
	if err := library.db.QueryRow("SELECT COUNT(*) FROM album_items WHERE album_id=?", album.ID).Scan(&membershipCount); err != nil || membershipCount != 0 {
		t.Fatalf("deleted album left orphan memberships: %d %v", membershipCount, err)
	}
	asset, err := library.Asset(assetID)
	if err != nil || !asset.Favorite {
		t.Fatalf("album operation changed shared favorite or asset: %+v %v", asset, err)
	}
	file, _, err := storage.Read("kept.jpg")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	data, err := io.ReadAll(file)
	if err != nil || string(data) != original {
		t.Fatalf("album operation changed original: %q %v", data, err)
	}
	if err := library.DeleteAlbum(album.ID); !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("unknown album delete: %v", err)
	}
}

func TestAlbumNamesAndCurrentShareIsolation(t *testing.T) {
	dir := t.TempDir()
	storage, err := files.NewManager(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer storage.Close()
	library, err := Open(dir, storage)
	if err != nil {
		t.Fatal(err)
	}
	defer library.Close()
	first, err := library.CreateAlbum("first")
	if err != nil {
		t.Fatal(err)
	}
	other, err := library.CreateAlbum("other")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := library.RenameAlbum(first.ID, other.Name); !errors.Is(err, ErrAlbumDuplicate) {
		t.Fatalf("duplicate rename not classified: %v", err)
	}
	for _, name := range []string{"", "  ", "bad\nname", "bad\x00name", strings.Repeat("屿", 61), string([]byte{0xff})} {
		if _, err := library.RenameAlbum(first.ID, name); !errors.Is(err, ErrAlbumName) {
			t.Errorf("invalid rename %q: %v", name, err)
		}
		if _, err := library.CreateAlbum(name); !errors.Is(err, ErrAlbumName) {
			t.Errorf("create and rename disagree for %q: %v", name, err)
		}
	}
	// A stale album ID from a previously selected share cannot be edited.
	if _, err := library.db.Exec("UPDATE albums SET share='previous-share' WHERE id=?", first.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := library.RenameAlbum(first.ID, "wrong-share"); !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("renamed a stale share's album: %v", err)
	}
	if err := library.DeleteAlbum(first.ID); !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("deleted a stale share's album: %v", err)
	}
	var name string
	if err := library.db.QueryRow("SELECT name FROM albums WHERE id=?", first.ID).Scan(&name); err != nil || name != "first" {
		t.Fatalf("stale album changed: %q %v", name, err)
	}
}
