package server

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/cinema"
	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestRound4SearchFilesAndCinemaFiltersAndClearProgress(t *testing.T) {
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
	for _, dir := range []string{
		filepath.Join(share, "2026"),
		filepath.Join(share, "Movies4K"),
		filepath.Join(share, "PrivateMovies"),
	} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(share, "税.pdf"), []byte("tax-exact"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(share, "2026", "租房合同_税务附件.pdf"), []byte("tax-sub"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(share, "Movies4K", "Wandering.2019.mp4"), []byte("0123456789"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(share, "Movies4K", "Wandering.2019.nfo"), []byte("<movie><title>流浪地球</title><rating>8.5</rating><year>2019</year></movie>"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(share, "PrivateMovies", "Secret.2024.mp4"), []byte("0123456789"), 0o600); err != nil {
		t.Fatal(err)
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
	ownerToken, err := accounts.Login("owner", "strong-owner-password")
	if err != nil {
		t.Fatal(err)
	}
	member, err := accounts.CreateUser(ownerToken, "member", "strong-member-password", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	if err := accounts.SetFileGrant(ownerToken, member.ID, "Movies4K", false); err != nil {
		t.Fatal(err)
	}
	if err := accounts.SetFileGrant(ownerToken, member.ID, "2026", false); err != nil {
		t.Fatal(err)
	}
	memberToken, err := accounts.Login("member", "strong-member-password")
	if err != nil {
		t.Fatal(err)
	}

	handler := NewWithCinema("", accounts, store, nil, videos)
	ownerCookie := &http.Cookie{Name: sessionCookie, Value: ownerToken}
	memberCookie := &http.Cookie{Name: sessionCookie, Value: memberToken}

	call := func(method, target, body string, cookie *http.Cookie) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, target, bytes.NewBufferString(body))
		if method != http.MethodGet && method != http.MethodHead {
			req.Header.Set("X-LightIsle-Request", "1")
		}
		if cookie != nil {
			req.AddCookie(cookie)
		}
		out := httptest.NewRecorder()
		handler.ServeHTTP(out, req)
		return out
	}

	// 1. Single-char Chinese file search with relevance ranking ("税.pdf" ranks before "2026/租房合同_税务附件.pdf").
	resSearch := call(http.MethodGet, "/api/v2/files/search?path=.&query="+url.QueryEscape("税"), "", ownerCookie)
	if resSearch.Code != http.StatusOK {
		t.Fatalf("search status=%d body=%s", resSearch.Code, resSearch.Body.String())
	}
	var searchBody struct {
		Entries []struct {
			Path string `json:"path"`
		} `json:"entries"`
	}
	if err := json.Unmarshal(resSearch.Body.Bytes(), &searchBody); err != nil {
		t.Fatal(err)
	}
	if len(searchBody.Entries) != 2 || searchBody.Entries[0].Path != "税.pdf" {
		t.Fatalf("expected exact stem 税.pdf ranked #1, got %+v", searchBody.Entries)
	}

	// Subfolder scope path=2026 returns only the file inside 2026/.
	resSub := call(http.MethodGet, "/api/v2/files/search?path=2026&query="+url.QueryEscape("2026 合同"), "", memberCookie)
	if resSub.Code != http.StatusOK {
		t.Fatalf("sub search status=%d body=%s", resSub.Code, resSub.Body.String())
	}
	if err := json.Unmarshal(resSub.Body.Bytes(), &searchBody); err != nil {
		t.Fatal(err)
	}
	if len(searchBody.Entries) != 1 || searchBody.Entries[0].Path != "2026/租房合同_税务附件.pdf" {
		t.Fatalf("expected 2026/租房合同_税务附件.pdf, got %+v", searchBody.Entries)
	}

	// 2. Cinema NFO import + multi-keyword search + watched filter + DELETE /progress + permission isolation.
	allFilms, _, err := videos.List(1, "", "", 10, 0)
	if err != nil || len(allFilms) != 2 {
		t.Fatalf("films: %+v %v", allFilms, err)
	}
	var publicFilmID, secretFilmID int64
	for _, f := range allFilms {
		if filepath.Dir(f.Path) == "Movies4K" {
			publicFilmID = f.ID
		} else {
			secretFilmID = f.ID
		}
	}
	pubIDStr := strconv.FormatInt(publicFilmID, 10)
	secIDStr := strconv.FormatInt(secretFilmID, 10)
	if r := call(http.MethodPost, "/api/v2/cinema/"+pubIDStr+"/metadata/nfo", "", ownerCookie); r.Code != http.StatusOK {
		t.Fatalf("nfo import: %d %s", r.Code, r.Body.String())
	}

	// Member searches multi-keyword "流浪 Movies4K" via search= alias + sort=rating + watched=unwatched.
	resCinema := call(http.MethodGet, "/api/v2/cinema?watched=unwatched&sort=rating&search="+url.QueryEscape("流浪 Movies4K"), "", memberCookie)
	if resCinema.Code != http.StatusOK {
		t.Fatalf("cinema list: %d %s", resCinema.Code, resCinema.Body.String())
	}
	var cinemaListBody struct {
		Films []cinema.Film `json:"films"`
	}
	if err := json.Unmarshal(resCinema.Body.Bytes(), &cinemaListBody); err != nil {
		t.Fatal(err)
	}
	if len(cinemaListBody.Films) != 1 || cinemaListBody.Films[0].ID != publicFilmID {
		t.Fatalf("expected publicFilmID from multi-keyword search, got %+v", cinemaListBody.Films)
	}

	// Save progress -> appears in kind=continue -> DELETE /progress clears it!
	if r := call(http.MethodPut, "/api/v2/cinema/"+pubIDStr+"/progress", `{"position":120,"duration":3600,"completed":false}`, memberCookie); r.Code != http.StatusOK {
		t.Fatalf("save progress: %d %s", r.Code, r.Body.String())
	}
	if r := call(http.MethodDelete, "/api/v2/cinema/"+pubIDStr+"/progress", "", memberCookie); r.Code != http.StatusOK {
		t.Fatalf("clear progress: %d %s", r.Code, r.Body.String())
	}
	resCont := call(http.MethodGet, "/api/v2/cinema?kind=continue", "", memberCookie)
	_ = json.Unmarshal(resCont.Body.Bytes(), &cinemaListBody)
	if len(cinemaListBody.Films) != 0 {
		t.Fatalf("expected continue watching empty after DELETE /progress, got %+v", cinemaListBody.Films)
	}

	// POST /watched with {"watched": true} alias marks watched -> watched=watched returns 1!
	if r := call(http.MethodPost, "/api/v2/cinema/"+pubIDStr+"/watched", `{"watched":true}`, memberCookie); r.Code != http.StatusOK {
		t.Fatalf("mark watched alias: %d %s", r.Code, r.Body.String())
	}
	resWatched := call(http.MethodGet, "/api/v2/cinema?watched=watched", "", memberCookie)
	_ = json.Unmarshal(resWatched.Body.Bytes(), &cinemaListBody)
	if len(cinemaListBody.Films) != 1 || !cinemaListBody.Films[0].Completed {
		t.Fatalf("expected watched=watched to return 1 completed film, got %+v", cinemaListBody.Films)
	}

	// Member attempting DELETE /progress on unauthorized secretFilmID is rejected and cannot touch owner progress.
	if r := call(http.MethodPut, "/api/v2/cinema/"+secIDStr+"/progress", `{"position":500,"duration":3600,"completed":false}`, ownerCookie); r.Code != http.StatusOK {
		t.Fatalf("owner save secret progress: %d %s", r.Code, r.Body.String())
	}
	if r := call(http.MethodDelete, "/api/v2/cinema/"+secIDStr+"/progress", "", memberCookie); r.Code != http.StatusForbidden && r.Code != http.StatusNotFound {
		t.Fatalf("expected 403/404 for unauthorized film progress delete, got %d %s", r.Code, r.Body.String())
	}
	secretCheck, err := videos.Get(secretFilmID, 1)
	if err != nil || secretCheck.Position != 500 {
		t.Fatalf("owner progress on secret film was modified: %+v err=%v", secretCheck, err)
	}
}
