package gallery

import (
	"database/sql"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
	_ "github.com/mattn/go-sqlite3"
)

func openRawLibrary(path string) (*sql.DB, error) {
	return sql.Open("sqlite3", path)
}

func setModifiedTime(path string, moment time.Time) error {
	return os.Chtimes(path, moment, moment)
}

// waitForBackfill polls until the background backfill visibly upgrades the
// legacy row (its location appears) or the deadline hits.
func waitForBackfill(t *testing.T, library *Library) Asset {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		assets, _, err := library.List(0, 10, 0, false)
		if err != nil {
			t.Fatal(err)
		}
		if len(assets) == 1 && assets[0].Latitude != nil {
			return assets[0]
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("backfill did not upgrade the legacy row in time")
	return Asset{}
}

func TestBackfillUpgradesLegacyRowsWithCaptureMetadata(t *testing.T) {
	root := t.TempDir()
	storage, err := files.NewManager(root)
	if err != nil {
		t.Fatal(err)
	}
	defer storage.Close()
	share, _ := storage.State()

	fixture := jpegWithEXIF(fixtureEXIF())
	sharedFile := filepath.Join(root, "SharedFiles", "legacy.jpg")
	if err := writeFileForTest(sharedFile, fixture); err != nil {
		t.Fatal(err)
	}
	modified := time.Unix(1_700_000_000, 0)
	if err := setModifiedTime(sharedFile, modified); err != nil {
		t.Fatal(err)
	}

	// A row written by an older pass: no capture columns filled, version 0.
	db, err := openRawLibrary(filepath.Join(root, "gallery.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	mtime := modified.UnixNano()
	if _, err := db.Exec(`CREATE TABLE assets(
 id INTEGER PRIMARY KEY AUTOINCREMENT, share TEXT NOT NULL, path TEXT NOT NULL, type TEXT NOT NULL,
 size INTEGER NOT NULL, modified INTEGER NOT NULL, taken_at INTEGER NOT NULL,
 seen INTEGER NOT NULL DEFAULT 0, favorite INTEGER NOT NULL DEFAULT 0, UNIQUE(share,path))`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO assets(share,path,type,size,modified,taken_at,seen) VALUES(?,?,?,?,?,?,1)`,
		share, "legacy.jpg", "photo", int64(len(fixture)), mtime, mtime/1e9); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	library, err := Open(root, storage)
	if err != nil {
		t.Fatal(err)
	}
	defer library.Close()

	// The backfill must upgrade the legacy row without any rescan.
	assets, _, err := library.List(0, 10, 0, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(assets) != 1 {
		t.Fatalf("assets = %d, want 1", len(assets))
	}
	waitForBackfill(t, library)
	assets, _, err = library.List(0, 10, 0, false)
	if err != nil {
		t.Fatal(err)
	}
	asset := assets[0]
	if asset.Latitude == nil || asset.Longitude == nil {
		t.Fatalf("location not backfilled: %+v", asset)
	}
	if diff(*asset.Latitude, 31.2304) || diff(*asset.Longitude, 121.4737) {
		t.Fatalf("backfilled coordinates = (%.6f, %.6f)", *asset.Latitude, *asset.Longitude)
	}
	if asset.CameraMake != "Fixture Camera" || asset.CameraModel != "Fixture One" {
		t.Fatalf("camera metadata not backfilled: %+v", asset)
	}
	if asset.ISO != 200 || diff(asset.FNumber, 2.8) || diff(asset.FocalLength, 23) {
		t.Fatalf("exposure metadata not backfilled: %+v", asset)
	}
	captured := time.Date(2024, 3, 4, 5, 6, 7, 0, time.Local)
	if asset.TakenAt != captured.Unix() {
		t.Fatalf("taken_at = %d, want EXIF original %d", asset.TakenAt, captured.Unix())
	}

	// A later scan of the untouched file must reuse the backfilled row.
	if err := library.StartScan(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(10 * time.Second)
	for library.Status().Running && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if state := library.Status(); state.Running || state.LastError != "" {
		t.Fatalf("scan after backfill failed: %+v", state)
	}
	assets, _, err = library.List(0, 10, 0, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(assets) != 1 || assets[0].Latitude == nil || diff(*assets[0].Latitude, 31.2304) {
		t.Fatalf("scan lost backfilled row: %+v", assets)
	}
}
