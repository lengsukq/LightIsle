package cinema

import (
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestListScopedFilteredSortWatchedAndMultiKeywordSearch(t *testing.T) {
	lib, _, share := newScrapeTestLibrary(t)
	if err := os.MkdirAll(filepath.Join(share, "4K收藏"), 0o700); err != nil {
		t.Fatal(err)
	}
	for _, rel := range []string{
		"4K收藏/Wandering.Earth.2019.mkv",
		"Homeward.2022.mkv",
		"Classic.1994.mkv",
	} {
		if err := os.WriteFile(filepath.Join(share, rel), []byte("video"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	scanAndWait(t, lib)

	// Enrich titles, years, ratings, and media durations.
	var wanderingID, homewardID, classicID int64
	if err := lib.db.QueryRow(`SELECT id FROM films WHERE path LIKE '%Wandering.Earth%'`).Scan(&wanderingID); err != nil {
		t.Fatal(err)
	}
	if err := lib.db.QueryRow(`SELECT id FROM films WHERE path LIKE '%Homeward%'`).Scan(&homewardID); err != nil {
		t.Fatal(err)
	}
	if err := lib.db.QueryRow(`SELECT id FROM films WHERE path LIKE '%Classic%'`).Scan(&classicID); err != nil {
		t.Fatal(err)
	}
	if _, err := lib.db.Exec(`UPDATE films SET title='流浪地球', year=2019, rating=8.4, duration_seconds=7500 WHERE id=?`, wanderingID); err != nil {
		t.Fatal(err)
	}
	if _, err := lib.db.Exec(`UPDATE films SET title='万里归途·家', year=2022, rating=7.6, duration_seconds=6800 WHERE id=?`, homewardID); err != nil {
		t.Fatal(err)
	}
	if _, err := lib.db.Exec(`UPDATE films SET title='肖申克的救赎', year=1994, rating=9.7, duration_seconds=8520 WHERE id=?`, classicID); err != nil {
		t.Fatal(err)
	}

	// MarkWatched(true) when Duration==0 falls back to MediaDuration (7500s).
	if err := lib.MarkWatched(1, wanderingID, true); err != nil {
		t.Fatal(err)
	}
	gotWandering, err := lib.Get(wanderingID, 1)
	if err != nil || !gotWandering.Completed || gotWandering.Duration != 7500 {
		t.Fatalf("expected MediaDuration fallback 7500 on MarkWatched, got %+v err=%v", gotWandering, err)
	}

	// 1. Watched vs Unwatched filter.
	watchedOnly, _, err := lib.ListScopedFiltered(1, ListFilter{Watched: "watched"}, 20, 0, []string{"."})
	if err != nil || len(watchedOnly) != 1 || watchedOnly[0].ID != wanderingID {
		t.Fatalf("watched filter got %+v err=%v", watchedOnly, err)
	}
	unwatchedOnly, _, err := lib.ListScopedFiltered(1, ListFilter{Watched: "unwatched", Sort: "rating"}, 20, 0, []string{"."})
	if err != nil || len(unwatchedOnly) != 2 || unwatchedOnly[0].ID != classicID || unwatchedOnly[1].ID != homewardID {
		t.Fatalf("unwatched+rating sort got %+v err=%v", unwatchedOnly, err)
	}

	// 2. Sort by year descending.
	byYear, _, err := lib.ListScopedFiltered(1, ListFilter{Sort: "year"}, 20, 0, []string{"."})
	if err != nil || len(byYear) != 3 || byYear[0].ID != homewardID || byYear[1].ID != wanderingID || byYear[2].ID != classicID {
		t.Fatalf("year sort got %+v err=%v", byYear, err)
	}

	// 3. Single-char Chinese query ("家") and multi-keyword title+path AND query ("流浪 4k").
	singleChar, _, err := lib.ListScopedFiltered(1, ListFilter{Query: "家"}, 20, 0, []string{"."})
	if err != nil || len(singleChar) != 1 || singleChar[0].ID != homewardID {
		t.Fatalf("single-char query '家' got %+v err=%v", singleChar, err)
	}
	multiKw, _, err := lib.ListScopedFiltered(1, ListFilter{Query: "流浪 4K"}, 20, 0, []string{"."})
	if err != nil || len(multiKw) != 1 || multiKw[0].ID != wanderingID {
		t.Fatalf("multi-keyword title+path query '流浪 4K' got %+v err=%v", multiKw, err)
	}

	// 4. ClearFilmProgress removes progress for user 1 without touching user 2.
	if err := lib.SaveProgress(1, homewardID, 120, 6800, false); err != nil {
		t.Fatal(err)
	}
	if err := lib.SaveProgress(2, homewardID, 300, 6800, false); err != nil {
		t.Fatal(err)
	}
	if err := lib.ClearFilmProgress(1, homewardID); err != nil {
		t.Fatal(err)
	}
	u1After, _ := lib.Get(homewardID, 1)
	u2After, _ := lib.Get(homewardID, 2)
	if u1After.Position != 0 || u1After.Completed || u2After.Position != 300 {
		t.Fatalf("ClearFilmProgress isolation broken: u1=%+v u2=%+v", u1After, u2After)
	}
}

func TestSeriesContinuePriorityAndMemberScopeIsolation(t *testing.T) {
	lib, _, share := newScrapeTestLibrary(t)
	writeShow(t, share, "Users/u1/videos/SciFi", []string{
		"SciFi.S01E01.mkv",
		"SciFi.S02E04.mkv",
		"SciFi.S02E05.mkv",
	})
	scanAndWait(t, lib)

	seriesList, err := lib.ListSeriesFiltered(1, SeriesFilter{Watched: "unwatched"}, 20, []string{"Users/u1/videos"})
	if err != nil || len(seriesList) != 1 {
		t.Fatalf("initial series list: %+v err=%v", seriesList, err)
	}
	showID := seriesList[0].ID
	if seriesList[0].NextSeason != 1 || seriesList[0].NextEpisode != 1 || seriesList[0].InProgress {
		t.Fatalf("fresh show should target S01E01: %+v", seriesList[0])
	}

	// Unauthorized member (scoped to Users/u2/videos) gets sql.ErrNoRows on GetSeries!
	if _, _, err := lib.GetSeries(2, showID, []string{"Users/u2/videos"}); !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("expected sql.ErrNoRows for unauthorized GetSeries, got %v", err)
	}

	_, eps, err := lib.GetSeries(1, showID, []string{"Users/u1/videos"})
	if err != nil || len(eps) != 3 {
		t.Fatalf("GetSeries episodes: %+v err=%v", eps, err)
	}
	s02e04 := eps[1]
	s02e05 := eps[2]

	// Priority 1: User jumps straight to S02E05 (20m in, S01E01 untouched) -> must resume S02E05 (inProgress=true)!
	if err := lib.SaveProgress(1, s02e05.ID, 1200, 2700, false); err != nil {
		t.Fatal(err)
	}
	inProgSeries, err := lib.ListSeriesFiltered(1, SeriesFilter{}, 20, []string{"Users/u1/videos"})
	if err != nil || len(inProgSeries) != 1 {
		t.Fatal(err)
	}
	if inProgSeries[0].NextFilmID != s02e05.ID || inProgSeries[0].NextSeason != 2 || inProgSeries[0].NextEpisode != 5 || !inProgSeries[0].InProgress {
		t.Fatalf("expected in-progress S02E05 continue point, got %+v", inProgSeries[0])
	}

	// Clear S02E05 progress, mark S02E04 watched (while S01E01 remains unwatched) -> Priority 2 picks S02E05 next!
	if err := lib.ClearFilmProgress(1, s02e05.ID); err != nil {
		t.Fatal(err)
	}
	if err := lib.MarkWatched(1, s02e04.ID, true); err != nil {
		t.Fatal(err)
	}
	detailAfterE04, _, err := lib.GetSeries(1, showID, []string{"Users/u1/videos"})
	if err != nil {
		t.Fatal(err)
	}
	if detailAfterE04.NextFilmID != s02e05.ID || detailAfterE04.NextSeason != 2 || detailAfterE04.NextEpisode != 5 || detailAfterE04.InProgress {
		t.Fatalf("expected next episode after S02E04 to be S02E05, got %+v", detailAfterE04)
	}
}
