package backup

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

func createPreviewDB(t *testing.T, filename string, statements ...string) []byte {
	t.Helper()
	db, err := sql.Open("sqlite3", filename)
	if err != nil {
		t.Fatal(err)
	}
	if len(statements) == 0 {
		// Force SQLite to create a valid tableless database for legacy-stage tests.
		if _, err := db.Exec(`CREATE TABLE __preview_empty(id INTEGER)`); err != nil {
			db.Close()
			t.Fatal(err)
		}
		if _, err := db.Exec(`DROP TABLE __preview_empty`); err != nil {
			db.Close()
			t.Fatal(err)
		}
	}
	for _, statement := range statements {
		if _, err := db.Exec(statement); err != nil {
			db.Close()
			t.Fatalf("exec %q: %v", statement, err)
		}
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filename)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func writePreviewStage(t *testing.T, dataDir, stageName string, files map[string][]byte) {
	t.Helper()
	stageDir := filepath.Join(dataDir, stageName)
	if err := os.Mkdir(stageDir, 0700); err != nil {
		t.Fatal(err)
	}
	entries := make([]File, 0, len(files))
	for name, data := range files {
		if err := os.WriteFile(filepath.Join(stageDir, name), data, 0600); err != nil {
			t.Fatal(err)
		}
		digest := sha256.Sum256(data)
		entries = append(entries, File{Path: name, Size: int64(len(data)), SHA256: hex.EncodeToString(digest[:])})
	}
	raw, err := json.Marshal(entries)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stageDir, "metadata-manifest.json"), raw, 0600); err != nil {
		t.Fatal(err)
	}
}

func TestPreviewStagedMetadataReportsOnlyCountsAndLeavesCurrentDatabaseUntouched(t *testing.T) {
	dataDir := t.TempDir()
	if err := os.Chmod(dataDir, 0700); err != nil {
		t.Fatal(err)
	}
	currentFiles := map[string][]byte{
		"accounts.sqlite": createPreviewDB(t, filepath.Join(dataDir, "accounts.sqlite"),
			`CREATE TABLE users(id INTEGER,username TEXT,password_hash BLOB)`,
			`INSERT INTO users VALUES(1,'private-current-user',x'7365637265742d68617368')`,
			`CREATE TABLE file_grants(user_id INTEGER,path TEXT)`, `INSERT INTO file_grants VALUES(1,'/private/current')`,
			`CREATE TABLE root_file_grants(user_id INTEGER,root_id TEXT,path TEXT)`,
			`INSERT INTO root_file_grants VALUES(1,'0123456789abcdef0123456789abcdef','.')`,
			`CREATE TABLE sessions(id BLOB)`, `INSERT INTO sessions VALUES(x'7365637265742d73657373696f6e')`,
			`CREATE TABLE file_shares(id BLOB)`, `INSERT INTO file_shares VALUES(x'7365637265742d7368617265')`,
			`CREATE TABLE root_file_shares(id BLOB)`, `INSERT INTO root_file_shares VALUES(x'7365637265742d726f6f742d7368617265')`),
		"gallery.sqlite": createPreviewDB(t, filepath.Join(dataDir, "gallery.sqlite"),
			`CREATE TABLE assets(id INTEGER)`, `INSERT INTO assets VALUES(1),(2),(3)`,
			`CREATE TABLE albums(id INTEGER)`, `INSERT INTO albums VALUES(1),(2)`,
			`CREATE TABLE private_albums(id INTEGER)`, `INSERT INTO private_albums VALUES(1)`,
			`CREATE TABLE private_album_items(id INTEGER)`, `INSERT INTO private_album_items VALUES(1),(2)`,
			`CREATE TABLE personal_favorites(id INTEGER)`, `INSERT INTO personal_favorites VALUES(1),(2),(3)`),
		"cinema.sqlite": createPreviewDB(t, filepath.Join(dataDir, "cinema.sqlite"),
			`CREATE TABLE films(id INTEGER,manual_title INTEGER)`, `INSERT INTO films VALUES(1,0),(2,1)`),
		"tasks.sqlite": createPreviewDB(t, filepath.Join(dataDir, "tasks.sqlite"),
			`CREATE TABLE task_journal(id INTEGER)`, `INSERT INTO task_journal VALUES(1),(2)`,
			`CREATE TABLE task_runs(id INTEGER)`, `INSERT INTO task_runs VALUES(1)`),
	}
	currentHashes := map[string][]byte{}
	for name := range currentFiles {
		currentHashes[name], _ = os.ReadFile(filepath.Join(dataDir, name))
	}

	stageName := "LightIsle-RestoredMetadata-preview-counts"
	stageDir := t.TempDir()
	stageFiles := map[string][]byte{
		"accounts.sqlite": createPreviewDB(t, filepath.Join(stageDir, "accounts.sqlite"),
			`CREATE TABLE users(id INTEGER,username TEXT,password_hash BLOB)`,
			`INSERT INTO users VALUES(1,'private-staged-user',x'616e6f746865722d736563726574')`,
			`INSERT INTO users VALUES(2,'private-staged-user-2',x'616e6f746865722d736563726574')`,
			`CREATE TABLE file_grants(user_id INTEGER,path TEXT)`, `INSERT INTO file_grants VALUES(1,'/private/staged')`,
			`CREATE TABLE root_file_grants(user_id INTEGER,root_id TEXT,path TEXT)`,
			`INSERT INTO root_file_grants VALUES(1,'0123456789abcdef0123456789abcdef','.'), (2,'0123456789abcdef0123456789abcdef','photos')`,
			`CREATE TABLE root_file_shares(id BLOB)`),
		"gallery.sqlite": createPreviewDB(t, filepath.Join(stageDir, "gallery.sqlite"),
			`CREATE TABLE assets(id INTEGER)`, `INSERT INTO assets VALUES(1)`,
			`CREATE TABLE albums(id INTEGER)`, `INSERT INTO albums VALUES(1)`,
			`CREATE TABLE private_albums(id INTEGER)`, `INSERT INTO private_albums VALUES(1),(2)`,
			`CREATE TABLE private_album_items(id INTEGER)`, `INSERT INTO private_album_items VALUES(1)`,
			`CREATE TABLE personal_favorites(id INTEGER)`, `INSERT INTO personal_favorites VALUES(1)`),
		"cinema.sqlite": createPreviewDB(t, filepath.Join(stageDir, "cinema.sqlite"),
			`CREATE TABLE films(id INTEGER,manual_title INTEGER)`, `INSERT INTO films VALUES(1,1),(2,1),(3,0)`),
		"tasks.sqlite": createPreviewDB(t, filepath.Join(stageDir, "tasks.sqlite"),
			`CREATE TABLE task_journal(id INTEGER)`, `INSERT INTO task_journal VALUES(1)`,
			`CREATE TABLE task_runs(id INTEGER)`, `INSERT INTO task_runs VALUES(1),(2),(3),(4)`),
	}
	writePreviewStage(t, dataDir, stageName, stageFiles)

	preview, err := PreviewStagedMetadata(context.Background(), dataDir, stageName)
	if err != nil {
		t.Fatal(err)
	}
	if !preview.Verified || preview.Status != "ready" || !validSHA256(preview.ManifestSHA256) {
		t.Fatalf("preview not ready: %+v", preview)
	}
	for key, want := range map[string][3]int64{
		"accounts.users": {1, 2, 1}, "accounts.fileGrants": {1, 1, 0}, "accounts.rootFileGrants": {1, 2, 1},
		"accounts.rootFileShares": {1, 0, -1},
		"gallery.privateAlbums":   {1, 2, 1}, "gallery.privateAlbumItems": {2, 1, -1},
		"gallery.favorites": {3, 1, -2}, "gallery.manualAlbums": {2, 1, -1}, "gallery.indexedAssets": {3, 1, -2},
		"cinema.manualTitles": {1, 2, 1}, "cinema.indexedFilms": {2, 3, 1},
		"tasks.journal": {2, 1, -1}, "tasks.history": {1, 4, 3},
	} {
		got := preview.Counts[key]
		if got.Current == nil || got.Staged == nil || got.Delta == nil ||
			*got.Current != want[0] || *got.Staged != want[1] || *got.Delta != want[2] {
			t.Errorf("%s count = %+v, want %v", key, got, want)
		}
	}
	raw, err := json.Marshal(preview)
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{"private-current-user", "private-staged-user", "secret-hash", "secret-session", "secret-share", dataDir, stageName, "password_hash"} {
		if strings.Contains(string(raw), secret) {
			t.Fatalf("preview leaked sensitive value %q", secret)
		}
	}
	for name, before := range currentHashes {
		after, err := os.ReadFile(filepath.Join(dataDir, name))
		if err != nil || string(after) != string(before) {
			t.Fatalf("preview changed current %s: %v", name, err)
		}
	}
}

func TestPreviewStagedMetadataKeepsMissingTablesUnknownForOldStages(t *testing.T) {
	dataDir := t.TempDir()
	if err := os.Chmod(dataDir, 0700); err != nil {
		t.Fatal(err)
	}
	createPreviewDB(t, filepath.Join(dataDir, "accounts.sqlite"))
	before, err := os.ReadFile(filepath.Join(dataDir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	stageTemp := t.TempDir()
	files := map[string][]byte{
		"accounts.sqlite": createPreviewDB(t, filepath.Join(stageTemp, "accounts.sqlite")),
		"gallery.sqlite":  createPreviewDB(t, filepath.Join(stageTemp, "gallery.sqlite")),
	}
	stageName := "LightIsle-RestoredMetadata-old-schema"
	writePreviewStage(t, dataDir, stageName, files)
	ctx, cancel := context.WithTimeout(context.Background(), time.Nanosecond)
	defer cancel()
	<-ctx.Done()
	if _, err := PreviewStagedMetadata(ctx, dataDir, stageName); err == nil {
		t.Fatal("expired preview context was ignored")
	}

	preview, err := PreviewStagedMetadata(context.Background(), dataDir, stageName)
	if err != nil {
		t.Fatal(err)
	}
	if !preview.Verified || preview.Status != "ready" {
		t.Fatalf("old no-table stage was rejected: %+v", preview)
	}
	for key, count := range preview.Counts {
		if count.Current != nil || count.Staged != nil || count.Delta != nil {
			t.Errorf("missing table %s was not unknown: %+v", key, count)
		}
	}
	if !containsWarning(preview.Warnings, "some_counts_unknown_for_legacy_schema") {
		t.Fatalf("missing unknown-count warning: %+v", preview.Warnings)
	}
	after, err := os.ReadFile(filepath.Join(dataDir, "accounts.sqlite"))
	if err != nil || string(before) != string(after) {
		t.Fatalf("readonly preview modified current database: %v", err)
	}
}

func containsWarning(warnings []string, want string) bool {
	for _, warning := range warnings {
		if warning == want {
			return true
		}
	}
	return false
}
