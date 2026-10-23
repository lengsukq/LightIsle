package cinema

import (
	"path/filepath"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestForgetLegacySharePreservesOtherLibrariesAndSourceFiles(t *testing.T) {
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
	old := filepath.Join(data, "detached")
	other := filepath.Join(data, "another")
	var oldID int64
	for _, share := range []string{old, other} {
		result, err := lib.db.Exec("INSERT INTO films(share,path,title,kind,size,modified,seen) VALUES(?, 'a.mp4','A','movie',1,1,1)", share)
		if err != nil {
			t.Fatal(err)
		}
		id, err := result.LastInsertId()
		if err != nil {
			t.Fatal(err)
		}
		if share == old {
			oldID = id
		}
		if _, err := lib.db.Exec("INSERT INTO watch_progress(user_id,film_id,position,duration,updated_at) VALUES(1,?,10,20,1)", id); err != nil {
			t.Fatal(err)
		}
	}
	if err := lib.ForgetLegacyShare(old); err != nil {
		t.Fatal(err)
	}
	var count int
	if err := lib.db.QueryRow("SELECT count(*) FROM films WHERE share=?", other).Scan(&count); err != nil || count != 1 {
		t.Fatalf("other film lost: %d %v", count, err)
	}
	if err := lib.db.QueryRow("SELECT count(*) FROM watch_progress WHERE film_id=?", oldID).Scan(&count); err != nil || count != 0 {
		t.Fatalf("forgotten progress retained: %d %v", count, err)
	}
	if err := lib.db.QueryRow("SELECT count(*) FROM watch_progress").Scan(&count); err != nil || count != 1 {
		t.Fatalf("other progress lost: %d %v", count, err)
	}
}
