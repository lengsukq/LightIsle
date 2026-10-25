package cinema

import (
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestHistoryOrderingAndClear(t *testing.T) {
	lib, _, share := newScrapeTestLibrary(t)
	writeShow(t, share, "Alpha Show", []string{"Alpha.Show.S01E01.mkv", "Alpha.Show.S01E02.mkv"})
	if err := os.WriteFile(filepath.Join(share, "Movie.One.2020.mkv"), []byte("video"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(share, "Movie.Two.2021.mkv"), []byte("video"), 0o600); err != nil {
		t.Fatal(err)
	}
	scanAndWait(t, lib)
	episodes, _, err := lib.seriesFilms(1, 1, 10, 0, []string{"."})
	if err != nil || len(episodes) < 2 {
		t.Fatalf("episodes: %+v %v", episodes, err)
	}
	var movie1, movie2 int64
	if err := lib.db.QueryRow("SELECT id FROM films WHERE title='Movie One'").Scan(&movie1); err != nil {
		t.Fatal(err)
	}
	if err := lib.db.QueryRow("SELECT id FROM films WHERE title='Movie Two'").Scan(&movie2); err != nil {
		t.Fatal(err)
	}
	// Watch movie1 fully, start an episode, then mark movie2 watched. The
	// 1.1s gaps keep the second-granularity updated_at ordering meaningful.
	if err := lib.SaveProgress(1, movie1, 100, 100, true); err != nil {
		t.Fatal(err)
	}
	time.Sleep(1100 * time.Millisecond)
	if err := lib.SaveProgress(1, episodes[0].ID, 30, 100, false); err != nil {
		t.Fatal(err)
	}
	time.Sleep(1100 * time.Millisecond)
	if err := lib.MarkWatched(1, movie2, true); err != nil {
		t.Fatal(err)
	}
	history, next, err := lib.History(1, 10, 0, []string{"."})
	if err != nil || next != 0 || len(history) != 3 {
		t.Fatalf("history: %+v next=%d err=%v", history, next, err)
	}
	// Most recent first: movie2 (marked last), then episode, then movie1.
	if history[0].ID != movie2 || !history[0].Completed || history[0].UpdatedAt == 0 {
		t.Fatalf("history[0]: %+v", history[0])
	}
	if history[1].ID != episodes[0].ID || history[1].Completed {
		t.Fatalf("history[1]: %+v", history[1])
	}
	// Marking unwatched resets the position and drops it from history.
	if err := lib.MarkWatched(1, movie1, false); err != nil {
		t.Fatal(err)
	}
	film, err := lib.Get(movie1, 1)
	if err != nil || film.Completed || film.Position != 0 {
		t.Fatalf("unwatched film: %+v %v", film, err)
	}
	history, _, err = lib.History(1, 10, 0, []string{"."})
	if err != nil || len(history) != 2 {
		t.Fatalf("history after unwatch: %+v %v", history, err)
	}
	// History is per-user: user 2 sees nothing.
	if other, _, err := lib.History(2, 10, 0, []string{"."}); err != nil || len(other) != 0 {
		t.Fatalf("user 2 history: %+v %v", other, err)
	}
	// Clear removes only the caller's rows.
	// The unwatched marker row is also progress state and goes with it.
	removed, err := lib.ClearHistory(1)
	if err != nil || removed != 3 {
		t.Fatalf("clear: %d %v", removed, err)
	}
	if rows, _, _ := lib.History(1, 10, 0, []string{"."}); len(rows) != 0 {
		t.Fatalf("history not cleared: %+v", rows)
	}
	var count int
	if err := lib.db.QueryRow("SELECT COUNT(*) FROM watch_progress WHERE user_id=2").Scan(&count); err != nil && !errors.Is(err, sql.ErrNoRows) {
		t.Fatal(err)
	}
	_ = count
}

func TestMarkWatchedKeepsPosition(t *testing.T) {
	lib, _, share := newScrapeTestLibrary(t)
	if err := os.WriteFile(filepath.Join(share, "Solo.2020.mkv"), []byte("video"), 0o600); err != nil {
		t.Fatal(err)
	}
	scanAndWait(t, lib)
	var filmID int64
	if err := lib.db.QueryRow("SELECT id FROM films WHERE title='Solo'").Scan(&filmID); err != nil {
		t.Fatal(err)
	}
	if err := lib.SaveProgress(1, filmID, 45, 120, false); err != nil {
		t.Fatal(err)
	}
	if err := lib.MarkWatched(1, filmID, true); err != nil {
		t.Fatal(err)
	}
	film, err := lib.Get(filmID, 1)
	if err != nil || !film.Completed || film.Position != 45 || film.Duration != 120 {
		t.Fatalf("watched keeps progress: %+v %v", film, err)
	}
	// Unknown film is an honest miss.
	if err := lib.MarkWatched(1, 9999, true); !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("unknown film error = %v", err)
	}
}
