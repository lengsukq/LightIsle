package cinema

import (
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
)

func newScrapeTestLibrary(t *testing.T) (*Library, *files.Manager, string) {
	t.Helper()
	base := t.TempDir()
	fs, err := files.NewManager(base)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { fs.Close() })
	lib, err := Open(base, fs)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { lib.Close() })
	share := filepath.Join(base, "SharedFiles")
	return lib, fs, share
}

func writeShow(t *testing.T, share, name string, episodes []string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(share, name), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, episode := range episodes {
		if err := os.WriteFile(filepath.Join(share, name, episode), []byte("video"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

func scanAndWait(t *testing.T, lib *Library) {
	t.Helper()
	if err := lib.StartScan(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(8 * time.Second)
	for lib.Status().Running && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	status := lib.Status()
	if status.Running || status.LastError != "" {
		t.Fatalf("scan: %+v", status)
	}
}

func TestSeriesAggregationAndNextUp(t *testing.T) {
	lib, _, share := newScrapeTestLibrary(t)
	writeShow(t, share, "Demo Show", []string{"Demo.Show.S01E01.mkv", "Demo.Show.S01E02.mkv", "Demo.Show.S02E01.mkv"})
	writeShow(t, share, "Idle Show", []string{"Idle.Show.S01E01.mkv"})
	scanAndWait(t, lib)

	series, err := lib.ListSeries(1, 60, []string{"."})
	if err != nil {
		t.Fatal(err)
	}
	if len(series) != 2 {
		t.Fatalf("series list: %+v", series)
	}
	byName := map[string]Series{}
	for _, s := range series {
		byName[s.Name] = s
	}
	demo, ok := byName["Demo Show"]
	if !ok || demo.EpisodeCount != 3 {
		t.Fatalf("Demo Show: %+v", demo)
	}
	if demo.WatchedCount != 0 || demo.InProgress || demo.NextFilmID == 0 {
		t.Fatalf("fresh Demo Show progress: %+v", demo)
	}
	// Watch episode 1 fully, start episode 2 partially.
	episodes, _, err := lib.seriesFilms(1, demo.ID, 20, 0, []string{"."})
	if err != nil || len(episodes) != 3 {
		t.Fatalf("episodes: %+v %v", episodes, err)
	}
	if err := lib.SaveProgress(1, episodes[0].ID, 100, 100, true); err != nil {
		t.Fatal(err)
	}
	if err := lib.SaveProgress(1, episodes[1].ID, 45, 100, false); err != nil {
		t.Fatal(err)
	}
	refreshed, err := lib.ListSeries(1, 60, []string{"."})
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range refreshed {
		if s.Name == "Demo Show" {
			if s.WatchedCount != 1 || !s.InProgress || s.NextFilmID != episodes[1].ID || s.Position != 45 {
				t.Fatalf("Demo Show next-up: %+v (want episode %d)", s, episodes[1].ID)
			}
		}
		if s.Name == "Idle Show" && (s.InProgress || s.WatchedCount != 0) {
			t.Fatalf("Idle Show: %+v", s)
		}
	}
	detail, films, err := lib.GetSeries(1, demo.ID, []string{"."})
	if err != nil || len(films) != 3 || detail.EpisodeCount != 3 {
		t.Fatalf("GetSeries: %+v %+v %v", detail, films, err)
	}
	// Episode order follows season/episode, not insertion order.
	if films[0].Season != 1 || films[0].Episode != 1 || films[2].Season != 2 {
		t.Fatalf("episode order: %+v", films)
	}
	// Unknown series id is an honest miss.
	if _, _, err := lib.GetSeries(1, 9999, []string{"."}); !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("unknown series error = %v", err)
	}
}

func TestSeriesPrunedWhenEpisodesVanish(t *testing.T) {
	lib, _, share := newScrapeTestLibrary(t)
	writeShow(t, share, "Doomed Show", []string{"Doomed.Show.S01E01.mkv"})
	scanAndWait(t, lib)
	series, err := lib.ListSeries(1, 60, []string{"."})
	if err != nil || len(series) != 1 {
		t.Fatalf("initial series: %+v %v", series, err)
	}
	if err := os.RemoveAll(filepath.Join(share, "Doomed Show")); err != nil {
		t.Fatal(err)
	}
	scanAndWait(t, lib)
	series, err = lib.ListSeries(1, 60, []string{"."})
	if err != nil || len(series) != 0 {
		t.Fatalf("series after prune: %+v %v", series, err)
	}
}
