package server

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
)

func TestSMBManagementRoutesAreAdminOnlyAndCSRFProtected(t *testing.T) {
	store, err := auth.Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.Setup("owner", "unique-owner-password"); err != nil {
		t.Fatal(err)
	}
	admin, err := store.Login("owner", "unique-owner-password")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.CreateUser(admin, "member", "unique-member-password", auth.RoleMember); err != nil {
		t.Fatal(err)
	}
	member, err := store.Login("member", "unique-member-password")
	if err != nil {
		t.Fatal(err)
	}
	h := New("", store, nil)
	call := func(method, url, body, session string, csrf bool) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, url, bytes.NewBufferString(body))
		if session != "" {
			req.AddCookie(&http.Cookie{Name: sessionCookie, Value: session})
		}
		if csrf {
			req.Header.Set("X-LightIsle-Request", "1")
		}
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		return rec
	}

	endpoints := []struct {
		method string
		url    string
		body   string
	}{
		{"GET", "/api/v2/admin/smb", ""},
		{"POST", "/api/v2/admin/smb/service", `{"enabled":true}`},
		{"POST", "/api/v2/admin/smb/shares", `{"path":"/Volumes","smbName":"bad"}`},
		{"PATCH", "/api/v2/admin/smb/shares/testshare", `{"smbName":"testshare","shared":true}`},
		{"DELETE", "/api/v2/admin/smb/shares/testshare", ""},
	}
	for _, ep := range endpoints {
		if got := call(ep.method, ep.url, ep.body, "", true); got.Code != http.StatusUnauthorized {
			t.Fatalf("anonymous %s %s: got %d, want 401", ep.method, ep.url, got.Code)
		}
		if got := call(ep.method, ep.url, ep.body, member, true); got.Code != http.StatusForbidden {
			t.Fatalf("member %s %s: got %d, want 403", ep.method, ep.url, got.Code)
		}
		if ep.method != "GET" {
			if got := call(ep.method, ep.url, ep.body, admin, false); got.Code != http.StatusForbidden {
				t.Fatalf("missing CSRF header %s %s: got %d, want 403", ep.method, ep.url, got.Code)
			}
		}
	}

	// Admin invalid/protected path must be rejected before touching sudo.
	if got := call("POST", "/api/v2/admin/smb/shares", `{"path":"/Volumes","smbName":"bad"}`, admin, true); got.Code != http.StatusForbidden {
		t.Fatalf("admin protected path /Volumes: got %d, want 403 (%s)", got.Code, got.Body.String())
	}
	if got := call("POST", "/api/v2/admin/smb/service", `{}`, admin, true); got.Code != http.StatusBadRequest {
		t.Fatalf("admin missing enabled field: got %d, want 400", got.Code)
	}
}
