package cinema

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestParseTrackInfoExtractsChaptersAndSkipIntro(t *testing.T) {
	raw := []byte(`{
		"streams": [{"index": 0, "codec_type": "video", "codec_name": "h264", "width": 1920, "height": 1080}],
		"format": {"duration": "2700.0"},
		"chapters": [
			{"id": 0, "start_time": "0.000", "end_time": "90.000", "tags": {"title": "Opening Credits"}},
			{"id": 1, "start_time": "90.000", "end_time": "2550.000", "tags": {"title": "Main Story"}},
			{"id": 2, "start_time": "2550.000", "end_time": "2700.000", "tags": {"title": "片尾曲"}}
		]
	}`)
	info, err := parseTrackInfo(raw)
	if err != nil {
		t.Fatalf("parseTrackInfo failed: %v", err)
	}
	if len(info.Chapters) != 3 {
		t.Fatalf("expected 3 chapters, got %d", len(info.Chapters))
	}
	if info.Chapters[0].Kind != "intro" || info.Chapters[0].EndSeconds != 90 {
		t.Fatalf("expected intro chapter ending at 90s, got %+v", info.Chapters[0])
	}
	if info.Chapters[1].Kind != "chapter" {
		t.Fatalf("expected normal chapter, got %+v", info.Chapters[1])
	}
	if info.Chapters[2].Kind != "credits" {
		t.Fatalf("expected credits chapter, got %+v", info.Chapters[2])
	}
}

func TestCinemaCollectionsCRUDAndScopeIsolation(t *testing.T) {
	dataDir := t.TempDir()
	fm, err := files.NewManager(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	defer fm.Close()
	shareDir := filepath.Join(dataDir, "SharedFiles")
	if err := os.MkdirAll(filepath.Join(shareDir, "Kids"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(shareDir, "Adults"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(shareDir, "Kids", "Totoro.mp4"), []byte("video1"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(shareDir, "Adults", "Inception.mp4"), []byte("video2"), 0600); err != nil {
		t.Fatal(err)
	}
	lib, err := Open(dataDir, fm)
	if err != nil {
		t.Fatal(err)
	}
	defer lib.Close()

	if err := lib.StartScan(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for lib.Status().Running && time.Now().Before(deadline) {
		time.Sleep(15 * time.Millisecond)
	}
	allFilms, _, err := lib.List(1, "all", "", 20, 0)
	if err != nil || len(allFilms) != 2 {
		t.Fatalf("expected 2 films, got %d (%v)", len(allFilms), err)
	}

	col, err := lib.CreateCollection("周末合家欢", "适合全家人一起看")
	if err != nil {
		t.Fatalf("CreateCollection failed: %v", err)
	}
	for _, f := range allFilms {
		if err := lib.AddFilmToCollection(col.ID, f.ID); err != nil {
			t.Fatalf("AddFilmToCollection failed: %v", err)
		}
	}

	// Admin sees both films in collection; restricted member scoped to "Kids" sees only 1.
	adminCols, err := lib.ListCollectionsScoped([]string{"."})
	if err != nil || len(adminCols) != 1 || adminCols[0].Count != 2 {
		t.Fatalf("unexpected admin collections: %+v (%v)", adminCols, err)
	}
	kidCols, err := lib.ListCollectionsScoped([]string{"Kids"})
	if err != nil || len(kidCols) != 1 || kidCols[0].Count != 1 {
		t.Fatalf("expected scoped member to see count=1, got %+v (%v)", kidCols, err)
	}
	kidFilms, err := lib.ListCollectionFilmsScoped(2, col.ID, []string{"Kids"})
	if err != nil || len(kidFilms) != 1 || kidFilms[0].Path != "Kids/Totoro.mp4" {
		t.Fatalf("expected scoped member to see only Kids film, got %+v (%v)", kidFilms, err)
	}

	if err := lib.DeleteCollection(col.ID); err != nil {
		t.Fatalf("DeleteCollection failed: %v", err)
	}
}
