package server

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
)

func TestResetMemberPasswordHTTPRequiresAdminAndRevokesSessions(t *testing.T) {
	store, err := auth.Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.Setup("owner", "admin-password-12345"); err != nil {
		t.Fatal(err)
	}
	admin, err := store.Login("owner", "admin-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	member, err := store.CreateUser(admin, "family", "family-password-12345", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	memberSession, err := store.Login("family", "family-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	endpoint := "/api/v2/users/" + strconv.FormatInt(member.ID, 10) + "/password"
	h := New("", store, nil)
	call := func(url, session, data string, header bool) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodPost, url, bytes.NewBufferString(data))
		if header {
			r.Header.Set("X-LightIsle-Request", "1")
		}
		if session != "" {
			r.AddCookie(&http.Cookie{Name: sessionCookie, Value: session})
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	body := `{"password":"new-family-password-12345"}`
	for _, tc := range []struct {
		url, session, body string
		header             bool
		status             int
	}{
		{endpoint, "", body, true, 401},
		{endpoint, memberSession, body, true, 403},
		{endpoint, admin, body, false, 403},
		{endpoint, admin, `{"password":"short"}`, true, 400},
		{endpoint, admin, `{"password":"new-family-password-12345","admin":true}`, true, 400},
		{"/api/v2/users/bogus/password", admin, body, true, 400},
	} {
		response := call(tc.url, tc.session, tc.body, tc.header)
		if response.Code != tc.status {
			t.Fatalf("reset %s = %d (expected %d) %s", tc.url, response.Code, tc.status, response.Body.String())
		}
	}
	if !store.Session(memberSession) {
		t.Fatal("failed request revoked member session")
	}
	response := call(endpoint, admin, body, true)
	if response.Code != 200 || !strings.Contains(response.Body.String(), `"sessionsRevoked":true`) {
		t.Fatalf("reset response = %d %s", response.Code, response.Body.String())
	}
	if store.Session(memberSession) {
		t.Fatal("reset failed to revoke member session")
	}
	newSession, err := store.Login("family", "new-family-password-12345")
	if err != nil || !store.Session(newSession) {
		t.Fatalf("new password not accepted: %v", err)
	}
	owner, ok := store.Identity(admin)
	if !ok {
		t.Fatal("admin no longer authenticated")
	}
	other := call("/api/v2/users/"+strconv.FormatInt(owner.ID, 10)+"/password", admin, body, true)
	if other.Code != 403 {
		t.Fatalf("administrator password reset via HTTP = %d", other.Code)
	}
}
