package gallery

import (
	"path/filepath"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestForgetLegacyShareOnlyRemovesMatchingRows(t *testing.T) {
	data := t.TempDir()
	storage, err := files.NewManager(data)
	if err != nil {
		t.Fatal(err)
	}
	defer storage.Close()
	lib, err := Open(data, storage)
	if err != nil {
		t.Fatal(err)
	}
	defer lib.Close()
	old := filepath.Join(data, "lost-drive")
	other := filepath.Join(data, "unrelated-drive")
	for _, share := range []string{old, other} {
		if _, err := lib.db.Exec("INSERT INTO assets(share,path,type,size,modified,taken_at,seen,favorite) VALUES(?, 'a.jpg','photo',2,1,1,1,1)", share); err != nil {
			t.Fatal(err)
		}
		if _, err := lib.db.Exec("INSERT INTO albums(share,name) VALUES(?, 'family')", share); err != nil {
			t.Fatal(err)
		}
	}
	if err := lib.ForgetLegacyShare(old); err != nil {
		t.Fatal(err)
	}
	for _, table := range []string{"assets", "albums"} {
		for _, check := range []struct {
			path string
			want int
		}{{old, 0}, {other, 1}} {
			var count int
			if err := lib.db.QueryRow("SELECT count(*) FROM "+table+" WHERE share=?", check.path).Scan(&count); err != nil {
				t.Fatal(err)
			}
			if count != check.want {
				t.Fatalf("%s %s: got %d want %d", table, check.path, count, check.want)
			}
		}
	}
}
