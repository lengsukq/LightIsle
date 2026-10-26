package migrationpreview

import (
	"context"
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/cinema"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/gallery"
	"github.com/lengsukq/lightisle/core/internal/roots"
	_ "github.com/mattn/go-sqlite3"
)

type previewFixture struct {
	dataDir  string
	store    *files.Manager
	registry *roots.Registry
}

func newPreviewFixture(t *testing.T, legacyPending bool) previewFixture {
	t.Helper()
	data := t.TempDir()
	manager, err := files.NewManager(data)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = manager.Close() })
	users, err := auth.Open(filepath.Join(data, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = users.Close() })
	if err := users.Setup("owner", "long-owner-password"); err != nil {
		t.Fatal(err)
	}
	admin, err := users.Login("owner", "long-owner-password")
	if err != nil {
		t.Fatal(err)
	}
	member, err := users.CreateUser(admin, "member", "member-password-1234", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	if err := users.SetFileGrant(admin, member.ID, ".", false); err != nil {
		t.Fatal(err)
	}
	photoLibrary, err := gallery.Open(data, manager)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = photoLibrary.Close() })
	cinemaLibrary, err := cinema.Open(data, manager)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cinemaLibrary.Close() })
	path, online := manager.State()
	if !online {
		t.Fatal("fresh shared files must be available")
	}
	if legacyPending {
		bytes, err := json.Marshal(map[string]string{"path": path})
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(data, "shared-root.json"), bytes, 0600); err != nil {
			t.Fatal(err)
		}
	}
	registry, err := roots.Open(data)
	if err != nil {
		t.Fatal(err)
	}
	// Populate actual v1 SQLite state with no filesystem writes to user data.
	withSQLite(t, filepath.Join(data, "gallery.sqlite"), func(db *sql.DB) {
		if _, err := db.Exec("INSERT INTO assets(share,path,type,size,modified,taken_at,seen,favorite) VALUES(?,?,?,?,?,?,?,?)", path, "old.jpg", "photo", 10, 1, 1, 1, 0); err != nil {
			t.Fatal(err)
		}
		if _, err := db.Exec("INSERT INTO private_albums(share,user_id,name) VALUES(?,?,?)", path, member.ID, "Private"); err != nil {
			t.Fatal(err)
		}
		if _, err := db.Exec("INSERT INTO private_album_items(album_id,asset_id) VALUES(1,1)"); err != nil {
			t.Fatal(err)
		}
		if _, err := db.Exec("INSERT INTO personal_favorites(user_id,asset_id) VALUES(?,1)", member.ID); err != nil {
			t.Fatal(err)
		}
	})
	withSQLite(t, filepath.Join(data, "cinema.sqlite"), func(db *sql.DB) {
		if _, err := db.Exec("INSERT INTO films(share,path,title,kind,size,modified,seen) VALUES(?,?,?,?,?,?,?)", path, "movie.mkv", "Movie", "movie", 20, 1, 1); err != nil {
			t.Fatal(err)
		}
		if _, err := db.Exec("INSERT INTO watch_progress(user_id,film_id,position,duration,updated_at) VALUES(?,1,30,90,1)", member.ID); err != nil {
			t.Fatal(err)
		}
	})
	return previewFixture{dataDir: data, store: manager, registry: registry}
}

func withSQLite(t *testing.T, name string, run func(*sql.DB)) {
	t.Helper()
	db, err := sql.Open("sqlite3", name)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	run(db)
}

func hasBlocker(blockers []string, code string) bool {
	for _, blocker := range blockers {
		if blocker == code {
			return true
		}
	}
	return false
}

func TestLegacyMigrationPreviewCountsAndVerifiesOriginalPhysicalDirectory(t *testing.T) {
	fixture := newPreviewFixture(t, false)
	// A previous share may have left rows behind in the shared v1 SQLite
	// databases. They must not be relabeled as the verified physical root.
	withSQLite(t, filepath.Join(fixture.dataDir, "gallery.sqlite"), func(db *sql.DB) {
		if _, err := db.Exec("INSERT INTO assets(share,path,type,size,modified,taken_at,seen,favorite) VALUES(?,?,?,?,?,?,?,?)",
			"/Volumes/disconnected/old-photo-share", "unrelated.jpg", "photo", 10, 1, 1, 1, 0); err != nil {
			t.Fatal(err)
		}
		if _, err := db.Exec("INSERT INTO private_albums(share,user_id,name) VALUES(?,?,?)",
			"/Volumes/disconnected/old-photo-share", 2, "Other Disk"); err != nil {
			t.Fatal(err)
		}
	})
	withSQLite(t, filepath.Join(fixture.dataDir, "cinema.sqlite"), func(db *sql.DB) {
		if _, err := db.Exec("INSERT INTO films(share,path,title,kind,size,modified,seen) VALUES(?,?,?,?,?,?,?)",
			"/Volumes/disconnected/old-video-share", "other.mkv", "Other Movie", "movie", 20, 1, 1); err != nil {
			t.Fatal(err)
		}
	})
	report, err := Build(context.Background(), fixture.dataDir, fixture.registry, fixture.store)
	if err != nil {
		t.Fatal(err)
	}
	if !report.LegacyRootFound || report.Pending || !report.PhysicalRootVerified || report.CanApply {
		t.Fatalf("unexpected migration eligibility: %+v", report)
	}
	if report.Counts.Members != 1 || report.Counts.FileGrants != 1 ||
		report.Counts.Photos != 2 || report.Counts.PrivateAlbums != 2 ||
		report.Counts.PrivateAlbumItems != 1 || report.Counts.PersonalFavorites != 1 ||
		report.Counts.Films != 2 || report.Counts.WatchProgress != 1 {
		t.Fatalf("legacy inventory is missing data: %+v", report.Counts)
	}
	if report.Scoped == nil || report.Scoped.Photos != 1 || report.Scoped.PrivateAlbums != 1 ||
		report.Scoped.PrivateAlbumItems != 1 || report.Scoped.PersonalFavorites != 1 ||
		report.Scoped.Films != 1 || report.Scoped.WatchProgress != 1 ||
		report.Scoped.OtherPhotos != 1 || report.Scoped.OtherFilms != 1 {
		t.Fatalf("scoped media inventory included unrelated former disk: %+v", report.Scoped)
	}
	if !hasBlocker(report.Blockers, "legacy_mapping_and_owner_approval_required") {
		t.Fatalf("migration auto-promotion was not blocked: %+v", report.Blockers)
	}
	serialized, err := json.Marshal(report)
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{fixture.dataDir, "old.jpg", "movie.mkv", "unrelated.jpg", "/Volumes/disconnected", "Private", "Other Disk", "member-password-1234"} {
		if strings.Contains(string(serialized), secret) {
			t.Fatalf("owner preview leaked private metadata: %s", secret)
		}
	}
}

func TestLegacyMigrationPreviewNeverApprovesUnboundLegacyPath(t *testing.T) {
	fixture := newPreviewFixture(t, true)
	report, err := Build(context.Background(), fixture.dataDir, fixture.registry, fixture.store)
	if err != nil {
		t.Fatal(err)
	}
	if !report.LegacyRootFound || !report.Pending || report.PhysicalRootVerified || report.CanApply ||
		!hasBlocker(report.Blockers, "legacy_physical_root_unverified") {
		t.Fatalf("unbound path was incorrectly considered safe: %+v", report)
	}
	if report.Scoped != nil {
		t.Fatal("unbound legacy root may not report scoped media as physically verified")
	}
	if report.Counts.WatchProgress != 1 || report.Counts.PrivateAlbums != 1 {
		t.Fatalf("pending root hid old metadata: %+v", report.Counts)
	}
}

func TestLegacyMigrationPreviewFailsClosedForMissingSQLite(t *testing.T) {
	fixture := newPreviewFixture(t, false)
	// A missing legacy DB cannot become an empty migratable inventory.
	if err := os.Remove(filepath.Join(fixture.dataDir, "gallery.sqlite")); err != nil {
		t.Fatal(err)
	}
	if _, err := Build(context.Background(), fixture.dataDir, fixture.registry, fixture.store); err == nil {
		t.Fatal("missing legacy gallery.sqlite was presented as an empty migration")
	}
	if _, err := os.Stat(filepath.Join(fixture.dataDir, "gallery.sqlite")); !os.IsNotExist(err) {
		t.Fatalf("read-only preview recreated the absent database: %v", err)
	}
}
