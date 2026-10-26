package dav

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/net/webdav"

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

func TestLockNamespacesResetOnShareRootSwitch(t *testing.T) {
	f, _ := newFixture(t)
	secondRoot := t.TempDir()
	if err := os.MkdirAll(filepath.Join(secondRoot, "photos"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(secondRoot, "photos", "a.txt"), []byte("second root"), 0600); err != nil {
		t.Fatal(err)
	}
	currentRoot := f.root
	f.service.root = func() (string, bool) { return currentRoot, true }
	lockBody := `<?xml version="1.0"?><d:lockinfo xmlns:d="DAV:"><d:lockscope><d:exclusive/></d:lockscope><d:locktype><d:write/></d:locktype><d:owner>qa</d:owner></d:lockinfo>`
	lock := func() string {
		t.Helper()
		rec := f.request(t, "LOCK", "/dav/photos/a.txt", f.memberName, f.memberPass, strings.NewReader(lockBody), nil)
		if rec.Code != http.StatusOK {
			t.Fatalf("LOCK status = %d: %s", rec.Code, rec.Body.String())
		}
		token := strings.Trim(rec.Header().Get("Lock-Token"), "<>")
		if token == "" {
			t.Fatal("LOCK response missing token")
		}
		return token
	}

	rootAToken := lock() // No Timeout requests an infinite lock in x/net/webdav.
	currentRoot = secondRoot
	rootBToken := lock()
	if rootBToken == rootAToken {
		t.Fatal("separate physical roots received the same lock token")
	}
	rec := f.request(t, "LOCK", "/dav/photos/a.txt", f.memberName, f.memberPass, nil,
		map[string]string{"If": "(<" + rootAToken + ">)", "Timeout": "Second-600"})
	if rec.Code != http.StatusForbidden {
		t.Fatalf("refresh root A token under root B status = %d, want 403", rec.Code)
	}
	record, ok := f.service.lockNS.owner(rootBToken, time.Now())
	if !ok {
		t.Fatal("root B lock owner record missing")
	}
	for _, condition := range []string{
		"(<" + rootAToken + ">)",
		"(<" + record.innerToken + ">)",
		"(Not <" + record.innerToken + ">)",
	} {
		rec = f.request(t, "PUT", "/dav/photos/a.txt", f.memberName, f.memberPass,
			strings.NewReader("must not replace locked file"), map[string]string{"If": condition})
		if rec.Code != http.StatusPreconditionFailed {
			t.Errorf("PUT with foreign/raw/negated lock token %q status = %d, want 412", condition, rec.Code)
		}
		if got, err := os.ReadFile(filepath.Join(secondRoot, "photos", "a.txt")); err != nil || string(got) != "second root" {
			t.Fatalf("failed lock-token PUT changed root B file to %q: %v", got, err)
		}
	}
	rec = f.request(t, "UNLOCK", "/dav/photos/a.txt", f.memberName, f.memberPass, nil,
		map[string]string{"Lock-Token": "<" + rootAToken + ">"})
	if rec.Code != http.StatusForbidden {
		t.Fatalf("UNLOCK root A token under root B status = %d, want 403", rec.Code)
	}

	currentRoot = f.root
	rootAReacquiredToken := lock()
	if rootAReacquiredToken == rootAToken {
		t.Fatal("switching back unexpectedly reused the discarded lock")
	}
	for _, token := range []string{rootAToken, rootBToken, rootAReacquiredToken} {
		rec = f.request(t, "UNLOCK", "/dav/photos/a.txt", f.memberName, f.memberPass, nil,
			map[string]string{"Lock-Token": "<" + token + ">"})
		if token == rootAReacquiredToken {
			if rec.Code != http.StatusNoContent && rec.Code != http.StatusOK {
				t.Fatalf("UNLOCK current root token status = %d", rec.Code)
			}
		} else if rec.Code != http.StatusForbidden {
			t.Fatalf("UNLOCK discarded root token %q status = %d, want 403", token, rec.Code)
		}
	}
}

func TestLockOwnerExpiresForZeroDuration(t *testing.T) {
	rootPath := t.TempDir()
	rootFile, err := openRootDirectory(rootPath)
	if err != nil {
		t.Fatal(err)
	}
	defer rootFile.Close()
	rootInfo, err := rootFile.Stat()
	if err != nil {
		t.Fatal(err)
	}
	namespace := &lockNamespace{inner: webdav.NewMemLS(), root: rootInfo, owners: map[string]lockOwner{}}
	state := &requestState{
		user:   auth.User{ID: 9},
		root:   &rootHandle{path: rootPath, file: rootFile, info: rootInfo},
		method: "LOCK",
	}
	lockSystem := &ownedLockSystem{
		inner:       namespace.inner,
		namespace:   namespace,
		state:       state,
		requestPath: "photos/a.txt",
	}
	now := time.Now()
	token, err := lockSystem.Create(now, webdav.LockDetails{
		Root:     "photos/a.txt",
		Duration: 0,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := namespace.owner(token, now); ok {
		t.Fatal("zero-duration lock owner remained active")
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

type interruptedReader struct {
	data []byte
	done bool
}

func (r *interruptedReader) Read(p []byte) (int, error) {
	if !r.done {
		r.done = true
		return copy(p, r.data), nil
	}
	return 0, errors.New("injected request-body failure")
}

func TestInterruptedPUTPreservesOldFileAndCleansStage(t *testing.T) {
	f, _ := newFixture(t)
	rec := f.request(t, "PUT", "/dav/photos/a.txt", f.memberName, f.memberPass,
		&interruptedReader{data: []byte("partial replacement")}, nil)
	if rec.Code == http.StatusCreated {
		t.Fatalf("interrupted PUT unexpectedly succeeded: %s", rec.Body.String())
	}
	contents, err := os.ReadFile(filepath.Join(f.root, "photos", "a.txt"))
	if err != nil || string(contents) != "in photos" {
		t.Fatalf("original changed after interrupted PUT: %q, %v", contents, err)
	}
	entries, err := os.ReadDir(filepath.Join(f.root, "photos"))
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".lightisle-dav-") {
			t.Errorf("interrupted PUT left a staged artifact %q", entry.Name())
		}
	}

	rec = f.request(t, "PUT", "/dav/photos/interrupted-new.txt", f.memberName, f.memberPass,
		&interruptedReader{data: []byte("partial new file")}, nil)
	if rec.Code == http.StatusCreated {
		t.Fatalf("interrupted new-file PUT unexpectedly succeeded")
	}
	if _, err := os.Stat(filepath.Join(f.root, "photos", "interrupted-new.txt")); !os.IsNotExist(err) {
		t.Errorf("interrupted PUT left a new partial target: %v", err)
	}
}

func TestPUTPublishesCompleteOverwrite(t *testing.T) {
	f, _ := newFixture(t)
	rec := f.request(t, "PUT", "/dav/photos/a.txt", f.memberName, f.memberPass,
		strings.NewReader("complete replacement"), nil)
	if rec.Code != http.StatusCreated {
		t.Fatalf("complete overwrite status = %d: %s", rec.Code, rec.Body.String())
	}
	contents, err := os.ReadFile(filepath.Join(f.root, "photos", "a.txt"))
	if err != nil || string(contents) != "complete replacement" {
		t.Fatalf("overwrite contents = %q, %v", contents, err)
	}
}

func TestCopyPublishesEveryCompletedFileInDirectory(t *testing.T) {
	f, _ := newFixture(t)
	source := filepath.Join(f.root, "photos", "source")
	if err := os.Mkdir(source, 0700); err != nil {
		t.Fatal(err)
	}
	for name, contents := range map[string]string{"one.txt": "first", "two.txt": "second"} {
		if err := os.WriteFile(filepath.Join(source, name), []byte(contents), 0600); err != nil {
			t.Fatal(err)
		}
	}
	rec := f.request(t, "COPY", "/dav/photos/source", f.memberName, f.memberPass, nil,
		map[string]string{"Destination": "/dav/photos/copied", "Depth": "infinity"})
	if rec.Code != http.StatusCreated {
		t.Fatalf("COPY directory status = %d: %s", rec.Code, rec.Body.String())
	}
	for name, want := range map[string]string{"one.txt": "first", "two.txt": "second"} {
		got, err := os.ReadFile(filepath.Join(f.root, "photos", "copied", name))
		if err != nil || string(got) != want {
			t.Errorf("copied %s = %q, %v", name, got, err)
		}
	}
}

func TestMoveFileWithinGrant(t *testing.T) {
	f, _ := newFixture(t)
	rec := f.request(t, "MOVE", "/dav/photos/a.txt", f.memberName, f.memberPass, nil,
		map[string]string{"Destination": "/dav/photos/moved.txt"})
	if rec.Code != http.StatusCreated && rec.Code != http.StatusNoContent {
		t.Fatalf("MOVE status = %d: %s", rec.Code, rec.Body.String())
	}
	if _, err := os.Stat(filepath.Join(f.root, "photos", "a.txt")); !os.IsNotExist(err) {
		t.Fatalf("MOVE left source in place: %v", err)
	}
	contents, err := os.ReadFile(filepath.Join(f.root, "photos", "moved.txt"))
	if err != nil || string(contents) != "in photos" {
		t.Fatalf("MOVE destination = %q, %v", contents, err)
	}
}

func TestDeleteDirectoryMovesWholeTreeToTrash(t *testing.T) {
	f, _ := newFixture(t)
	directory := filepath.Join(f.root, "photos", "folder")
	if err := os.Mkdir(directory, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "inside.txt"), []byte("inside"), 0600); err != nil {
		t.Fatal(err)
	}
	rec := f.request(t, "DELETE", "/dav/photos/folder", f.memberName, f.memberPass, nil, nil)
	if rec.Code != http.StatusNoContent && rec.Code != http.StatusOK {
		t.Fatalf("DELETE directory status = %d: %s", rec.Code, rec.Body.String())
	}
	if _, err := os.Stat(directory); !os.IsNotExist(err) {
		t.Fatalf("directory remained after DELETE: %v", err)
	}
	if len(f.trashed) == 0 || f.trashed[len(f.trashed)-1] != "photos/folder" {
		t.Fatalf("directory trash callback = %v", f.trashed)
	}
}

func TestCopyOverwriteMovesPreviousTargetToTrash(t *testing.T) {
	f, _ := newFixture(t)
	if err := os.WriteFile(filepath.Join(f.root, "photos", "source.txt"), []byte("new copy"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(f.root, "photos", "target.txt"), []byte("old target"), 0600); err != nil {
		t.Fatal(err)
	}
	rec := f.request(t, "COPY", "/dav/photos/source.txt", f.memberName, f.memberPass, nil,
		map[string]string{"Destination": "/dav/photos/target.txt", "Overwrite": "T"})
	if rec.Code != http.StatusNoContent {
		t.Fatalf("COPY overwrite status = %d: %s", rec.Code, rec.Body.String())
	}
	contents, err := os.ReadFile(filepath.Join(f.root, "photos", "target.txt"))
	if err != nil || string(contents) != "new copy" {
		t.Fatalf("COPY overwrite result = %q, %v", contents, err)
	}
	if len(f.trashed) == 0 || f.trashed[len(f.trashed)-1] != "photos/target.txt" {
		t.Fatalf("overwritten target was not sent to trash: %v", f.trashed)
	}
}

func TestCopySourceReadFailureNeverPublishesPartialTarget(t *testing.T) {
	f, _ := newFixture(t)
	user, err := f.service.store.VerifyDAVCredential(f.memberName, f.memberPass)
	if err != nil {
		t.Fatal(err)
	}
	rootFile, err := openRootDirectory(f.root)
	if err != nil {
		t.Fatal(err)
	}
	rootInfo, err := rootFile.Stat()
	if err != nil {
		rootFile.Close()
		t.Fatal(err)
	}
	root := &rootHandle{path: f.root, file: rootFile, info: rootInfo}
	defer root.close()
	state := &requestState{
		service: f.service,
		user:    user,
		root:    root,
		method:  "COPY",
		body:    &trackedBody{body: http.NoBody},
	}
	ctx := context.WithValue(context.Background(), requestStateKey{}, state)
	file, err := (&grantedFS{service: f.service}).OpenFile(ctx, "photos/partial-copy.txt",
		os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.Write([]byte("partial source bytes")); err != nil {
		t.Fatal(err)
	}
	state.noteCopyRead(errors.New("injected source read failure"))
	if err := file.Close(); err == nil {
		t.Fatal("COPY transaction committed after source read failure")
	}
	if _, err := os.Stat(filepath.Join(f.root, "photos", "partial-copy.txt")); !os.IsNotExist(err) {
		t.Errorf("failed COPY left a partial destination: %v", err)
	}
	entries, err := os.ReadDir(filepath.Join(f.root, "photos"))
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".lightisle-dav-") {
			t.Errorf("failed COPY left a staging artifact %q", entry.Name())
		}
	}
}

func TestFailedCopyCleansCreatedDirectoryAfterChild(t *testing.T) {
	f, _ := newFixture(t)
	if err := os.WriteFile(filepath.Join(f.root, "photos", "copy-source.txt"), []byte("copied"), 0600); err != nil {
		t.Fatal(err)
	}
	user, err := f.service.store.VerifyDAVCredential(f.memberName, f.memberPass)
	if err != nil {
		t.Fatal(err)
	}
	rootFile, err := openRootDirectory(f.root)
	if err != nil {
		t.Fatal(err)
	}
	rootInfo, err := rootFile.Stat()
	if err != nil {
		rootFile.Close()
		t.Fatal(err)
	}
	root := &rootHandle{path: f.root, file: rootFile, info: rootInfo}
	defer root.close()
	state := &requestState{
		service: f.service,
		user:    user,
		root:    root,
		method:  "COPY",
		body:    &trackedBody{body: http.NoBody},
	}
	ctx := context.WithValue(context.Background(), requestStateKey{}, state)
	fs := &grantedFS{service: f.service}
	if err := fs.Mkdir(ctx, "photos/partial-copy", 0700); err != nil {
		t.Fatal(err)
	}
	source, err := fs.OpenFile(ctx, "photos/copy-source.txt", os.O_RDONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	target, err := fs.OpenFile(ctx, "photos/partial-copy/copied.txt",
		os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		source.Close()
		t.Fatal(err)
	}
	if _, err := io.Copy(target, source); err != nil {
		t.Fatal(err)
	}
	if err := source.Close(); err != nil {
		t.Fatal(err)
	}
	if err := target.Close(); err != nil {
		t.Fatal(err)
	}
	state.noteCopyRead(errors.New("injected later COPY failure"))
	state.cleanupCreated()
	if _, err := os.Stat(filepath.Join(f.root, "photos", "partial-copy")); !os.IsNotExist(err) {
		t.Fatalf("failed COPY left its empty destination directory: %v", err)
	}
}

func newPUTWriteTxn(t *testing.T, f *fixture) *writeTxn {
	t.Helper()
	user, err := f.service.store.VerifyDAVCredential(f.memberName, f.memberPass)
	if err != nil {
		t.Fatal(err)
	}
	rootFile, err := openRootDirectory(f.root)
	if err != nil {
		t.Fatal(err)
	}
	rootInfo, err := rootFile.Stat()
	if err != nil {
		rootFile.Close()
		t.Fatal(err)
	}
	root := &rootHandle{path: f.root, file: rootFile, info: rootInfo}
	t.Cleanup(root.close)
	body := &trackedBody{body: http.NoBody, eof: true}
	state := &requestState{
		service: f.service,
		user:    user,
		root:    root,
		method:  http.MethodPut,
		body:    body,
	}
	ctx := context.WithValue(context.Background(), requestStateKey{}, state)
	file, err := (&grantedFS{service: f.service}).OpenFile(ctx, "photos/a.txt",
		os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		t.Fatal(err)
	}
	txn, ok := file.(*writeTxn)
	if !ok {
		t.Fatalf("OpenFile returned %T, want *writeTxn", file)
	}
	if _, err := txn.Write([]byte("new bytes")); err != nil {
		t.Fatal(err)
	}
	return txn
}

func TestPUTRollbackExchangeFailureRetainsOriginalStage(t *testing.T) {
	f, _ := newFixture(t)
	txn := newPUTWriteTxn(t, f)
	stageName := txn.stageName
	exchangeCalls := 0
	txn.exchangeAtFn = func(sourceName, destinationName string) error {
		exchangeCalls++
		if exchangeCalls == 2 {
			return errors.New("injected reverse exchange failure")
		}
		return exchangeAt(txn.parent, sourceName, txn.parent, destinationName)
	}
	syncCalls := 0
	txn.syncParentFn = func() error {
		syncCalls++
		if syncCalls == 1 {
			return errors.New("injected publish directory sync failure")
		}
		return nil
	}

	if err := txn.Close(); err == nil {
		t.Fatal("PUT committed after publish sync and rollback both failed")
	}
	if exchangeCalls != 2 {
		t.Fatalf("exchange calls = %d, want publish and failed rollback", exchangeCalls)
	}
	if got, err := os.ReadFile(filepath.Join(f.root, "photos", "a.txt")); err != nil || string(got) != "new bytes" {
		t.Errorf("published target = %q, %v; want complete replacement", got, err)
	}
	if got, err := os.ReadFile(filepath.Join(f.root, "photos", stageName)); err != nil || string(got) != "in photos" {
		t.Errorf("staging recovery copy = %q, %v; want original bytes preserved", got, err)
	}
}

func TestPUTCleanupSyncFailureKeepsPublishedReplacementSuccessful(t *testing.T) {
	f, _ := newFixture(t)
	txn := newPUTWriteTxn(t, f)
	stageName := txn.stageName
	syncCalls := 0
	txn.syncParentFn = func() error {
		syncCalls++
		if syncCalls == 2 {
			return errors.New("injected post-cleanup directory sync failure")
		}
		return nil
	}

	if err := txn.Close(); err != nil {
		t.Fatalf("published PUT reported cleanup sync failure: %v", err)
	}
	if got, err := os.ReadFile(filepath.Join(f.root, "photos", "a.txt")); err != nil || string(got) != "new bytes" {
		t.Errorf("published target = %q, %v; want complete replacement", got, err)
	}
	if _, err := os.Stat(filepath.Join(f.root, "photos", stageName)); !os.IsNotExist(err) {
		t.Errorf("prior-file staging entry remained after successful cleanup: %v", err)
	}
}

func TestMemberCannotFollowSymlinksAcrossGrantOrRoot(t *testing.T) {
	f, _ := newFixture(t)
	outside := t.TempDir()
	if err := os.WriteFile(filepath.Join(outside, "outside.txt"), []byte("outside secret"), 0600); err != nil {
		t.Fatal(err)
	}
	photos := filepath.Join(f.root, "photos")
	links := []struct {
		name   string
		target string
	}{
		{name: "private-link", target: filepath.Join("..", "private", "b.txt")},
		{name: "outside-link", target: filepath.Join(outside, "outside.txt")},
		{name: "private-dir", target: filepath.Join("..", "private")},
		{name: "outside-dir", target: outside},
	}
	for _, link := range links {
		if err := os.Symlink(link.target, filepath.Join(photos, link.name)); err != nil {
			t.Fatal(err)
		}
	}

	for _, target := range []string{"/dav/photos/private-link", "/dav/photos/outside-link"} {
		rec := f.request(t, "GET", target, f.memberName, f.memberPass, nil, nil)
		if rec.Code == http.StatusOK {
			t.Errorf("GET followed symlink %s", target)
		}
		rec = f.request(t, "PUT", target, f.memberName, f.memberPass, strings.NewReader("overwrite"), nil)
		if rec.Code == http.StatusCreated {
			t.Errorf("PUT followed symlink %s", target)
		}
	}
	for _, target := range []string{"/dav/photos/private-dir/b.txt", "/dav/photos/outside-dir/outside.txt"} {
		rec := f.request(t, "GET", target, f.memberName, f.memberPass, nil, nil)
		if rec.Code == http.StatusOK {
			t.Errorf("GET traversed symlink parent %s", target)
		}
		rec = f.request(t, "PUT", target, f.memberName, f.memberPass, strings.NewReader("overwrite"), nil)
		if rec.Code == http.StatusCreated {
			t.Errorf("PUT traversed symlink parent %s", target)
		}
	}

	for _, method := range []string{"PROPFIND", "DELETE", "MOVE", "COPY"} {
		target := "/dav/photos/private-link"
		headers := map[string]string{}
		if method == "MOVE" || method == "COPY" {
			headers["Destination"] = "/dav/photos/copied-link"
		}
		rec := f.request(t, method, target, f.memberName, f.memberPass, nil, headers)
		if rec.Code >= 200 && rec.Code < 300 {
			t.Errorf("%s unexpectedly accepted symlink target: %d", method, rec.Code)
		}
	}
	private, err := os.ReadFile(filepath.Join(f.root, "private", "b.txt"))
	if err != nil || string(private) != "secret" {
		t.Errorf("private target changed: %q, %v", private, err)
	}
	outsideContent, err := os.ReadFile(filepath.Join(outside, "outside.txt"))
	if err != nil || string(outsideContent) != "outside secret" {
		t.Errorf("outside target changed: %q, %v", outsideContent, err)
	}
	if _, err := os.Stat(filepath.Join(photos, "copied-link")); !os.IsNotExist(err) {
		t.Errorf("COPY/MOVE left an unauthorized result: %v", err)
	}
}

type gateReader struct {
	started chan struct{}
	resume  chan struct{}
	data    []byte
	read    bool
}

func (r *gateReader) Read(p []byte) (int, error) {
	if r.read {
		return 0, io.EOF
	}
	r.read = true
	close(r.started)
	<-r.resume
	return copy(p, r.data), nil
}

func TestDirectoryReplacementCannotRedirectPUT(t *testing.T) {
	f, _ := newFixture(t)
	outside := t.TempDir()
	if err := os.WriteFile(filepath.Join(outside, "sentinel.txt"), []byte("keep"), 0600); err != nil {
		t.Fatal(err)
	}
	reader := &gateReader{started: make(chan struct{}), resume: make(chan struct{}), data: []byte("do not publish")}
	finished := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		finished <- f.request(t, "PUT", "/dav/photos/raced.txt", f.memberName, f.memberPass, reader, nil)
	}()
	select {
	case <-reader.started:
	case <-time.After(5 * time.Second):
		t.Fatal("PUT did not reach its request body")
	}
	photos := filepath.Join(f.root, "photos")
	moved := filepath.Join(f.root, "photos-original")
	if err := os.Rename(photos, moved); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, photos); err != nil {
		t.Fatal(err)
	}
	close(reader.resume)
	var rec *httptest.ResponseRecorder
	select {
	case rec = <-finished:
	case <-time.After(5 * time.Second):
		t.Fatal("PUT did not finish after releasing its body")
	}
	if rec.Code == http.StatusCreated {
		t.Fatal("PUT succeeded after its authorized parent was replaced")
	}
	if _, err := os.Stat(filepath.Join(outside, "raced.txt")); !os.IsNotExist(err) {
		t.Errorf("directory replacement redirected PUT outside the share: %v", err)
	}
	if _, err := os.Stat(filepath.Join(moved, "raced.txt")); !os.IsNotExist(err) {
		t.Errorf("PUT published under a detached directory: %v", err)
	}
	entries, err := os.ReadDir(moved)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".lightisle-dav-") {
			t.Errorf("directory replacement left a staged artifact %q", entry.Name())
		}
	}
	if data, err := os.ReadFile(filepath.Join(outside, "sentinel.txt")); err != nil || string(data) != "keep" {
		t.Errorf("outside sentinel changed: %q, %v", data, err)
	}
}

func TestShareRootSwitchAbortsInFlightPUT(t *testing.T) {
	f, _ := newFixture(t)
	newRoot := t.TempDir()
	currentRoot := f.root
	f.service.root = func() (string, bool) { return currentRoot, true }
	reader := &gateReader{started: make(chan struct{}), resume: make(chan struct{}), data: []byte("must not publish")}
	finished := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		finished <- f.request(t, "PUT", "/dav/photos/root-switch.txt", f.memberName, f.memberPass, reader, nil)
	}()
	select {
	case <-reader.started:
	case <-time.After(5 * time.Second):
		t.Fatal("PUT did not reach its request body")
	}
	currentRoot = newRoot
	close(reader.resume)
	var rec *httptest.ResponseRecorder
	select {
	case rec = <-finished:
	case <-time.After(5 * time.Second):
		t.Fatal("PUT did not finish after the root changed")
	}
	if rec.Code == http.StatusCreated {
		t.Fatal("PUT published after the configured share root changed")
	}
	for _, target := range []string{
		filepath.Join(f.root, "photos", "root-switch.txt"),
		filepath.Join(newRoot, "photos", "root-switch.txt"),
	} {
		if _, err := os.Stat(target); !os.IsNotExist(err) {
			t.Errorf("root switch left a target at %s: %v", target, err)
		}
	}
}

func TestPUTConditionsAreCheckedBeforeAndDuringPublication(t *testing.T) {
	f, _ := newFixture(t)
	oldInfo, err := os.Stat(filepath.Join(f.root, "photos", "a.txt"))
	if err != nil {
		t.Fatal(err)
	}
	wrong := map[string]string{"If-Match": `"not-current"`}
	rec := f.request(t, "PUT", "/dav/photos/a.txt", f.memberName, f.memberPass, strings.NewReader("no"), wrong)
	if rec.Code != http.StatusPreconditionFailed {
		t.Fatalf("stale If-Match status = %d", rec.Code)
	}
	ifNone := map[string]string{"If-None-Match": "*"}
	rec = f.request(t, "PUT", "/dav/photos/a.txt", f.memberName, f.memberPass, strings.NewReader("no"), ifNone)
	if rec.Code != http.StatusPreconditionFailed {
		t.Fatalf("If-None-Match wildcard status = %d", rec.Code)
	}

	reader := &gateReader{started: make(chan struct{}), resume: make(chan struct{}), data: []byte("stale conditional body")}
	headers := map[string]string{"If-Match": davETag(oldInfo)}
	finished := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		finished <- f.request(t, "PUT", "/dav/photos/a.txt", f.memberName, f.memberPass, reader, headers)
	}()
	select {
	case <-reader.started:
	case <-time.After(5 * time.Second):
		t.Fatal("conditional PUT did not reach its body")
	}
	if err := os.WriteFile(filepath.Join(f.root, "photos", "a.txt"), []byte("external update"), 0600); err != nil {
		t.Fatal(err)
	}
	close(reader.resume)
	select {
	case rec = <-finished:
	case <-time.After(5 * time.Second):
		t.Fatal("conditional PUT did not finish")
	}
	if rec.Code != http.StatusPreconditionFailed {
		t.Fatalf("If-Match changed during upload status = %d", rec.Code)
	}
	contents, err := os.ReadFile(filepath.Join(f.root, "photos", "a.txt"))
	if err != nil || string(contents) != "external update" {
		t.Fatalf("conditional PUT overwrote changed target: %q, %v", contents, err)
	}
}

func TestReadOnlyGrantCannotLockAndLockOwnerPathIsEnforced(t *testing.T) {
	f, _ := newFixture(t)
	adminSession, err := f.service.store.Login("boss", "correct-horse-1")
	if err != nil {
		t.Fatal(err)
	}
	users, err := f.service.store.ListUsers(adminSession)
	if err != nil {
		t.Fatal(err)
	}
	var memberID int64
	for _, user := range users {
		if user.Username == "leo" {
			memberID = user.ID
		}
	}
	if memberID == 0 {
		t.Fatal("member not found")
	}
	if err := f.service.store.SetFileGrant(adminSession, memberID, "photos", false); err != nil {
		t.Fatal(err)
	}
	lockBody := `<?xml version="1.0"?><d:lockinfo xmlns:d="DAV:"><d:lockscope><d:exclusive/></d:lockscope><d:locktype><d:write/></d:locktype><d:owner>qa</d:owner></d:lockinfo>`
	rec := f.request(t, "LOCK", "/dav/photos/a.txt", f.memberName, f.memberPass,
		strings.NewReader(lockBody), map[string]string{"Timeout": "Second-600"})
	if rec.Code != http.StatusForbidden {
		t.Fatalf("read-only grant LOCK status = %d", rec.Code)
	}
	if err := f.service.store.SetFileGrant(adminSession, memberID, "photos", true); err != nil {
		t.Fatal(err)
	}
	rec = f.request(t, "LOCK", "/dav/photos/a.txt", f.memberName, f.memberPass,
		strings.NewReader(lockBody), map[string]string{"Timeout": "Second-600"})
	if rec.Code != http.StatusOK {
		t.Fatalf("writable member LOCK status = %d: %s", rec.Code, rec.Body.String())
	}
	token := rec.Header().Get("Lock-Token")
	if token == "" {
		t.Fatal("LOCK response missing token")
	}
	if err := os.WriteFile(filepath.Join(f.root, "photos", "other.txt"), []byte("other"), 0600); err != nil {
		t.Fatal(err)
	}
	rec = f.request(t, "UNLOCK", "/dav/photos/other.txt", f.memberName, f.memberPass, nil,
		map[string]string{"Lock-Token": token})
	if rec.Code != http.StatusForbidden {
		t.Fatalf("wrong-path UNLOCK status = %d", rec.Code)
	}
	rec = f.request(t, "UNLOCK", "/dav/photos/a.txt", f.adminName, f.adminPassword, nil,
		map[string]string{"Lock-Token": token})
	if rec.Code != http.StatusForbidden {
		t.Fatalf("other-account UNLOCK status = %d", rec.Code)
	}
	rec = f.request(t, "LOCK", "/dav/photos/a.txt", f.adminName, f.adminPassword, nil,
		map[string]string{"If": "(<" + strings.Trim(token, "<>") + ">)", "Timeout": "Second-600"})
	if rec.Code != http.StatusForbidden {
		t.Fatalf("other-account lock refresh status = %d", rec.Code)
	}
	rec = f.request(t, "UNLOCK", "/dav/photos/a.txt", f.memberName, f.memberPass, nil,
		map[string]string{"Lock-Token": token})
	if rec.Code != http.StatusNoContent && rec.Code != http.StatusOK {
		t.Fatalf("owner UNLOCK status = %d", rec.Code)
	}
}
