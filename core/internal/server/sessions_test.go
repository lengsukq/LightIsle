package server

import (
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
)

func TestSessionAPIEnforcesLoginAndCSRFAndRevokesOtherDevices(t *testing.T) {
	accounts, err := auth.Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("owner", "owner-password-12345"); err != nil {
		t.Fatal(err)
	}
	first, err := accounts.Login("owner", "owner-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	second, err := accounts.Login("owner", "owner-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	h := New("", accounts, nil)
	call := func(method, url, session string, header bool) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, url, nil)
		if session != "" {
			r.AddCookie(&http.Cookie{Name: sessionCookie, Value: session})
		}
		if header {
			r.Header.Set("X-LightIsle-Request", "1")
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	if out := call("GET", "/api/v1/auth/sessions", "", false); out.Code != 401 {
		t.Fatalf("unauthorized list = %d", out.Code)
	}
	out := call("GET", "/api/v1/auth/sessions", first, false)
	if out.Code != 200 || !strings.Contains(out.Body.String(), `"current":true`) {
		t.Fatalf("list = %d %s", out.Code, out.Body.String())
	}
	if out := call("DELETE", "/api/v1/auth/sessions/others", first, false); out.Code != 403 {
		t.Fatalf("missing CSRF guard = %d", out.Code)
	}
	if out := call("DELETE", "/api/v1/auth/sessions/not-hex", first, true); out.Code != 400 {
		t.Fatalf("invalid session ID = %d", out.Code)
	}
	if out := call("DELETE", "/api/v1/auth/sessions/others", first, true); out.Code != 200 {
		t.Fatalf("revoke other sessions = %d %s", out.Code, out.Body.String())
	}
	if !accounts.Session(first) || accounts.Session(second) {
		t.Fatal("other device not revoked or current device lost")
	}
}
