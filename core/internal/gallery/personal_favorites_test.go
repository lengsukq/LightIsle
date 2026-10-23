package gallery

import (
	"testing"

	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestPersonalFavoritesDoNotModifySharedOrOtherUsersAndCascadeOnAssetRemoval(t *testing.T) {
	data := t.TempDir()
	storage, err := files.NewManager(data)
	if err != nil {
		t.Fatal(err)
	}
	defer storage.Close()
	library, err := Open(data, storage)
	if err != nil {
		t.Fatal(err)
	}
	defer library.Close()
	share, online := storage.State()
	if !online {
		t.Fatal("shared folder unavailable")
	}
	result, err := library.db.Exec(`INSERT INTO assets(share,path,type,size,modified,taken_at,seen,favorite)
 VALUES(?,?,?,?,?,?,?,?)`, share, "family/summer.jpg", "photo", 12, 100, 100, 1, 1)
	if err != nil {
		t.Fatal(err)
	}
	id, err := result.LastInsertId()
	if err != nil {
		t.Fatal(err)
	}
	if err := library.PersonalFavorite(101, id, true); err != nil {
		t.Fatal(err)
	}
	if err := library.PersonalFavorite(101, id, true); err != nil {
		t.Fatalf("duplicate toggle: %v", err)
	}
	first, _, err := library.ListScopedForUser(101, 0, 10, 0, false, true, []string{"."})
	if err != nil || len(first) != 1 || !first[0].PersonalFavorite || !first[0].Favorite {
		t.Fatalf("personal list: %+v %v", first, err)
	}
	other, _, err := library.ListScopedForUser(102, 0, 10, 0, false, false, []string{"."})
	if err != nil || len(other) != 1 || other[0].PersonalFavorite != false || !other[0].Favorite {
		t.Fatalf("other user saw private favorite or lost shared favorite: %+v %v", other, err)
	}
	privateOther, _, err := library.ListScopedForUser(102, 0, 10, 0, false, true, []string{"."})
	if err != nil || len(privateOther) != 0 {
		t.Fatalf("private favorite leaked to other user: %+v %v", privateOther, err)
	}
	if err := library.PersonalFavorite(101, id, false); err != nil {
		t.Fatal(err)
	}
	cleared, _, err := library.ListScopedForUser(101, 0, 10, 0, false, true, []string{"."})
	if err != nil || len(cleared) != 0 {
		t.Fatalf("personal favorite removal failed: %+v %v", cleared, err)
	}
	if err := library.PersonalFavorite(101, id, true); err != nil {
		t.Fatal(err)
	}
	if _, err := library.db.Exec("DELETE FROM assets WHERE id=?", id); err != nil {
		t.Fatal(err)
	}
	var remaining int
	if err := library.db.QueryRow("SELECT COUNT(*) FROM personal_favorites WHERE asset_id=?", id).Scan(&remaining); err != nil || remaining != 0 {
		t.Fatalf("orphan personal favorite remained: %d %v", remaining, err)
	}
}
