package server

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/cinema"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/gallery"
	"github.com/lengsukq/lightisle/core/internal/maptiles"
)

func TestCacheStatusAndAdminClearAndPosterETag(t *testing.T) {
	dataDir := t.TempDir()
	accounts, err := auth.Open(filepath.Join(dataDir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("owner", "valid-owner-password"); err != nil {
		t.Fatal(err)
	}
	adminToken, err := accounts.Login("owner", "valid-owner-password")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := accounts.CreateUser(adminToken, "member", "valid-member-password", auth.RoleMember); err != nil {
		t.Fatal(err)
	}
	memberToken, err := accounts.Login("member", "valid-member-password")
	if err != nil {
		t.Fatal(err)
	}

	shared, err := files.NewManager(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	defer shared.Close()
	share, _ := shared.State()
	filmPath := filepath.Join(share, "clip.mp4")
	if err := os.WriteFile(filmPath, []byte("video source bytes"), 0600); err != nil {
		t.Fatal(err)
	}
	photos, err := gallery.Open(dataDir, shared)
	if err != nil {
		t.Fatal(err)
	}
	defer photos.Close()
	films, err := cinema.Open(dataDir, shared)
	if err != nil {
		t.Fatal(err)
	}
	defer films.Close()
	worker := &posterAPIWorker{}
	photos.SetMediaWorker(worker)
	films.SetMediaWorker(worker)
	if err := photos.StartScan(); err != nil {
		t.Fatal(err)
	}
	if err := films.StartScan(); err != nil {
		t.Fatal(err)
	}
	waitMediaLibraries(t, photos, films)
	items, _, err := films.List(1, "", "", 20, 0)
	if err != nil || len(items) != 1 {
		t.Fatalf("film index = %+v, %v", items, err)
	}
	filmID := items[0].ID

	maptiles.Default.Clear()
	t.Cleanup(maptiles.Default.Clear)
	_ = maptiles.Default.Set("safe-test-key-1234")
	maptiles.Default.SetHTTPClientForTest(&http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return &http.Response{
			StatusCode: 200,
			Header:     http.Header{"Content-Type": []string{"image/png"}},
			Body:       io.NopCloser(bytes.NewReader([]byte("\x89PNG\r\n\x1a\ntile-bytes"))),
		}, nil
	})})

	handler := NewWithCinema("", accounts, shared, photos, films)
	request := func(method, path, body, token string, headers map[string]string) *httptest.ResponseRecorder {
		var reader io.Reader
		if body != "" {
			reader = strings.NewReader(body)
		}
		r := httptest.NewRequest(method, path, reader)
		r.Header.Set("X-LightIsle-Request", "1")
		if token != "" {
			r.AddCookie(&http.Cookie{Name: sessionCookie, Value: token})
		}
		for k, v := range headers {
			r.Header.Set(k, v)
		}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}

	posterURL := "/api/v2/cinema/" + strconv.FormatInt(filmID, 10) + "/poster"
	first := request(http.MethodGet, posterURL, "", adminToken, nil)
	if first.Code != http.StatusOK {
		t.Fatalf("poster GET = %d", first.Code)
	}
	etag := first.Header().Get("ETag")
	if etag == "" {
		t.Fatal("expected ETag on poster response")
	}

	// Conditional GET with If-None-Match returns 304 Not Modified.
	cond := request(http.MethodGet, posterURL, "", adminToken, map[string]string{"If-None-Match": etag})
	if cond.Code != http.StatusNotModified {
		t.Fatalf("conditional poster GET = %d, want 304", cond.Code)
	}

	// Seed one map tile into cache.
	tileRes := request(http.MethodGet, "/api/v2/map/tiles/tianditu/vec/3/2/1", "", adminToken, nil)
	if tileRes.Code != http.StatusOK {
		t.Fatalf("tile GET = %d", tileRes.Code)
	}

	// Both member and admin can read /api/v2/cache/status.
	statusRes := request(http.MethodGet, "/api/v2/cache/status", "", memberToken, nil)
	if statusRes.Code != http.StatusOK {
		t.Fatalf("member cache status = %d %s", statusRes.Code, statusRes.Body.String())
	}
	var statusPayload struct {
		Thumbnails     gallery.ThumbnailCacheStats `json:"thumbnails"`
		MapTiles       maptiles.TileCacheStats     `json:"mapTiles"`
		TotalUsedBytes int64                       `json:"totalUsedBytes"`
	}
	if err := json.Unmarshal(statusRes.Body.Bytes(), &statusPayload); err != nil {
		t.Fatal(err)
	}
	if statusPayload.Thumbnails.EntryCount != 1 || statusPayload.MapTiles.EntryCount != 1 || statusPayload.TotalUsedBytes <= 0 {
		t.Fatalf("unexpected cache status: %+v", statusPayload)
	}

	// Member cannot clear server cache.
	denied := request(http.MethodPost, "/api/v2/admin/cache/clear", `{}`, memberToken, nil)
	if denied.Code != http.StatusForbidden {
		t.Fatalf("member clear cache = %d, want 403", denied.Code)
	}

	// Admin clears server cache.
	cleared := request(http.MethodPost, "/api/v2/admin/cache/clear", `{"categories":["thumbnails","map_tiles"]}`, adminToken, nil)
	if cleared.Code != http.StatusOK {
		t.Fatalf("admin clear cache = %d %s", cleared.Code, cleared.Body.String())
	}
	var clearPayload struct {
		OK             bool  `json:"ok"`
		RemovedEntries int   `json:"removedEntries"`
		FreedBytes     int64 `json:"freedBytes"`
		TotalUsedBytes int64 `json:"totalUsedBytes"`
	}
	if err := json.Unmarshal(cleared.Body.Bytes(), &clearPayload); err != nil {
		t.Fatal(err)
	}
	if !clearPayload.OK || clearPayload.RemovedEntries != 2 || clearPayload.FreedBytes <= 0 || clearPayload.TotalUsedBytes != 0 {
		t.Fatalf("unexpected clear payload: %+v", clearPayload)
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (fn roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return fn(r) }
