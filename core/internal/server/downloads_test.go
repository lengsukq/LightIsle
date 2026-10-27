package server

import (
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
)

// The download endpoints degrade honestly when the manager is absent
// (single-binary tests, or aria2 missing on the host).
func TestDownloadEndpointsHonestWithoutManager(t *testing.T) {
	dir := t.TempDir()
	accounts, err := auth.Open(filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("owner", "owner-password-12345"); err != nil {
		t.Fatal(err)
	}
	store, err := files.Open(filepath.Join(dir, "SharedFiles"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	handler := New("", accounts, store)
	login := func() *http.Cookie {
		t.Helper()
		request := httptest.NewRequest(http.MethodPost, "/api/v2/auth/login",
			strings.NewReader(`{"username":"owner","password":"owner-password-12345"}`))
		request.RemoteAddr = "192.168.1.4:1000"
		request.Header.Set("X-LightIsle-Request", "1")
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		for _, cookie := range response.Result().Cookies() {
			if cookie.Name == sessionCookie {
				return cookie
			}
		}
		t.Fatal("no session cookie")
		return nil
	}
	call := func(method, url, body string) *httptest.ResponseRecorder {
		request := httptest.NewRequest(method, url, strings.NewReader(body))
		request.RemoteAddr = "192.168.1.4:1000"
		if method != http.MethodGet {
			request.Header.Set("X-LightIsle-Request", "1")
		}
		request.AddCookie(login())
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		return response
	}
	if response := call(http.MethodGet, "/api/v2/downloads/status", ""); response.Code != http.StatusOK ||
		!strings.Contains(response.Body.String(), `"available":false`) {
		t.Fatalf("status without manager: %d %s", response.Code, response.Body.String())
	}
	for _, target := range []struct{ method, url, body string }{
		{http.MethodGet, "/api/v2/downloads", ""},
		{http.MethodPost, "/api/v2/downloads", `{"url":"https://example.com/x","destination":"."}`},
		{http.MethodPost, "/api/v2/downloads/x/actions", `{"action":"pause"}`},
		{http.MethodDelete, "/api/v2/downloads/x", ""},
	} {
		if response := call(target.method, target.url, target.body); response.Code != http.StatusServiceUnavailable ||
			!strings.Contains(response.Body.String(), "download_unavailable") {
			t.Fatalf("%s %s without manager: %d %s", target.method, target.url, response.Code, response.Body.String())
		}
	}
}
