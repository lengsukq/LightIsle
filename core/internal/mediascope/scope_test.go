package mediascope

import (
	"database/sql"
	_ "github.com/mattn/go-sqlite3"
	"testing"
)

func TestLiteralScopesPreventSiblingAndWildcardEscapes(t *testing.T) {
	db, err := sql.Open("sqlite3", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec("CREATE TABLE films(path TEXT);INSERT INTO films(path) VALUES ('family/a.mp4'),('family-private/b.mp4'),('Family/a.mp4'),('100%done/c.mp4'),('100xxdone/d.mp4')"); err != nil {
		t.Fatal(err)
	}
	for _, tt := range []struct {
		root string
		want int
	}{
		{"family", 1}, {"100%done", 1}, {"Family", 1}, {".", 5},
	} {
		fragment, args, err := Clause("f.path", []string{tt.root})
		if err != nil {
			t.Fatal(err)
		}
		var count int
		if err := db.QueryRow("SELECT COUNT(*) FROM films f WHERE 1=1"+fragment, args...).Scan(&count); err != nil {
			t.Fatal(err)
		}
		if count != tt.want {
			t.Fatalf("scope %q leaked paths: %d want %d", tt.root, count, tt.want)
		}
	}
	fragment, _, err := Clause("f.path", nil)
	if err != nil || fragment != " AND 1=0" {
		t.Fatal("zero-grant scope must deny")
	}
}
