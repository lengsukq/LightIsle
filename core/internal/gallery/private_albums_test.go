package gallery

import (
	"database/sql"
	"errors"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestPrivateAlbumsAreAccountAndShareIsolatedWithSafeDeletion(t *testing.T) {
	data := t.TempDir()
	storage, err := files.NewManager(data)
	if err != nil {
		t.Fatal(err)
	}
	defer storage.Close()
	l, err := Open(data, storage)
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	share, ok := storage.State()
	if !ok {
		t.Fatal("share offline")
	}
	if err := storage.Mkdir("allowed"); err != nil {
		t.Fatal(err)
	}
	if err := storage.Mkdir("restricted"); err != nil {
		t.Fatal(err)
	}
	a1, err := l.db.Exec("INSERT INTO assets(share,path,type,size,modified,taken_at,seen) VALUES(?,'allowed/cat.jpg','photo',10,1,100,1)", share)
	if err != nil {
		t.Fatal(err)
	}
	visible, _ := a1.LastInsertId()
	a2, err := l.db.Exec("INSERT INTO assets(share,path,type,size,modified,taken_at,seen) VALUES(?,'restricted/dog.jpg','photo',10,1,90,1)", share)
	if err != nil {
		t.Fatal(err)
	}
	hidden, _ := a2.LastInsertId()
	owner := int64(101)
	other := int64(202)
	album, err := l.CreatePrivateAlbum(owner, "  私人旅行  ")
	if err != nil || album.Name != "私人旅行" {
		t.Fatalf("create %+v %v", album, err)
	}
	if _, err := l.CreatePrivateAlbum(owner, "私人旅行"); !errors.Is(err, ErrAlbumDuplicate) {
		t.Fatalf("duplicate allowed: %v", err)
	}
	if _, err := l.RenamePrivateAlbum(other, album.ID, "hijack"); !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("other user rename succeeded: %v", err)
	}
	if err := l.AddToPrivateAlbum(other, album.ID, visible); !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("other user inserted into album: %v", err)
	}
	if err := l.AddToPrivateAlbum(owner, album.ID, visible); err != nil {
		t.Fatal(err)
	}
	if err := l.AddToPrivateAlbum(owner, album.ID, visible); err != nil {
		t.Fatalf("repeat add must be idempotent: %v", err)
	}
	if err := l.AddToPrivateAlbum(owner, album.ID, hidden); err != nil {
		t.Fatal(err)
	}
	albums, err := l.PrivateAlbumsScoped(owner, []string{"allowed"})
	if err != nil || len(albums) != 1 || albums[0].Count != 1 {
		t.Fatalf("album count leaked restricted assets: %+v %v", albums, err)
	}
	outsider, err := l.PrivateAlbumsScoped(other, []string{"."})
	if err != nil || len(outsider) != 0 {
		t.Fatalf("album name leaked to other user: %+v %v", outsider, err)
	}
	list, more, err := l.ListScopedForUserWithPrivateAlbum(owner, 0, 1, 0, album.ID, false, false, []string{"allowed"})
	if err != nil || more != 0 || len(list) != 1 || list[0].ID != visible {
		t.Fatalf("incorrect ACL-paginated results: %+v %d %v", list, more, err)
	}
	if _, _, err := l.ListScopedForUserWithPrivateAlbum(other, 0, 20, 0, album.ID, false, false, []string{"."}); !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("other user enumerated private album ID: %v", err)
	}
	if err := l.RemoveFromPrivateAlbum(other, album.ID, visible); !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("other user removed item: %v", err)
	}
	updated, err := l.RenamePrivateAlbum(owner, album.ID, "仅自己")
	if err != nil || updated.Name != "仅自己" {
		t.Fatalf("rename: %+v %v", updated, err)
	}
	if err := l.DeletePrivateAlbum(other, album.ID); !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("other user deleted album: %v", err)
	}
	if err := l.DeletePrivateAlbum(owner, album.ID); err != nil {
		t.Fatal(err)
	}
	var count int
	if err := l.db.QueryRow("SELECT COUNT(*) FROM private_album_items WHERE album_id=?", album.ID).Scan(&count); err != nil || count != 0 {
		t.Fatalf("orphan memberships: %d %v", count, err)
	}
	if _, err := storage.Upload("allowed/cat.jpg", strings.NewReader("original")); err != nil {
		t.Fatal(err)
	}
	f, _, err := storage.Read("allowed/cat.jpg")
	if err != nil {
		t.Fatalf("album deleted original source: %v", err)
	}
	f.Close()
}
