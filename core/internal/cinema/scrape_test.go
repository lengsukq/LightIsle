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

func TestScanAutoChainsIncrementalScrapeAndFiltersUnmatched(t *testing.T) {
	lib, _, share := newScrapeTestLibrary(t)
	const movieTitle = "Groundhog Day"
	if err := os.WriteFile(filepath.Join(share, "Groundhog.Day.1993.mkv"), []byte("video"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(share, "Unknown.Home.Video.2024.mkv"), []byte("video"), 0o600); err != nil {
		t.Fatal(err)
	}

	var tokenSeen string
	server := fakeTMDB(t, &tokenSeen, movieTitle, "Great Show")
	endpoint := server.URL + "/3"
	lib.scrapeService = &TMDBService{endpoint: endpoint, client: server.Client()}
	if err := lib.SetTMDBToken("test-token-1234567890"); err != nil {
		t.Fatal(err)
	}

	// StartScan should automatically chain incremental scrape when TMDB token is configured.
	scanAndWait(t, lib)

	matched, _, err := lib.List(1, "movie", "Groundhog", 10, 0)
	if err != nil || len(matched) != 1 || !strings.HasPrefix(matched[0].MetadataSource, "tmdb") || matched[0].ScrapeState != "auto" {
		t.Fatalf("expected auto-scraped movie after scan, got: %+v (err=%v)", matched, err)
	}

	unmatched, _, err := lib.List(1, "unmatched", "", 10, 0)
	if err != nil || len(unmatched) != 1 || !strings.Contains(unmatched[0].Path, "Unknown.Home.Video.2024.mkv") || unmatched[0].ScrapeState != "miss" {
		t.Fatalf("expected 1 unmatched film with scrapeState='miss', got: %+v (err=%v)", unmatched, err)
	}
}

func TestSetTMDBTokenAutoStartsScrapeAndSearchFallback(t *testing.T) {
	lib, _, share := newScrapeTestLibrary(t)
	const movieTitle = "Groundhog Day"
	if err := os.WriteFile(filepath.Join(share, "Groundhog.Day.1993.mkv"), []byte("video"), 0o600); err != nil {
		t.Fatal(err)
	}
	scanAndWait(t, lib)

	var tokenSeen string
	server := fakeTMDB(t, &tokenSeen, movieTitle, "Great Show")
	endpoint := server.URL + "/3"
	lib.scrapeService = &TMDBService{endpoint: endpoint, client: server.Client()}

	// Setting the TMDB token on Mac automatically triggers background scraping
	// without requiring any manual StartScrape call.
	if err := lib.SetTMDBToken("test-token-1234567890"); err != nil {
		t.Fatal(err)
	}
	waitForScrape(t, lib)

	movies, _, err := lib.List(1, "movie", "Groundhog", 10, 0)
	if err != nil || len(movies) != 1 || movies[0].ScrapeState != "auto" {
		t.Fatalf("expected SetTMDBToken to auto-scrape existing films, got: %+v (err=%v)", movies, err)
	}

	// Client SearchTMDB with an empty token falls back to the Mac-configured token.
	candidates, err := lib.SearchTMDB(t.Context(), "", movies[0].ID, movieTitle)
	if err != nil || len(candidates) != 1 || candidates[0].ID != 42 {
		t.Fatalf("expected SearchTMDB with empty token to use stored token, got: %+v (err=%v)", candidates, err)
	}

	// Clearing the token on Mac disables TMDB fallback.
	lib.ClearTMDBToken()
	if _, err := lib.SearchTMDB(t.Context(), "", movies[0].ID, movieTitle); err != ErrInvalid {
		t.Fatalf("expected ErrInvalid after ClearTMDBToken, got %v", err)
	}
}

func TestAutoRecognizeAndScrapeRealWorldAddedFilms(t *testing.T) {
	lib, _, share := newScrapeTestLibrary(t)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		query := r.URL.Query().Get("query")
		results := []map[string]any{}
		switch {
		case strings.EqualFold(query, "The Matrix"):
			// English filename searched with language=zh-CN returns Chinese title + English original_title.
			results = append(results, map[string]any{
				"id": 603, "title": "黑客帝国", "original_title": "The Matrix",
				"release_date": "1999-03-30", "overview": "尼奥觉醒", "vote_average": 8.7, "poster_path": "/matrix.jpg",
			})
		case query == "流浪地球2":
			results = append(results, map[string]any{
				"id": 842675, "title": "流浪地球2", "original_title": "流浪地球2",
				"release_date": "2023-01-22", "overview": "太阳危机", "vote_average": 8.3, "poster_path": "/earth2.jpg",
			})
		case query == "庆余年":
			results = append(results, map[string]any{
				"id": 95557, "name": "庆余年", "original_name": "庆余年",
				"first_air_date": "2019-11-26", "overview": "范闲传奇", "vote_average": 8.2, "poster_path": "/qyn.jpg",
			})
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"results": results})
	}))
	t.Cleanup(server.Close)

	lib.scrapeService = &TMDBService{endpoint: server.URL + "/3", client: server.Client()}
	if err := lib.SetTMDBToken("test-token-1234567890"); err != nil {
		t.Fatal(err)
	}

	// 1. Add a movie with an English filename and a bilingual movie with release group tags.
	if err := os.WriteFile(filepath.Join(share, "The.Matrix.1999.1080p.BluRay.mp4"), []byte("matrix"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(share, "[阳光电影www.ygdy8.com]流浪地球2.The.Wandering.Earth.II.2023.2160p.WEB-DL.H265.mp4"), []byte("earth2"), 0o600); err != nil {
		t.Fatal(err)
	}
	// 2. Add a TV episode inside a nested Chinese series/season folder.
	epDir := filepath.Join(share, "影视", "庆余年", "第2季")
	if err := os.MkdirAll(epDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(epDir, "EP05.1080p.mp4"), []byte("ep5"), 0o600); err != nil {
		t.Fatal(err)
	}

	// StartScan automatically scans and chains into TMDB scraping.
	if err := lib.StartScan(); err != nil {
		t.Fatal(err)
	}
	waitForScrape(t, lib)

	movies, _, err := lib.List(1, "movie", "", 10, 0)
	if err != nil || len(movies) != 2 {
		t.Fatalf("expected 2 matched movies, got %+v (err=%v)", movies, err)
	}
	for _, m := range movies {
		if m.Title != "黑客帝国" && m.Title != "流浪地球2" {
			t.Fatalf("unexpected movie title after auto-scrape: %+v", m)
		}
		if m.PosterURL == "" || m.Overview == "" || m.ScrapeState != "auto" {
			t.Fatalf("movie missing auto-scraped metadata: %+v", m)
		}
	}

	unmatched, _, err := lib.List(1, "unmatched", "", 10, 0)
	if err != nil || len(unmatched) != 0 {
		t.Fatalf("expected 0 unmatched items after series and movie auto-scrape, got %+v (err=%v)", unmatched, err)
	}
}
