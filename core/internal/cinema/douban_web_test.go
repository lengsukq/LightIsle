package cinema

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestDoubanWebSearchIsLimitedAndSanitized(t *testing.T) {
	hits := 0
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		if r.Method != "GET" || r.URL.Path != "/j/subject_suggest" || r.URL.Query().Get("q") != "霸王别姬" {
			t.Errorf("unexpected Douban request %s", r.URL.String())
		}
		if r.Header.Get("Cookie") != "" || r.Header.Get("Authorization") != "" {
			t.Error("unexpected credentials forwarded")
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`[
   {"id":"1291546","title":"霸王别姬","year":"1993","type":"movie","img":"https://external.invalid/cover.jpg"},
   {"id":"1291546","title":"duplicate","year":"1994","type":"movie"},
   {"id":"javascript:bad","title":"unsafe","type":"movie"},
   {"id":"1002","title":"a","year":"invalid","type":"book"},
   {"id":"2983275","title":"后来的我们","year":"2018","type":"movie"}
  ]`))
	}))
	defer upstream.Close()
	service := DoubanWebService{endpoint: upstream.URL + "/j/subject_suggest", client: upstream.Client()}
	matches, err := service.Search(context.Background(), "霸王别姬")
	if err != nil || len(matches) != 2 {
		t.Fatalf("candidates=%+v err=%v", matches, err)
	}
	if matches[0].ID != "1291546" || matches[0].Year != "1993" {
		t.Fatalf("bad normalization: %+v", matches)
	}
	if hits != 1 {
		t.Fatalf("unexpected upstream requests: %d", hits)
	}
	if _, err := service.Search(context.Background(), "a"); err != ErrInvalid {
		t.Fatal("short query accepted")
	}
	if _, err := service.Search(context.Background(), "Hi\r\nHeader: evil"); err != ErrInvalid {
		t.Fatal("header injection accepted")
	}
}
func TestDoubanWebBlockedDoesNotBypassOrRetry(t *testing.T) {
	calls := 0
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		http.Error(w, "captcha required", http.StatusForbidden)
	}))
	defer upstream.Close()
	service := DoubanWebService{endpoint: upstream.URL, client: upstream.Client()}
	_, err := service.Search(context.Background(), "电影甲")
	if err == nil || calls != 1 {
		t.Fatalf("site block not reported, or retried: %v calls=%d", err, calls)
	}
}
func TestDoubanSuggestionOnlyUpdatesSafeMetadata(t *testing.T) {
	dir := t.TempDir()
	store, err := files.NewManager(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	original := filepath.Join(dir, "SharedFiles", "Film.2026.mp4")
	if err := os.WriteFile(original, []byte("original-video"), 0600); err != nil {
		t.Fatal(err)
	}
	lib, err := Open(dir, store)
	if err != nil {
		t.Fatal(err)
	}
	defer lib.Close()
	if err = lib.StartScan(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(6 * time.Second)
	for lib.Status().Running && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	films, _, err := lib.List(1, "movie", "", 10, 0)
	if err != nil || len(films) != 1 {
		t.Fatalf("scan results %+v %v", films, err)
	}
	film := films[0]
	if err = lib.Rename(film.ID, "我的自定义标题"); err != nil {
		t.Fatal(err)
	}
	selection := DoubanCandidate{ID: "1291546", Title: "霸王别姬", Year: "1993", Kind: "movie"}
	if err = lib.applyDoubanSuggestion(film, selection); err != nil {
		t.Fatal(err)
	}
	after, err := lib.Get(film.ID, 1)
	if err != nil || after.Title != "我的自定义标题" || after.Year != 1993 ||
		after.YearSource != "douban-suggest:1291546" || after.MetadataSource != "" {
		t.Fatalf("wrong metadata or manually edited title: %+v %v", after, err)
	}
	if err = lib.StartScan(); err != nil {
		t.Fatal(err)
	}
	for lib.Status().Running && time.Now().Before(deadline.Add(5*time.Second)) {
		time.Sleep(10 * time.Millisecond)
	}
	rescanned, err := lib.Get(film.ID, 1)
	if err != nil || rescanned.Year != 1993 || rescanned.YearSource != after.YearSource {
		t.Fatalf("explicit Douban year lost after automatic rescan: %+v %v", rescanned, err)
	}
	if after.Rating != 0 || after.Overview != "" || after.PosterURL != "" {
		t.Fatalf("invented rich metadata: %+v", after)
	}
	if before, err := os.ReadFile(original); err != nil || string(before) != "original-video" {
		t.Fatal("modified original video file")
	}
	if err = lib.applyDoubanSuggestion(film, DoubanCandidate{ID: "123", Title: "not a movie", Kind: "tv"}); err != ErrInvalid {
		t.Fatalf("cross-kind spoof accepted: %v", err)
	}
	if strings.Contains(after.YearSource, "https://") {
		t.Fatal("source contains external URL")
	}
}

func TestDoubanMatchRejectsSuggestionWhenFilmChangesDuringUpstreamRequest(t *testing.T) {
	dir := t.TempDir()
	store, err := files.NewManager(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	original := filepath.Join(dir, "SharedFiles", "Film.2026.mp4")
	if err := os.WriteFile(original, []byte("original-film-bytes"), 0600); err != nil {
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
	films, _, err := lib.List(1, "movie", "", 10, 0)
	if err != nil || len(films) != 1 {
		t.Fatalf("scan result: %+v %v", films, err)
	}
	film := films[0]

	entered, release := make(chan struct{}), make(chan struct{})
	var releaseOnce sync.Once
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(entered)
		<-release
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`[{"id":"1291546","title":"旧影片建议","year":"2026","type":"movie"}]`))
	}))
	defer upstream.Close()
	defer releaseOnce.Do(func() { close(release) })
	service := DoubanWebService{endpoint: upstream.URL + "/j/subject_suggest", client: upstream.Client()}
	type matchResult struct {
		film Film
		err  error
	}
	done := make(chan matchResult, 1)
	go func() {
		matched, err := lib.matchDoubanWithService(context.Background(), film.ID, "旧影片", "1291546", service)
		done <- matchResult{film: matched, err: err}
	}()
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		t.Fatal("Douban request did not reach local test server")
	}

	if err := os.WriteFile(original, []byte("replacement-film-has-different-bytes"), 0600); err != nil {
		t.Fatal(err)
	}
	changedAt := time.Now().Add(2 * time.Second)
	if err := os.Chtimes(original, changedAt, changedAt); err != nil {
		t.Fatal(err)
	}
	if err := lib.StartScan(); err != nil {
		t.Fatal(err)
	}
	waitMetadataScan(t, lib)
	releaseOnce.Do(func() { close(release) })

	select {
	case result := <-done:
		if !errors.Is(result.err, ErrAssetChanged) {
			t.Fatalf("stale Douban suggestion was not rejected: film=%+v err=%v", result.film, result.err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("Douban matching did not finish after upstream release")
	}
	current, err := lib.Get(film.ID, 0)
	if err != nil || current.TitleSource != "" || current.YearSource != "" {
		t.Fatalf("stale suggestion was written to replacement film: %+v %v", current, err)
	}
}
