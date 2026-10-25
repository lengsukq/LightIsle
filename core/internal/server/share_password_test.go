package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

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
			req.Header.Set("X-LightIsle-Request", "1")
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
