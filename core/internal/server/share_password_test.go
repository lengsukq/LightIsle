package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestPublicSharePasswordAndDownloadCount(t *testing.T) {
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
	share := filepath.Join(data, "SharedFiles")
	if err := os.WriteFile(filepath.Join(share, "secret.txt"), []byte("top-secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := accounts.Setup("owner", "long-owner-password"); err != nil {
		t.Fatal(err)
	}
	handler := NewWithCinema("", accounts, store, nil, nil)
	call := func(method, url, body string, cookie *http.Cookie) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, url, strings.NewReader(body))
		if method != "GET" && method != "HEAD" {
			if strings.HasPrefix(url, "/api/v1/public/file/") {
				// A real HTML form cannot attach X-LightIsle-Request.
				req.Header.Set("Origin", "http://example.com")
			} else {
				req.Header.Set("X-LightIsle-Request", "1")
			}
			if strings.HasPrefix(body, "{") {
				req.Header.Set("Content-Type", "application/json")
			} else {
				req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
			}
		}
		if cookie != nil {
			req.AddCookie(cookie)
		}
		out := httptest.NewRecorder()
		handler.ServeHTTP(out, req)
		return out
	}
	login := call("POST", "/api/v1/auth/login", `{"username":"owner","password":"long-owner-password"}`, nil)
	cookie := login.Result().Cookies()[0]
	created := call("POST", "/api/v1/file-shares",
		`{"path":"secret.txt","hours":1,"password":"open-sesame","maxDownloads":1}`, cookie)
	if created.Code != 201 {
		t.Fatalf("create share %d %s", created.Code, created.Body.String())
	}
	var payload struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(created.Body.Bytes(), &payload); err != nil || payload.Token == "" {
		t.Fatalf("payload: %s", created.Body.String())
	}
	link := "/api/v1/public/file/" + payload.Token

	// Without a grant the link answers the password form, never the file.
	challenge := call("GET", link, "", nil)
	if challenge.Code != http.StatusUnauthorized || !strings.Contains(challenge.Body.String(), "受密码保护") {
		t.Fatalf("challenge %d %s", challenge.Code, challenge.Body.String())
	}
	if strings.Contains(challenge.Body.String(), "top-secret") {
		t.Fatal("challenge leaked the file content")
	}
	if !strings.Contains(challenge.Body.String(), `action="`+link+`"`) ||
		!strings.Contains(challenge.Header().Get("Content-Security-Policy"), "form-action 'self'") ||
		strings.Contains(challenge.Header().Get("Content-Security-Policy"), "sandbox") {
		t.Fatalf("native browser form cannot submit safely: %q %s", challenge.Header().Get("Content-Security-Policy"), challenge.Body.String())
	}
	// A wrong password stays on the form with an explicit message.
	wrong := call("POST", link, "password=nope", nil)
	if wrong.Code != http.StatusUnauthorized || !strings.Contains(wrong.Body.String(), "密码不正确") {
		t.Fatalf("wrong password %d %s", wrong.Code, wrong.Body.String())
	}
	// The correct password mints the grant and redirects back to the link.
	right := call("POST", link, "password=open-sesame", nil)
	if right.Code != http.StatusSeeOther {
		t.Fatalf("grant %d %s", right.Code, right.Body.String())
	}
	var grant *http.Cookie
	for _, c := range right.Result().Cookies() {
		if c.Name == shareGrantCookie {
			grant = c
		}
	}
	if grant == nil {
		t.Fatal("grant cookie missing")
	}
	if right.Header().Get("Location") != link || grant.Path != "/api/v1/public/file/" {
		t.Fatalf("bad v1 grant redirect/cookie path: %s %+v", right.Header().Get("Location"), grant)
	}
	// An unavailable file may not spend the link's one allowed download.
	away := filepath.Join(share, "temporarily-offline.txt")
	if err := os.Rename(filepath.Join(share, "secret.txt"), away); err != nil {
		t.Fatal(err)
	}
	if unavailable := call("GET", link, "", grant); unavailable.Code != http.StatusNotFound {
		t.Fatalf("unavailable file = %d", unavailable.Code)
	}
	if err := os.Rename(away, filepath.Join(share, "secret.txt")); err != nil {
		t.Fatal(err)
	}
	// HEAD, conditional caching and malformed ranges do not start downloads.
	head := call("HEAD", link, "", grant)
	if head.Code != http.StatusOK {
		t.Fatalf("HEAD unexpectedly failed: %d", head.Code)
	}
	badRangeRequest := httptest.NewRequest(http.MethodGet, link, nil)
	badRangeRequest.AddCookie(grant)
	badRangeRequest.Header.Set("Range", "bytes=999999-")
	badRange := httptest.NewRecorder()
	handler.ServeHTTP(badRange, badRangeRequest)
	if badRange.Code != http.StatusRequestedRangeNotSatisfiable {
		t.Fatalf("invalid range response = %d %s", badRange.Code, badRange.Body.String())
	}
	conditional := httptest.NewRequest(http.MethodGet, link, nil)
	conditional.AddCookie(grant)
	conditional.Header.Set("If-Modified-Since", time.Now().Add(time.Hour).UTC().Format(http.TimeFormat))
	notModified := httptest.NewRecorder()
	handler.ServeHTTP(notModified, conditional)
	if notModified.Code != http.StatusNotModified {
		t.Fatalf("conditional GET = %d", notModified.Code)
	}
	download := call("GET", link, "", grant)
	if download.Code != 200 || download.Body.String() != "top-secret" {
		t.Fatalf("download %d %s", download.Code, download.Body.String())
	}
	// The single allowed download is consumed; the link now reads as gone.
	exhausted := call("GET", link, "", grant)
	if exhausted.Code != 404 {
		t.Fatalf("exhausted %d", exhausted.Code)
	}
	// The password form no longer promises a file either.
	again := call("POST", link, "password=open-sesame", nil)
	if again.Code != 404 {
		t.Fatalf("post-exhaustion grant %d", again.Code)
	}
}
