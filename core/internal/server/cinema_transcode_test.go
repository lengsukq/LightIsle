package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/cinema"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/ffmpegbin"
)

// The production endpoint reports real Homebrew FFmpeg availability. When
// FFmpeg is installed, verify the installed status instead of assuming this
// development/CI machine has no optional tools. Explicit missing-binary
// behavior is exercised in cinema's NewWithPaths("", "") unit tests.
func TestTranscodeEndpointsReportAvailabilityAndDegradeWithoutFFmpeg(t *testing.T) {
	data := t.TempDir()
	accounts, err := auth.Open(filepath.Join(data, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	store, err := files.NewManager(data)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	videos, err := cinema.OpenWithTranscodeTools(data, store, ffmpegbin.NewWithPaths("", ""))
	if err != nil {
		t.Fatal(err)
	}
	defer videos.Close()
	share := filepath.Join(data, "SharedFiles")
	if err := os.WriteFile(filepath.Join(share, "Show.S01E01.mkv"), []byte("video"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := videos.StartScan(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for videos.Status().Running && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	found, _, err := videos.List(1, "series", "", 10, 0)
	if err != nil || len(found) != 1 {
		t.Fatalf("index: %+v %v", found, err)
	}
	filmID := strconv.FormatInt(found[0].ID, 10)
	if err := accounts.Setup("owner", "strong-owner-password"); err != nil {
		t.Fatal(err)
	}
	handler := NewWithCinema("", accounts, store, nil, videos)
	call := func(method, url, body string, cookie *http.Cookie) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, url, strings.NewReader(body))
		if method != "GET" && method != "HEAD" {
			req.Header.Set("X-LightIsle-Request", "1")
		}
		if cookie != nil {
			req.AddCookie(cookie)
		}
		out := httptest.NewRecorder()
		handler.ServeHTTP(out, req)
		return out
	}
	login := call("POST", "/api/v1/auth/login", `{"username":"owner","password":"strong-owner-password"}`, nil)
	if login.Code != 200 {
		t.Fatalf("login %d %s", login.Code, login.Body.String())
	}
	cookie := login.Result().Cookies()[0]

	available := false
	if r := call("GET", "/api/v1/cinema/transcode/status", "", cookie); r.Code != 200 {
		t.Fatalf("status %d %s", r.Code, r.Body.String())
	} else {
		var payload map[string]any
		if err := json.Unmarshal(r.Body.Bytes(), &payload); err != nil {
			t.Fatal(err)
		}
		var valid bool
		available, valid = payload["available"].(bool)
		if !valid {
			t.Fatalf("invalid transcode availability: %v", payload)
		}
		if available {
			if payload["version"] == "" || payload["reason"] != nil {
				t.Fatalf("installed FFmpeg reports incomplete status: %v", payload)
			}
		} else if payload["reason"] != "ffmpeg_not_installed" {
			// The probe may fail independently of installation; this is a
			// distinct, truthful failure mode, not a missing binary.
			if payload["reason"] == "ffmpeg_failed" {
				t.Skip("FFmpeg is present but its version probe failed; missing-binary branch tested in cinema unit tests")
			}
			t.Fatalf("honest status: %v", payload)
		}
	}
	if available {
		// The real-FFmpeg integration tests cover playable media; this
		// fixture intentionally contains a fake .mkv, not a playable film.
		return
	}
	if r := call("GET", "/api/v1/cinema/"+filmID+"/hls/session?start=0", "", cookie); r.Code != 503 {
		t.Fatalf("session without ffmpeg %d %s", r.Code, r.Body.String())
	} else if r.Body.String() != "{\"error\":\"transcode_unavailable\"}\n" {
		t.Fatalf("session reason code: %s", r.Body.String())
	}
	if r := call("GET", "/api/v1/cinema/"+filmID+"/tracks", "", cookie); r.Code != 503 {
		t.Fatalf("tracks without ffmpeg %d %s", r.Code, r.Body.String())
	}
	if r := call("GET", "/api/v1/cinema/"+filmID+"/embedded-subtitles?track=2", "", cookie); r.Code != 503 {
		t.Fatalf("embedded subtitle without ffmpeg %d %s", r.Code, r.Body.String())
	}
	// Unknown sessions are a plain miss; illegal file names are invalid
	// before any disk access.
	if r := call("GET", "/api/v1/cinema/"+filmID+"/hls/whatever/index.m3u8", "", cookie); r.Code != 404 {
		t.Fatalf("unknown session %d", r.Code)
	}
	if r := call("GET", "/api/v1/cinema/"+filmID+"/hls/whatever/evil.m4s", "", cookie); r.Code != 400 {
		t.Fatalf("illegal file name %d", r.Code)
	}
}

func TestSeriesAndScrapeEndpoints(t *testing.T) {
	data := t.TempDir()
	accounts, err := auth.Open(filepath.Join(data, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	store, err := files.NewManager(data)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	videos, err := cinema.Open(data, store)
	if err != nil {
		t.Fatal(err)
	}
	defer videos.Close()
	share := filepath.Join(data, "SharedFiles")
	if err := os.MkdirAll(filepath.Join(share, "Show"), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"Show.S01E01.mkv", "Show.S01E02.mkv"} {
		if err := os.WriteFile(filepath.Join(share, "Show", name), []byte("video"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := videos.StartScan(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for videos.Status().Running && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if err := accounts.Setup("owner", "strong-owner-password"); err != nil {
		t.Fatal(err)
	}
	handler := NewWithCinema("", accounts, store, nil, videos)
	call := func(method, url, body string, cookie *http.Cookie) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, url, strings.NewReader(body))
		if method != "GET" && method != "HEAD" {
			req.Header.Set("X-LightIsle-Request", "1")
		}
		if cookie != nil {
			req.AddCookie(cookie)
		}
		out := httptest.NewRecorder()
		handler.ServeHTTP(out, req)
		return out
	}
	login := call("POST", "/api/v1/auth/login", `{"username":"owner","password":"strong-owner-password"}`, nil)
	cookie := login.Result().Cookies()[0]

	list := call("GET", "/api/v1/series", "", cookie)
	if list.Code != 200 {
		t.Fatalf("series list %d %s", list.Code, list.Body.String())
	}
	var payload struct {
		Series []cinema.Series `json:"series"`
	}
	if err := json.Unmarshal(list.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if len(payload.Series) != 1 || payload.Series[0].EpisodeCount != 2 || payload.Series[0].NextFilmID == 0 {
		t.Fatalf("series payload: %+v", payload.Series)
	}
	seriesID := strconv.FormatInt(payload.Series[0].ID, 10)
	detail := call("GET", "/api/v1/series/"+seriesID, "", cookie)
	if detail.Code != 200 {
		t.Fatalf("series detail %d %s", detail.Code, detail.Body.String())
	}
	var detailed struct {
		Series cinema.Series `json:"series"`
		Films  []cinema.Film `json:"films"`
	}
	if err := json.Unmarshal(detail.Body.Bytes(), &detailed); err != nil {
		t.Fatal(err)
	}
	if len(detailed.Films) != 2 || detailed.Series.EpisodeCount != 2 {
		t.Fatalf("detail: %+v", detailed)
	}
	if r := call("GET", "/api/v1/series/999", "", cookie); r.Code != 404 {
		t.Fatalf("unknown series %d", r.Code)
	}
	// Scrape without a Keychain-provisioned token fails honestly.
	if r := call("POST", "/api/v1/cinema/scrape/start", `{}`, cookie); r.Code != 409 {
		t.Fatalf("scrape without token %d %s", r.Code, r.Body.String())
	} else if r.Body.String() != "{\"error\":\"tmdb_token_not_configured\"}\n" {
		t.Fatalf("scrape reason: %s", r.Body.String())
	}
	status := call("GET", "/api/v1/cinema/scrape/status", "", cookie)
	if status.Code != 200 {
		t.Fatalf("scrape status %d", status.Code)
	}
	var scrapeStatus map[string]any
	if err := json.Unmarshal(status.Body.Bytes(), &scrapeStatus); err != nil {
		t.Fatal(err)
	}
	if scrapeStatus["running"] != false || scrapeStatus["tmdbConfigured"] != false {
		t.Fatalf("scrape status: %v", scrapeStatus)
	}
	// Members cannot start scrapes.
	ownerToken, err := accounts.Login("owner", "strong-owner-password")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := accounts.CreateUser(ownerToken, "viewer", "strong-viewer-password", auth.RoleMember); err != nil {
		t.Fatal(err)
	}
	memberLogin := call("POST", "/api/v1/auth/login", `{"username":"viewer","password":"strong-viewer-password"}`, nil)
	memberCookie := memberLogin.Result().Cookies()[0]
	if r := call("POST", "/api/v1/cinema/scrape/start", `{}`, memberCookie); r.Code != 403 {
		t.Fatalf("member scrape %d", r.Code)
	}
}
