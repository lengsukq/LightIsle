package server

import (
	"bytes"
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
)

func TestCinemaProtectedStreamAndUserProgress(t *testing.T) {
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
	if err := os.WriteFile(filepath.Join(share, "Movie.2025.mp4"), []byte("0123456789"), 0600); err != nil {
		t.Fatal(err)
	}
	subtitle := "1" + string([]byte{10}) + "00:00:01,000 --> 00:00:04,000" + string([]byte{10}) + "Hello"
	if err := os.WriteFile(filepath.Join(share, "Movie.2025.zh.srt"), []byte(subtitle), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(share, "Movie.2025.nfo"), []byte("<movie><title>可信本地电影名</title><plot>可信本地介绍</plot><rating>9.1</rating></movie>"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := videos.StartScan(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for videos.Status().Running && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if videos.Status().Running || videos.Status().LastError != "" {
		t.Fatalf("scan: %+v", videos.Status())
	}
	found, _, err := videos.List(1, "movie", "", 10, 0)
	if err != nil || len(found) != 1 {
		t.Fatalf("index: %+v %v", found, err)
	}
	id := strconv.FormatInt(found[0].ID, 10)
	if err := accounts.Setup("owner", "strong-owner-password"); err != nil {
		t.Fatal(err)
	}
	ownerToken, err := accounts.Login("owner", "strong-owner-password")
	if err != nil {
		t.Fatal(err)
	}
	member, err := accounts.CreateUser(ownerToken, "viewer", "strong-viewer-password", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	handler := NewWithCinema("", accounts, store, nil, videos)
	call := func(method, url, body string, cookie *http.Cookie) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, url, bytes.NewBufferString(body))
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
	unauthorized := call("GET", "/api/v1/cinema/"+id+"/stream", "", nil)
	if unauthorized.Code != 401 {
		t.Fatalf("unauth stream %d", unauthorized.Code)
	}
	login := call("POST", "/api/v1/auth/login", `{"username":"owner","password":"strong-owner-password"}`, nil)
	if login.Code != 200 || len(login.Result().Cookies()) == 0 {
		t.Fatalf("login %d %s", login.Code, login.Body.String())
	}
	cookie := login.Result().Cookies()[0]
	rangeReq := httptest.NewRequest("GET", "/api/v1/cinema/"+id+"/stream", nil)
	rangeReq.Header.Set("Range", "bytes=2-5")
	rangeReq.AddCookie(cookie)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, rangeReq)
	if response.Code != 206 || response.Body.String() != "2345" {
		t.Fatalf("Range: %d %s", response.Code, response.Body.String())
	}
	captions := call("GET", "/api/v1/cinema/"+id+"/subtitles?lang=zh", "", cookie)
	if captions.Code != 200 || !strings.Contains(captions.Body.String(), "WEBVTT") ||
		!strings.Contains(captions.Body.String(), "00:00:01.000 --> 00:00:04.000") {
		t.Fatalf("SRT to VTT: %d %s", captions.Code, captions.Body.String())
	}
	if r := call("GET", "/api/v1/cinema/"+id+"/subtitles?lang=../../secret", "", cookie); r.Code != 400 {
		t.Fatalf("subtitle traversal permitted %d", r.Code)
	}
	if r := call("PUT", "/api/v1/cinema/"+id+"/progress", `{"position":25,"duration":100,"completed":false}`, cookie); r.Code != 200 {
		t.Fatalf("progress write %d %s", r.Code, r.Body.String())
	}
	viewerFilm, err := videos.Get(found[0].ID, member.ID)
	if err != nil || viewerFilm.Position != 0 {
		t.Fatalf("user isolation: %+v %v", viewerFilm, err)
	}
	ownFilm, err := videos.Get(found[0].ID, 1)
	if err != nil || ownFilm.Position != 25 {
		t.Fatalf("own progress: %+v %v", ownFilm, err)
	}
	if r := call("GET", "/api/v1/cinema/status", "", nil); r.Code != 401 {
		t.Fatalf("open index: %d", r.Code)
	}
	var dump map[string]any
	if err := json.Unmarshal(call("GET", "/api/v1/cinema/"+id, "", cookie).Body.Bytes(), &dump); err != nil {
		t.Fatal(err)
	}
	if dump["position"] != float64(25) {
		t.Fatalf("wrong progress: %+v", dump)
	}
	if r := call("POST", "/api/v1/cinema/"+id+"/metadata/nfo", "", nil); r.Code != 401 {
		t.Fatalf("anonymous imported NFO: %d", r.Code)
	}
	memberToken, err := accounts.Login("viewer", "strong-viewer-password")
	if err != nil {
		t.Fatal(err)
	}
	viewer := &http.Cookie{Name: sessionCookie, Value: memberToken}
	if r := call("POST", "/api/v1/cinema/"+id+"/metadata/nfo", "", viewer); r.Code != 403 {
		t.Fatalf("nonadmin imported NFO: %d", r.Code)
	}
	if r := call("POST", "/api/v1/cinema/"+id+"/metadata/tmdb/search",
		`{"accessToken":"user-supplied-but-private-token","query":"Movie"}`, viewer); r.Code != 403 {
		t.Fatalf("nonadmin called TMDB scraper: %d", r.Code)
	}
	if r := call("POST", "/api/v1/cinema/"+id+"/metadata/tmdb/match",
		`{"accessToken":"user-supplied-but-private-token","tmdbId":123}`, viewer); r.Code != 403 {
		t.Fatalf("nonadmin matched external metadata: %d", r.Code)
	}
	if r := call("POST", "/api/v1/cinema/"+id+"/metadata/douban/search",
		`{"query":"霸王别姬"}`, viewer); r.Code != 403 {
		t.Fatalf("nonadmin used Douban website search: %d", r.Code)
	}
	if r := call("POST", "/api/v1/cinema/"+id+"/metadata/douban/match",
		`{"query":"霸王别姬","doubanId":"1291546"}`, viewer); r.Code != 403 {
		t.Fatalf("nonadmin matched Douban suggestion: %d", r.Code)
	}
	if r := call("POST", "/api/v1/cinema/"+id+"/metadata/douban/search",
		`{"query":"x"}`, cookie); r.Code != 400 {
		t.Fatalf("bad Douban query must fail without contacting website: %d", r.Code)
	}
	if r := call("POST", "/api/v1/cinema/"+id+"/metadata/douban/match",
		`{"query":"霸王别姬","doubanId":"invalid"}`, cookie); r.Code != 400 {
		t.Fatalf("bad Douban subject ID must fail without contacting website: %d", r.Code)
	}
	if r := call("POST", "/api/v1/cinema/"+id+"/metadata/tmdb/search",
		`{"accessToken":"","query":"Movie"}`, cookie); r.Code != 400 {
		t.Fatalf("empty TMDB token should be rejected without contacting upstream: %d", r.Code)
	}
	if r := call("POST", "/api/v1/cinema/"+id+"/metadata/nfo", "", cookie); r.Code != 200 {
		t.Fatalf("admin NFO import %d: %s", r.Code, r.Body.String())
	}
	updated, err := videos.Get(found[0].ID, 1)
	if err != nil || updated.Title != "可信本地电影名" || updated.Overview != "可信本地介绍" || updated.Rating != 9.1 {
		t.Fatalf("movie detail not imported: %+v %v", updated, err)
	}
}
