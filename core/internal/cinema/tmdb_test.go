package cinema

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestTMDBManualSearchAndDetailMatchNeverSendTokenInURL(t *testing.T) {
	const token = "sample-read-access-token-not-a-real-credential"
	seen := make([]string, 0, 2)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "Bearer "+token {
			t.Errorf("unexpected upstream authorization %q", got)
		}
		if strings.Contains(r.URL.String(), token) {
			t.Error("TMDB bearer token leaked in URL")
		}
		seen = append(seen, r.URL.String())
		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.HasPrefix(r.URL.Path, "/3/search/movie"):
			_, _ = w.Write([]byte(`{"results":[{"id":123,"title":"电影甲","overview":"简短简介","release_date":"2024-01-02","vote_average":8.4,"poster_path":"/poster123.jpg"},{"id":124,"title":"成人作品","adult":true},{"id":125,"title":"损坏封面","poster_path":"https://evil.invalid/cover.jpg"}]}`))
		case r.URL.Path == "/3/movie/123":
			_, _ = w.Write([]byte(`{"id":123,"title":"电影甲","overview":"正式电影简介","vote_average":8.8,"poster_path":"/poster123.jpg"}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer upstream.Close()
	client := TMDBService{endpoint: upstream.URL + "/3", client: upstream.Client()}
	choices, err := client.Search(context.Background(), token, "电影甲", "movie")
	if err != nil || len(choices) != 2 {
		t.Fatalf("search failed: %+v %v", choices, err)
	}
	if choices[0].Title != "电影甲" || choices[0].Year != "2024" ||
		choices[0].PosterURL != "https://image.tmdb.org/t/p/w342/poster123.jpg" {
		t.Fatalf("candidate fields unexpected: %+v", choices[0])
	}
	if choices[1].PosterURL != "" {
		t.Fatalf("unsafe poster propagated: %+v", choices[1])
	}
	if len(seen) == 0 || !strings.Contains(seen[0], "language=zh-CN") {
		t.Fatalf("request did not include language: %v", seen)
	}
	matched, err := client.Details(context.Background(), token, "movie", 123)
	if err != nil || matched.Overview != "正式电影简介" || matched.Rating != 8.8 {
		t.Fatalf("confirmed detail mismatch: %+v %v", matched, err)
	}
	if len(seen) != 2 {
		t.Fatalf("expected exactly 2 explicit upstream calls, got %v", seen)
	}
	if _, err := client.Search(context.Background(), "malicious\r\nHeader: x", "Title", "movie"); err != ErrInvalid {
		t.Fatalf("newline token accepted: %v", err)
	}
	if _, err := client.Search(context.Background(), token, "Title", "file:///etc/passwd"); err != ErrInvalid {
		t.Fatalf("unsupported source accepted: %v", err)
	}
	if tmdbPosterURL("//evil.invalid/img.jpg") != "" {
		t.Fatal("unsafe poster redirect allowed")
	}
	serialized, err := json.Marshal(choices[0])
	if err != nil || strings.Contains(string(serialized), "posterPath") {
		t.Fatalf("internal poster ID leaked in API JSON: %s %v", serialized, err)
	}
}

func TestTMDBMetadataAppliesOnlyToChosenFilmAndRetainsManualTitle(t *testing.T) {
	data := t.TempDir()
	store, err := files.NewManager(data)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := os.WriteFile(filepath.Join(data, "SharedFiles", "Film.2026.mp4"), []byte("safe-original"), 0600); err != nil {
		t.Fatal(err)
	}
	lib, err := Open(data, store)
	if err != nil {
		t.Fatal(err)
	}
	defer lib.Close()
	if err := lib.StartScan(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for lib.Status().Running && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	films, _, err := lib.List(1, "movie", "", 10, 0)
	if err != nil || len(films) != 1 {
		t.Fatalf("scan: %+v %v", films, err)
	}
	item := films[0]
	if err := lib.Rename(item.ID, "我的手动标题"); err != nil {
		t.Fatal(err)
	}
	choice := TMDBCandidate{ID: 123, Kind: "movie", Title: "TMDB标题", Overview: "剧集简介", Rating: 7.9,
		PosterURL: "https://image.tmdb.org/t/p/w342/test123.jpg", posterPath: "/test123.jpg"}
	if err := lib.applyTMDB(item, choice); err != nil {
		t.Fatal(err)
	}
	updated, err := lib.Get(item.ID, 1)
	if err != nil || updated.Title != "我的手动标题" || updated.MetadataSource != "tmdb:movie:123" ||
		updated.Overview != "剧集简介" || updated.Rating != 7.9 || updated.PosterURL != choice.PosterURL {
		t.Fatalf("wrong explicit match: %+v %v", updated, err)
	}
	if err := lib.StartScan(); err != nil {
		t.Fatal(err)
	}
	for lib.Status().Running && time.Now().Before(deadline.Add(4*time.Second)) {
		time.Sleep(10 * time.Millisecond)
	}
	after, err := lib.Get(item.ID, 1)
	if err != nil || after.Overview != "剧集简介" {
		t.Fatalf("metadata not persisted across scan: %+v %v", after, err)
	}
	if err := lib.applyTMDB(item, TMDBCandidate{ID: 44, Kind: "tv", Title: "wrong media type"}); err != ErrInvalid {
		t.Fatalf("accepted TV details on movie record: %v", err)
	}
	if changed, err := os.ReadFile(filepath.Join(data, "SharedFiles", "Film.2026.mp4")); err != nil || string(changed) != "safe-original" {
		t.Fatalf("TMDB metadata changed original bytes: %q %v", changed, err)
	}
}

func TestTMDBUnexpectedResponseAndIdentityMismatchRejected(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"id":999,"title":"not requested"}`))
	}))
	defer srv.Close()
	client := TMDBService{endpoint: srv.URL + "/3", client: srv.Client()}
	if _, err := client.Details(context.Background(), "long-test-token-with-access-credential", "movie", 12); err == nil {
		t.Fatal("accepted a mismatched remote TMDB ID")
	}
}
