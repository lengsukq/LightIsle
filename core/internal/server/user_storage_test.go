package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
)

func TestUserStorageQuotaAPIIsAdminOnlyAndExplicitlyUnenforced(t *testing.T) {
	store, err := auth.Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.Setup("owner", "owner-strong-password-2026"); err != nil {
		t.Fatal(err)
	}
	admin, err := store.Login("owner", "owner-strong-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	member, err := store.CreateUser(admin, "family", "family-strong-password-2026", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	memberSession, err := store.Login("family", "family-strong-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	h := New("", store, nil)
	base := "/api/v1/users/" + strconv.FormatInt(member.ID, 10) + "/storage"
	call := func(method, path, session, body string, withOriginGuard bool) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, path, strings.NewReader(body))
		if withOriginGuard {
			r.Header.Set("X-LightIsle-Request", "1")
		}
		if session != "" {
			r.AddCookie(&http.Cookie{Name: sessionCookie, Value: session})
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	for _, tc := range []struct {
		path, session, body string
		guard               bool
		want                int
	}{
		{base + "/quota", "", `{"quotaBytes":1000}`, true, 401},
		{base + "/quota", memberSession, `{"quotaBytes":1000}`, true, 403},
		{base + "/quota", admin, `{"quotaBytes":1000}`, false, 403},
		{base + "/quota", admin, `{}`, true, 400},
		{base + "/quota", admin, `{"quotaBytes":-1}`, true, 400},
		{base + "/quota", admin, `{"quotaBytes":1000,"unexpected":1}`, true, 400},
		{"/api/v1/users/nope/storage/quota", admin, `{"quotaBytes":1000}`, true, 400},
	} {
		response := call(http.MethodPut, tc.path, tc.session, tc.body, tc.guard)
		if response.Code != tc.want {
			t.Fatalf("%s got %d want %d: %s", tc.path, response.Code, tc.want, response.Body.String())
		}
	}
	unauthorized := call(http.MethodGet, base, memberSession, "", false)
	if unauthorized.Code != 403 {
		t.Fatalf("member listed another user's administrator endpoint: %d", unauthorized.Code)
	}
	self := call(http.MethodGet, "/api/v1/me/storage", memberSession, "", false)
	if self.Code != 200 {
		t.Fatalf("member cannot see own quota: %d %s", self.Code, self.Body.String())
	}
	var policy auth.StoragePolicy
	if err := json.Unmarshal(self.Body.Bytes(), &policy); err != nil || policy.QuotaBytes == nil ||
		*policy.QuotaBytes != auth.DefaultMemberQuotaBytes || policy.Enforcement != "pending" {
		t.Fatalf("default quota or pending status misreported: %+v %v", policy, err)
	}
	updated := call(http.MethodPut, base+"/quota", admin, `{"quotaBytes":21474836480}`, true)
	if updated.Code != 200 {
		t.Fatalf("admin failed to configure quota: %d %s", updated.Code, updated.Body.String())
	}
	if err := json.Unmarshal(updated.Body.Bytes(), &policy); err != nil || policy.QuotaBytes == nil ||
		*policy.QuotaBytes != 20<<30 || policy.Enforcement != "pending" {
		t.Fatalf("quota setting misreported actual enforcement: %+v %v", policy, err)
	}
}
