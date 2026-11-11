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
	"github.com/lengsukq/lightisle/core/internal/ffmpegbin"
	"github.com/lengsukq/lightisle/core/internal/files"
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
	login := call("POST", "/api/v2/auth/login", `{"username":"owner","password":"strong-owner-password"}`, nil)
	if login.Code != 200 {
		t.Fatalf("login %d %s", login.Code, login.Body.String())
	}
	cookie := login.Result().Cookies()[0]

	// Without ?direct=1, an unverified .mkv returns 415; with ?direct=1, local
	// hardware decoders can stream the original file via HTTP Range even when
	// FFmpeg is not installed.
	if r := call("GET", "/api/v2/cinema/"+filmID+"/stream", "", cookie); r.Code != 415 {
		t.Fatalf("plain stream without direct=1 got %d, want 415", r.Code)
	}
	directReq := httptest.NewRequest("GET", "/api/v2/cinema/"+filmID+"/stream?direct=1", nil)
	directReq.Header.Set("Range", "bytes=1-3")
	directReq.AddCookie(cookie)
	directResp := httptest.NewRecorder()
	handler.ServeHTTP(directResp, directReq)
	if directResp.Code != 206 || directResp.Body.String() != "ide" || directResp.Header().Get("Content-Type") != "video/x-matroska" {
		t.Fatalf("direct local-decode stream: code=%d body=%q type=%q", directResp.Code, directResp.Body.String(), directResp.Header().Get("Content-Type"))
	}

	available := false
	if r := call("GET", "/api/v2/cinema/transcode/status", "", cookie); r.Code != 200 {
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
	if r := call("GET", "/api/v2/cinema/"+filmID+"/hls/session?start=0", "", cookie); r.Code != 503 {
		t.Fatalf("session without ffmpeg %d %s", r.Code, r.Body.String())
	} else if r.Body.String() != "{\"error\":\"transcode_unavailable\"}\n" {
		t.Fatalf("session reason code: %s", r.Body.String())
	}
	if r := call("GET", "/api/v2/cinema/"+filmID+"/tracks", "", cookie); r.Code != 503 {
		t.Fatalf("tracks without ffmpeg %d %s", r.Code, r.Body.String())
	}
	if r := call("GET", "/api/v2/cinema/"+filmID+"/embedded-subtitles?track=2", "", cookie); r.Code != 503 {
		t.Fatalf("embedded subtitle without ffmpeg %d %s", r.Code, r.Body.String())
	}
	// Unknown sessions are a plain miss; illegal file names are invalid
	// before any disk access.
	if r := call("GET", "/api/v2/cinema/"+filmID+"/hls/whatever/index.m3u8", "", cookie); r.Code != 404 {
		t.Fatalf("unknown session %d", r.Code)
	}
	if r := call("GET", "/api/v2/cinema/"+filmID+"/hls/whatever/evil.m4s", "", cookie); r.Code != 400 {
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
	login := call("POST", "/api/v2/auth/login", `{"username":"owner","password":"strong-owner-password"}`, nil)
	cookie := login.Result().Cookies()[0]

	list := call("GET", "/api/v2/series", "", cookie)
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
	detail := call("GET", "/api/v2/series/"+seriesID, "", cookie)
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
	if r := call("GET", "/api/v2/series/999", "", cookie); r.Code != 404 {
		t.Fatalf("unknown series %d", r.Code)
	}
	// Scrape without a Keychain-provisioned token fails honestly.
	if r := call("POST", "/api/v2/cinema/scrape/start", `{}`, cookie); r.Code != 409 {
		t.Fatalf("scrape without token %d %s", r.Code, r.Body.String())
	} else if r.Body.String() != "{\"error\":\"tmdb_token_not_configured\"}\n" {
		t.Fatalf("scrape reason: %s", r.Body.String())
	}
	status := call("GET", "/api/v2/cinema/scrape/status", "", cookie)
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
	memberLogin := call("POST", "/api/v2/auth/login", `{"username":"viewer","password":"strong-viewer-password"}`, nil)
	memberCookie := memberLogin.Result().Cookies()[0]
	if r := call("POST", "/api/v2/cinema/scrape/start", `{}`, memberCookie); r.Code != 403 {
		t.Fatalf("member scrape %d", r.Code)
	}
}

func TestHLSSessionDurationBackfillReplaceAndDelete(t *testing.T) {
	data := t.TempDir()
	probeScript := filepath.Join(data, "ffprobe")
	probeOut := `#!/bin/sh
cat <<'EOF'
{"streams":[{"index":0,"codec_name":"hevc","codec_type":"video","width":3840,"height":1608},{"index":1,"codec_name":"eac3","codec_type":"audio","channels":6}],"format":{"duration":"9660.0"}}
EOF
`
	if err := os.WriteFile(probeScript, []byte(probeOut), 0o755); err != nil {
		t.Fatal(err)
	}
	ffmpegScript := filepath.Join(data, "ffmpeg")
	ffmpegOut := `#!/bin/sh
if [ "$1" = "-version" ]; then
  echo "ffmpeg version 7.1-fake"
  exit 0
fi
for last; do :; done
dir=$(dirname "$last")
printf '#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-TARGETDURATION:4\n#EXT-X-PLAYLIST-TYPE:EVENT\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:4.0,\nseg00000.m4s\n' > "$last"
printf 'init' > "$dir/init.mp4"
printf 'seg' > "$dir/seg00000.m4s"
sleep 30
`
	if err := os.WriteFile(ffmpegScript, []byte(ffmpegOut), 0o755); err != nil {
		t.Fatal(err)
	}

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
	videos, err := cinema.OpenWithTranscodeTools(data, store, ffmpegbin.NewWithPaths(ffmpegScript, probeScript))
	if err != nil {
		t.Fatal(err)
	}
	defer videos.Close()
	share := filepath.Join(data, "SharedFiles")
	if err := os.WriteFile(filepath.Join(share, "BlackPanther2.2022.mkv"), []byte("mkv-video"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := videos.StartScan(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for videos.Status().Running && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	found, _, err := videos.List(1, "all", "", 10, 0)
	if err != nil || len(found) != 1 {
		t.Fatalf("index: %+v %v", found, err)
	}
	filmID := strconv.FormatInt(found[0].ID, 10)
	if err := accounts.Setup("owner", "strong-owner-password"); err != nil {
		t.Fatal(err)
	}
	handler := NewWithCinema("", accounts, store, nil, videos)
	call := func(method, url string, cookie *http.Cookie) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, url, nil)
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
	loginReq := httptest.NewRequest("POST", "/api/v2/auth/login", strings.NewReader(`{"username":"owner","password":"strong-owner-password"}`))
	loginReq.Header.Set("X-LightIsle-Request", "1")
	loginResp := httptest.NewRecorder()
	handler.ServeHTTP(loginResp, loginReq)
	cookie := loginResp.Result().Cookies()[0]

	firstResp := call("GET", "/api/v2/cinema/"+filmID+"/hls/session?start=1800&audio=0", cookie)
	if firstResp.Code != 200 {
		t.Fatalf("first session %d %s", firstResp.Code, firstResp.Body.String())
	}
	var firstSession struct {
		SessionID       string  `json:"sessionId"`
		Start           float64 `json:"start"`
		DurationSeconds float64 `json:"durationSeconds"`
	}
	if err := json.Unmarshal(firstResp.Body.Bytes(), &firstSession); err != nil {
		t.Fatal(err)
	}
	if firstSession.DurationSeconds != 9660 {
		t.Fatalf("session durationSeconds = %v, want 9660", firstSession.DurationSeconds)
	}

	detailResp := call("GET", "/api/v2/cinema/"+filmID, cookie)
	if detailResp.Code != 200 {
		t.Fatalf("detail %d %s", detailResp.Code, detailResp.Body.String())
	}
	var detail struct {
		DurationSeconds float64 `json:"durationSeconds"`
		BrowserPlayback string  `json:"browserPlayback"`
	}
	if err := json.Unmarshal(detailResp.Body.Bytes(), &detail); err != nil {
		t.Fatal(err)
	}
	if detail.DurationSeconds != 9660 || detail.BrowserPlayback != "download-only" {
		t.Fatalf("backfilled detail = %+v", detail)
	}

	secondResp := call("GET", "/api/v2/cinema/"+filmID+"/hls/session?start=3600&audio=0&replace="+firstSession.SessionID, cookie)
	if secondResp.Code != 200 {
		t.Fatalf("replace session %d %s", secondResp.Code, secondResp.Body.String())
	}
	var secondSession struct {
		SessionID       string  `json:"sessionId"`
		DurationSeconds float64 `json:"durationSeconds"`
	}
	if err := json.Unmarshal(secondResp.Body.Bytes(), &secondSession); err != nil {
		t.Fatal(err)
	}
	if secondSession.DurationSeconds != 9660 {
		t.Fatalf("second session durationSeconds = %v, want 9660", secondSession.DurationSeconds)
	}
	if r := call("GET", "/api/v2/cinema/"+filmID+"/hls/"+firstSession.SessionID+"/index.m3u8", cookie); r.Code != 404 {
		t.Fatalf("replaced session playlist status = %d, want 404", r.Code)
	}
	if r := call("DELETE", "/api/v2/cinema/"+filmID+"/hls/session?session="+secondSession.SessionID, cookie); r.Code != 204 {
		t.Fatalf("delete session status = %d, want 204", r.Code)
	}
	if r := call("GET", "/api/v2/cinema/"+filmID+"/hls/"+secondSession.SessionID+"/index.m3u8", cookie); r.Code != 404 {
		t.Fatalf("deleted session playlist status = %d, want 404", r.Code)
	}
}
