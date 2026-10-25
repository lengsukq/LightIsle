package cinema

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fakeTMDB serves the three endpoints the scrape touches: movie search,
// tv search and details. It records the bearer token for assertions.
func fakeTMDB(t *testing.T, tokenSeen *string, movieTitle, tvTitle string) *httptest.Server {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		*tokenSeen = strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !strings.HasPrefix(r.URL.Path, "/3/search/") {
			http.NotFound(w, r)
			return
		}
		query := r.URL.Query().Get("query")
		kind := strings.TrimPrefix(r.URL.Path, "/3/search/")
		_ = kind // movies and shows share the result shape in this fixture
		results := []map[string]any{}
		if strings.EqualFold(query, movieTitle) {
			results = append(results, map[string]any{
				"id": 42, "title": movieTitle, "release_date": "1993-02-12",
				"overview": "剧情简介", "vote_average": 8.5, "poster_path": "/poster.jpg",
			})
		}
		if strings.EqualFold(query, tvTitle) {
			results = append(results, map[string]any{
				"id": 7, "name": tvTitle, "first_air_date": "2010-01-01",
				"overview": "剧集简介", "vote_average": 9.0, "poster_path": "/show.jpg",
			})
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"results": results})
	}))
	t.Cleanup(server.Close)
	return server
}

func waitForScrape(t *testing.T, lib *Library) {
	t.Helper()
	deadline := time.Now().Add(8 * time.Second)
	for lib.Status().Running && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if lib.Status().Running {
		t.Fatal("scrape still running")
	}
}

func TestScrapeMatchesMoviesAndSeries(t *testing.T) {
	lib, _, share := newScrapeTestLibrary(t)
	const movieTitle = "Groundhog Day"
	writeShow(t, share, "Great Show", []string{"Great.Show.S01E01.mkv"})
	if err := os.WriteFile(filepath.Join(share, "Groundhog.Day.1993.mkv"), []byte("video"), 0o600); err != nil {
		t.Fatal(err)
	}
	scanAndWait(t, lib)

	var tokenSeen string
	server := fakeTMDB(t, &tokenSeen, movieTitle, "Great Show")
	endpoint := server.URL + "/3"
	lib.scrapeService = &TMDBService{endpoint: endpoint, client: server.Client()}
	if err := lib.SetTMDBToken("test-token-1234567890"); err != nil {
		t.Fatal(err)
	}
	if !lib.TMDBTokenConfigured() {
		t.Fatal("token must be configured")
	}
	if err := lib.StartScrape(false); err != nil {
		t.Fatal(err)
	}
	waitForScrape(t, lib)
	status := lib.Status()
	if status.LastError != "" {
		t.Fatalf("scrape error: %s", status.LastError)
	}
	if tokenSeen != "test-token-1234567890" {
		t.Fatalf("upstream token = %q", tokenSeen)
	}
	movies, _, err := lib.List(1, "movie", "Groundhog", 10, 0)
	if err != nil || len(movies) != 1 {
		t.Fatalf("movies: %+v %v", movies, err)
	}
	if movies[0].Title != movieTitle || movies[0].Overview != "剧情简介" || movies[0].Rating != 8.5 {
		t.Fatalf("movie metadata: %+v", movies[0])
	}
	if movies[0].PosterURL == "" || !strings.Contains(movies[0].PosterURL, "/w342/poster.jpg") {
		t.Fatalf("poster URL: %q", movies[0].PosterURL)
	}
	series, err := lib.ListSeries(1, 60, []string{"."})
	if err != nil || len(series) != 1 {
		t.Fatalf("series: %+v %v", series, err)
	}
	if series[0].TMDBID != 7 || series[0].Overview != "剧集简介" {
		t.Fatalf("series metadata: %+v", series[0])
	}
	// A rerun without retry does not re-query resolved items.
	if err := lib.StartScrape(false); err != nil {
		t.Fatal(err)
	}
	waitForScrape(t, lib)
	if status := lib.Status(); status.LastError != "" {
		t.Fatalf("second scrape error: %s", status.LastError)
	}
}

func TestScrapeRequiresToken(t *testing.T) {
	lib, _, _ := newScrapeTestLibrary(t)
	if err := lib.StartScrape(false); err != ErrTMDBNotConfigured {
		t.Fatalf("StartScrape without token = %v", err)
	}
	if lib.Status().Running {
		t.Fatal("refused scrape must not start a job")
	}
}

func TestScrapeInvalidTokenRejected(t *testing.T) {
	lib, _, _ := newScrapeTestLibrary(t)
	if err := lib.SetTMDBToken("short"); err != ErrInvalid {
		t.Fatalf("short token error = %v", err)
	}
	if err := lib.SetTMDBToken("has\nnewline-token-123456"); err != ErrInvalid {
		t.Fatalf("newline token error = %v", err)
	}
}

func TestPickTMBDCandidateConfidence(t *testing.T) {
	candidates := []TMDBCandidate{
		{ID: 1, Title: "Wrong Movie", Year: "1999"},
		{ID: 2, Title: "The Right Movie", Year: "2001"},
		{ID: 3, Title: "The Right Movie!", Year: "1999"},
	}
	got := pickTMBDCandidate(candidates, "The Right Movie", 1999)
	if got == nil || got.ID != 3 {
		t.Fatalf("confident pick = %+v", got)
	}
	// Year mismatch beyond ±1 rejects even a title match.
	got = pickTMBDCandidate(candidates, "The Right Movie", 1995)
	if got != nil {
		t.Fatalf("year-mismatched pick = %+v", got)
	}
	// Titles without any candidate match stay unmatched.
	if pickTMBDCandidate(candidates, "Unrelated", 0) != nil {
		t.Fatal("unrelated title must not match")
	}
	// Chinese and punctuation-insensitive normalization.
	localized := []TMDBCandidate{{ID: 9, Title: "千与千寻", Year: "2001"}}
	if got := pickTMBDCandidate(localized, "千与。千寻", 2001); got == nil {
		t.Fatal("normalized Chinese title must match")
	}
}
