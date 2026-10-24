package dav

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
)

type fixture struct {
	root          string
	trashed       []string
	service       *Service
	adminName     string
	adminPassword string
	memberName    string
	memberPass    string
	memberSession string
}

func newFixture(t *testing.T) (*fixture, *Service) {
	t.Helper()
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "photos"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "private"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "photos", "a.txt"), []byte("in photos"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "private", "b.txt"), []byte("secret"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "top.txt"), []byte("root file"), 0600); err != nil {
		t.Fatal(err)
	}
	store, err := auth.Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	if err := store.Setup("boss", "correct-horse-1"); err != nil {
		t.Fatal(err)
	}
	adminSession, err := store.Login("boss", "correct-horse-1")
	if err != nil {
		t.Fatal(err)
	}
	member, err := store.CreateUser(adminSession, "leo", "member-pass-1", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.SetFileGrant(adminSession, member.ID, "photos", true); err != nil {
		t.Fatal(err)
	}
	memberSession, err := store.Login("leo", "member-pass-1")
	if err != nil {
		t.Fatal(err)
	}

	f := &fixture{
		root:       root,
		adminName:  "boss",
		memberName: "leo",
	}
	// WebDAV passwords are independent of account passwords: mint one per
	// account exactly as the self-service endpoint would.
	if _, f.adminPassword, err = store.CreateDAVCredential(adminSession, "qa-admin"); err != nil {
		t.Fatal(err)
	}
	if _, f.memberPass, err = store.CreateDAVCredential(memberSession, "qa-member"); err != nil {
		t.Fatal(err)
	}
	f.service = New(store, func() (string, bool) { return root, true }, func(rel string) error {
		f.trashed = append(f.trashed, rel)
		if err := os.RemoveAll(filepath.Join(root, filepath.FromSlash(rel))); err != nil {
			return err
		}
		return nil
	})
	return f, f.service
}

func (f *fixture) request(t *testing.T, method, target, user, password string, body io.Reader, headers map[string]string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, target, body)
	if user != "" {
		req.SetBasicAuth(user, password)
	}
	for key, value := range headers {
		req.Header.Set(key, value)
	}
	rec := httptest.NewRecorder()
	f.service.ServeHTTP(rec, req)
	return rec
}

func (f *fixture) propfind(t *testing.T, target, user, password string) (int, string) {
	t.Helper()
	body := `<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:displayname/></d:prop></d:propfind>`
	rec := f.request(t, "PROPFIND", target, user, password, strings.NewReader(body), map[string]string{"Depth": "1"})
	data, _ := io.ReadAll(rec.Body)
	return rec.Code, string(data)
}

func TestAdminSeesWholeRoot(t *testing.T) {
	f, _ := newFixture(t)
	code, body := f.propfind(t, "/dav/", f.adminName, f.adminPassword)
	if code != http.StatusMultiStatus {
		t.Fatalf("admin PROPFIND status = %d", code)
	}
	for _, want := range []string{"photos/", "private/", "top.txt"} {
		if !strings.Contains(body, want) {
			t.Errorf("admin listing missing %s", want)
		}
	}
}

func TestMemberListingFiltersUnauthorizedSiblings(t *testing.T) {
	f, _ := newFixture(t)
	code, body := f.propfind(t, "/dav/", f.memberName, f.memberPass)
	if code != http.StatusMultiStatus {
		t.Fatalf("member PROPFIND status = %d body %s", code, body)
	}
	if !strings.Contains(body, "photos/") {
		t.Error("granted subtree must be visible")
	}
	if strings.Contains(body, "private/") || strings.Contains(body, "top.txt") {
		t.Errorf("unauthorized siblings leaked: %s", body)
	}
}

func TestMemberReadWriteInsideGrant(t *testing.T) {
	f, _ := newFixture(t)
	rec := f.request(t, "PUT", "/dav/photos/new.txt", f.memberName, f.memberPass, strings.NewReader("hello"), nil)
	if rec.Code != http.StatusCreated {
		t.Fatalf("PUT inside grant status = %d: %s", rec.Code, rec.Body.String())
	}
	data, err := os.ReadFile(filepath.Join(f.root, "photos", "new.txt"))
	if err != nil || string(data) != "hello" {
		t.Fatalf("uploaded file = %q, %v", data, err)
	}
	rec = f.request(t, "GET", "/dav/photos/a.txt", f.memberName, f.memberPass, nil, nil)
	if rec.Code != http.StatusOK || rec.Body.String() != "in photos" {
		t.Fatalf("GET inside grant = %d %q", rec.Code, rec.Body.String())
	}
}

func TestMemberWritesOutsideGrantRefused(t *testing.T) {
	f, _ := newFixture(t)
	// x/net/webdav maps every non-ENOENT OpenFile failure on PUT to 404
	// (anti-probing); the operation must still be refused and touch nothing.
	for _, target := range []string{"/dav/leak.txt", "/dav/private/new.txt"} {
		rec := f.request(t, "PUT", target, f.memberName, f.memberPass, strings.NewReader("no"), nil)
		if rec.Code != http.StatusNotFound {
			t.Errorf("PUT %s status = %d, want 404", target, rec.Code)
		}
	}
	if _, err := os.Stat(filepath.Join(f.root, "leak.txt")); !os.IsNotExist(err) {
		t.Error("unauthorized PUT must not touch the filesystem")
	}
}

func TestDeleteMovesToTrash(t *testing.T) {
	f, _ := newFixture(t)
	rec := f.request(t, "DELETE", "/dav/photos/a.txt", f.memberName, f.memberPass, nil, nil)
	if rec.Code != http.StatusNoContent && rec.Code != http.StatusOK {
		t.Fatalf("DELETE status = %d: %s", rec.Code, rec.Body.String())
	}
	if _, err := os.Stat(filepath.Join(f.root, "photos", "a.txt")); !os.IsNotExist(err) {
		t.Fatal("deleted file must leave the live tree")
	}
	if len(f.trashed) != 1 || f.trashed[0] != "photos/a.txt" {
		t.Fatalf("trash = %v, want photos/a.txt", f.trashed)
	}
	// Deleting outside the grant or the mount root is always refused
	// (x/net maps RemoveAll permission failures to 405).
	for _, target := range []string{"/dav/private/b.txt", "/dav/", "/dav/top.txt"} {
		rec := f.request(t, "DELETE", target, f.memberName, f.memberPass, nil, nil)
		if rec.Code != http.StatusMethodNotAllowed {
			t.Errorf("DELETE %s status = %d, want 405", target, rec.Code)
		}
	}
}

func TestLockAndUnlock(t *testing.T) {
	f, _ := newFixture(t)
	lockBody := `<?xml version="1.0"?><d:lockinfo xmlns:d="DAV:"><d:lockscope><d:exclusive/></d:lockscope><d:locktype><d:write/></d:locktype><d:owner>qa</d:owner></d:lockinfo>`
	rec := f.request(t, "LOCK", "/dav/photos/a.txt", f.memberName, f.memberPass, strings.NewReader(lockBody),
		map[string]string{"Timeout": "Second-600"})
	if rec.Code != http.StatusOK {
		t.Fatalf("LOCK status = %d: %s", rec.Code, rec.Body.String())
	}
	token := rec.Header().Get("Lock-Token")
	if token == "" {
		t.Fatal("LOCK response missing lock token")
	}
	// Second exclusive lock by the same principal must conflict.
	rec = f.request(t, "LOCK", "/dav/photos/a.txt", f.adminName, f.adminPassword, strings.NewReader(lockBody), nil)
	if rec.Code != http.StatusLocked {
		t.Fatalf("second exclusive LOCK status = %d, want 423", rec.Code)
	}
	rec = f.request(t, "UNLOCK", "/dav/photos/a.txt", f.memberName, f.memberPass, nil,
		map[string]string{"Lock-Token": token})
	if rec.Code != http.StatusNoContent && rec.Code != http.StatusOK {
		t.Fatalf("UNLOCK status = %d", rec.Code)
	}
}

func TestUnauthorizedAndCookieNeverWork(t *testing.T) {
	f, _ := newFixture(t)
	rec := f.request(t, "PROPFIND", "/dav/", "", "", strings.NewReader(""), map[string]string{"Depth": "0"})
	if rec.Code != http.StatusUnauthorized || rec.Header().Get("WWW-Authenticate") == "" {
		t.Fatalf("anonymous status = %d", rec.Code)
	}
	rec = f.request(t, "PROPFIND", "/dav/", "boss", "wrong-password", strings.NewReader(""), map[string]string{"Depth": "0"})
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("bad password status = %d", rec.Code)
	}
	// A stolen web session cookie grants nothing on /dav/.
	rec = f.request(t, "GET", "/dav/top.txt", "", "", nil,
		map[string]string{"Cookie": "lightisle_session=anything"})
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("cookie-only status = %d, want 401", rec.Code)
	}
}

func TestDisabledAccountRejected(t *testing.T) {
	f, svc := newFixture(t)
	store := svc.store
	// Logins use the account password; only the DAV minted password (already
	// stored in f.memberPass) authenticates on /dav/.
	session, err := store.Login("boss", "correct-horse-1")
	if err != nil {
		t.Fatal(err)
	}
	users, err := store.ListUsers(session)
	if err != nil {
		t.Fatal(err)
	}
	for _, user := range users {
		if user.Username == "leo" {
			if err := store.SetEnabled(session, user.ID, false); err != nil {
				t.Fatal(err)
			}
		}
	}
	rec := f.request(t, "GET", "/dav/photos/a.txt", f.memberName, f.memberPass, nil, nil)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("disabled account status = %d, want 401", rec.Code)
	}
}

func TestAuthFailureThrottle(t *testing.T) {
	f, _ := newFixture(t)
	for i := 0; i < authFailureLimit; i++ {
		rec := f.request(t, "GET", "/dav/top.txt", "boss", "wrong", nil, nil)
		if rec.Code != http.StatusUnauthorized {
			t.Fatalf("attempt %d status = %d", i, rec.Code)
		}
	}
	// Correct credentials no longer help: the client address is throttled.
	rec := f.request(t, "GET", "/dav/top.txt", f.adminName, f.adminPassword, nil, nil)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("throttled status = %d, want 401", rec.Code)
	}
}

func TestCredentialLifecycle(t *testing.T) {
	_, svc := newFixture(t)
	store := svc.store
	session, err := store.Login("boss", "correct-horse-1")
	if err != nil {
		t.Fatal(err)
	}
	credential, password, err := store.CreateDAVCredential(session, "Finder")
	if err != nil {
		t.Fatal(err)
	}
	if len(password) < 20 {
		t.Fatalf("generated password too weak: %q", password)
	}
	if _, err := store.VerifyDAVCredential("boss", password); err != nil {
		t.Fatalf("fresh credential rejected: %v", err)
	}
	listed, err := store.ListDAVCredentials(session)
	if err != nil || len(listed) != 2 {
		t.Fatalf("list = %+v, %v", listed, err)
	}
	found := false
	for _, item := range listed {
		if item.Label == "Finder" {
			found = true
		}
	}
	if !found {
		t.Fatalf("new credential missing from list: %+v", listed)
	}
	if err := store.RevokeDAVCredential(session, credential.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.VerifyDAVCredential("boss", password); err == nil {
		t.Fatal("revoked credential still verifies")
	}
	if err := store.RevokeDAVCredential(session, credential.ID); err == nil {
		t.Fatal("double revoke must report not found")
	}
}

func TestOfflineRootRejected(t *testing.T) {
	f, svc := newFixture(t)
	svc.root = func() (string, bool) { return f.root, false }
	rec := f.request(t, "GET", "/dav/top.txt", f.adminName, f.adminPassword, nil, nil)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("offline root status = %d, want 503", rec.Code)
	}
}

func TestRelativePath(t *testing.T) {
	cases := map[string]string{
		"/":          ".",
		"/photos":    "photos",
		"/photos/a":  "photos/a",
		"/a/b/c.txt": "a/b/c.txt",
		"a/b/c.txt":  "a/b/c.txt",
	}
	for input, want := range cases {
		if got := relativePath(input); got != want {
			t.Errorf("relativePath(%q) = %q, want %q", input, got, want)
		}
	}
}
