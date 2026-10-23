package cinema

import (
	"database/sql"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
)

func waitMetadataScan(t *testing.T, l *Library) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for l.Status().Running && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if result := l.Status(); result.Running || result.LastError != "" {
		t.Fatalf("scan failed: %+v", result)
	}
}
func TestLegacyRichMetadataDoesNotFabricateTitleProvenance(t *testing.T) {
	dir := t.TempDir()
	store, err := files.NewManager(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := os.WriteFile(filepath.Join(dir, "SharedFiles", "Filename.2026.mp4"), []byte("movie"), 0600); err != nil {
		t.Fatal(err)
	}
	lib, err := Open(dir, store)
	if err != nil {
		t.Fatal(err)
	}
	if err := lib.StartScan(); err != nil {
		t.Fatal(err)
	}
	waitMetadataScan(t, lib)
	if _, err := lib.db.Exec(`UPDATE films SET title='旧版确认的片名',title_source='',metadata_source='tmdb:movie:333'`); err != nil {
		t.Fatal(err)
	}
	if err := lib.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := Open(dir, store)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	list, _, err := reopened.List(1, "movie", "", 10, 0)
	if err != nil || len(list) != 1 || list[0].TitleSource != "legacy-confirmed" || list[0].MetadataSource != "tmdb:movie:333" {
		t.Fatalf("previous Beta mislabeled title source: %+v %v", list, err)
	}
	if err := reopened.StartScan(); err != nil {
		t.Fatal(err)
	}
	waitMetadataScan(t, reopened)
	checked, err := reopened.Get(list[0].ID, 0)
	if err != nil || checked.Title != "旧版确认的片名" {
		t.Fatalf("legacy title overwritten: %+v %v", checked, err)
	}
}

func TestConfirmedTitleAndYearSurviveRescanAndRichMetadataSource(t *testing.T) {
	dir := t.TempDir()
	store, err := files.NewManager(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := os.WriteFile(filepath.Join(dir, "SharedFiles", "Movie.2026.mp4"), []byte("original"), 0600); err != nil {
		t.Fatal(err)
	}
	lib, err := Open(dir, store)
	if err != nil {
		t.Fatal(err)
	}
	defer lib.Close()
	if err := lib.StartScan(); err != nil {
		t.Fatal(err)
	}
	waitMetadataScan(t, lib)
	items, _, err := lib.List(1, "movie", "", 10, 0)
	if err != nil || len(items) != 1 {
		t.Fatalf("items=%+v %v", items, err)
	}
	film := items[0]
	selected := TMDBCandidate{ID: 42, Kind: "movie", Title: "TMDB 官方片名", Overview: "Verified summary", Rating: 7.2}
	if err := lib.applyTMDB(film, selected); err != nil {
		t.Fatal(err)
	}
	tmdb, err := lib.Get(film.ID, 1)
	if err != nil || tmdb.Title != "TMDB 官方片名" || tmdb.TitleSource != "tmdb:movie:42" {
		t.Fatalf("TMDB selection lost: %+v %v", tmdb, err)
	}
	if err := lib.StartScan(); err != nil {
		t.Fatal(err)
	}
	waitMetadataScan(t, lib)
	rescanned, err := lib.Get(film.ID, 1)
	if err != nil || rescanned.Title != tmdb.Title || rescanned.MetadataSource != "tmdb:movie:42" {
		t.Fatalf("TMDB filename rescan overwrote title: %+v %v", rescanned, err)
	}
	if err := lib.applyDoubanSuggestion(rescanned, DoubanCandidate{ID: "1234567", Title: "豆瓣选定片名", Year: "1998", Kind: "movie"}); err != nil {
		t.Fatal(err)
	}
	updated, err := lib.Get(film.ID, 1)
	if err != nil || updated.Title != "豆瓣选定片名" || updated.Year != 1998 ||
		updated.TitleSource != "douban-suggest:1234567" || updated.YearSource != "douban-suggest:1234567" ||
		updated.MetadataSource != "tmdb:movie:42" || updated.Overview != "Verified summary" {
		t.Fatalf("mixed-source metadata incorrectly attributed: %+v %v", updated, err)
	}
	if err := lib.StartScan(); err != nil {
		t.Fatal(err)
	}
	waitMetadataScan(t, lib)
	final, err := lib.Get(film.ID, 1)
	if err != nil || final.Title != updated.Title || final.Year != 1998 || final.MetadataSource != updated.MetadataSource {
		t.Fatalf("confirmed match overwritten after scan: %+v %v", final, err)
	}
}

func TestPriorBetaDatabaseSourceMigrationPreservesConfirmedTitle(t *testing.T) {
	dir := t.TempDir()
	store, err := files.NewManager(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := os.WriteFile(filepath.Join(dir, "SharedFiles", "Filename.2026.mp4"), []byte("oldfilm"), 0600); err != nil {
		t.Fatal(err)
	}
	// Create an ordinary old database through the previous schema, then
	// emulate a persisted confirmed title from a previous Beta install.
	lib, err := Open(dir, store)
	if err != nil {
		t.Fatal(err)
	}
	if err := lib.StartScan(); err != nil {
		t.Fatal(err)
	}
	waitMetadataScan(t, lib)
	if _, err := lib.db.Exec(`UPDATE films SET title='曾确认的旧片名',year=1994,metadata_source='douban-suggest:98222'`); err != nil {
		t.Fatal(err)
	}
	if err := lib.Close(); err != nil {
		t.Fatal(err)
	}
	// Simulate pre-upgrade SQL shape by copying only the historic columns.
	db, err := sql.Open("sqlite3", filepath.Join(dir, "cinema.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec(`UPDATE films SET title_source='',year_source=''`); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	next, err := Open(dir, store)
	if err != nil {
		t.Fatal(err)
	}
	defer next.Close()
	films, _, err := next.List(1, "movie", "", 10, 0)
	if err != nil || len(films) != 1 {
		t.Fatalf("migrated record %+v %v", films, err)
	}
	if films[0].TitleSource != "douban-suggest:98222" || films[0].YearSource != "douban-suggest:98222" ||
		films[0].MetadataSource != "" {
		t.Fatalf("old source migration: %+v", films[0])
	}
	if err := next.StartScan(); err != nil {
		t.Fatal(err)
	}
	waitMetadataScan(t, next)
	after, err := next.Get(films[0].ID, 0)
	if err != nil || after.Title != "曾确认的旧片名" || after.Year != 1994 {
		t.Fatalf("migration title lost %+v %v", after, err)
	}
}
