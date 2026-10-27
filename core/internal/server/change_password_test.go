package server

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
)

func TestSelfServicePasswordEndpointRequiresExistingPasswordAndRevokesSessions(t *testing.T) {
	accounts, err := auth.Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("owner", "old-password-123456"); err != nil {
		t.Fatal(err)
	}
	first, err := accounts.Login("owner", "old-password-123456")
	if err != nil {
		t.Fatal(err)
	}
	second, err := accounts.Login("owner", "old-password-123456")
	if err != nil {
		t.Fatal(err)
	}
	h := New("", accounts, nil)
	call := func(session, body string, header bool) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, "/api/v2/auth/password", bytes.NewBufferString(body))
		req.RemoteAddr = "127.0.0.1:1234"
		if header {
			req.Header.Set("X-LightIsle-Request", "1")
		}
		if session != "" {
			req.AddCookie(&http.Cookie{Name: sessionCookie, Value: session})
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req)
		return w
	}
	for _, tc := range []struct {
		session, body string
		header        bool
		code          int
	}{
		{"", `{"currentPassword":"old-password-123456","newPassword":"changed-password-1234"}`, true, 401},
		{first, `{"currentPassword":"old-password-123456","newPassword":"changed-password-1234"}`, false, 403},
		{first, `{"currentPassword":"invalid-password","newPassword":"changed-password-1234"}`, true, 401},
		{first, `{"currentPassword":"old-password-123456","newPassword":"short"}`, true, 400},
		{first, `{"currentPassword":"old-password-123456","newPassword":"changed-password-1234","extra":1}`, true, 400},
	} {
		w := call(tc.session, tc.body, tc.header)
		if w.Code != tc.code {
			t.Fatalf("password request = %d, want %d: %s", w.Code, tc.code, w.Body.String())
		}
	}
	if !accounts.Session(first) || !accounts.Session(second) {
		t.Fatal("failed change revoked sessions")
	}
	w := call(first, `{"currentPassword":"old-password-123456","newPassword":"changed-password-1234"}`, true)
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"changed":true`) {
		t.Fatalf("password change failed: %d %s", w.Code, w.Body.String())
	}
	if accounts.Session(first) || accounts.Session(second) {
		t.Fatal("sessions remain valid")
	}
	if len(w.Result().Cookies()) == 0 || w.Result().Cookies()[0].MaxAge != -1 {
		t.Fatalf("client cookie not expired: %v", w.Result().Cookies())
	}
	if w := call(second, `{"currentPassword":"changed-password-1234","newPassword":"next-password-123456"}`, true); w.Code != 401 {
		t.Fatalf("other device could update password: %d", w.Code)
	}
}
