package server

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
)

func TestDiskManagementRoutesAreAdminOnlyAndCSRFProtected(t *testing.T) {
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
	call := func(method, url, session string, csrf bool) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, url, bytes.NewBufferString(`{"action":"eject","id":"disk8s1","identity":"not-a-real-device"}`))
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
	for _, endpoint := range []struct{ method, url string }{
		{"GET", "/api/v2/admin/disks"},
		{"GET", "/api/v2/admin/disks/disk8s1/smart/history"},
		{"POST", "/api/v2/admin/disks/actions"},
	} {
		if got := call(endpoint.method, endpoint.url, "", true); got.Code != 401 {
			t.Fatalf("anonymous %s %s: %d", endpoint.method, endpoint.url, got.Code)
		}
		if got := call(endpoint.method, endpoint.url, member, true); got.Code != 403 {
			t.Fatalf("member %s %s: %d", endpoint.method, endpoint.url, got.Code)
		}
	}
	if got := call("POST", "/api/v2/admin/disks/actions", admin, false); got.Code != 403 {
		t.Fatalf("missing request header: %d", got.Code)
	}
	if got := call("POST", "/api/v2/admin/disks/actions", admin, true); got.Code != 400 {
		t.Fatalf("admin invalid device ID not rejected: %d", got.Code)
	}
}
