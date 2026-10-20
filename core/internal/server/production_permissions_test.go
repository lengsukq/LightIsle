package server

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
)

// Regression for privilege escalation via symlinks entirely inside the same
// share, sensitive trash metadata, and grants revoked while a session exists.
func TestFileACLNoPrivateSymlinkSearchOrTrashDisclosure(t *testing.T) {
	dir := t.TempDir()
	accounts, err := auth.Open(filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	root := filepath.Join(dir, "shared")
	share, err := files.Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer share.Close()
	if err := accounts.Setup("owner", "unique-owner-password"); err != nil {
		t.Fatal(err)
	}
	admin, err := accounts.Login("owner", "unique-owner-password")
	if err != nil {
		t.Fatal(err)
	}
	child, err := accounts.CreateUser(admin, "member", "unique-member-password", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	token, err := accounts.Login("member", "unique-member-password")
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"shared", "secret"} {
		if err := share.Mkdir(name); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range []string{"shared/child.txt", "secret/private.txt"} {
		if _, err := share.Upload(name, bytes.NewReader([]byte("classified"))); err != nil {
			t.Fatal(err)
		}
	}
	// These aliases do not escape the share; os.Root alone cannot enforce
	// *user-specific* directory permissions.
	if err := os.Symlink("../secret", filepath.Join(root, "shared", "link")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../secret/private.txt", filepath.Join(root, "shared", "alias.txt")); err != nil {
		t.Fatal(err)
	}
	route := New("", accounts, share)
	call := func(method, url, body, authToken string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, url, bytes.NewBufferString(body))
		req.Header.Set("X-LightIsle-Request", "1")
		req.AddCookie(&http.Cookie{Name: sessionCookie, Value: authToken})
		resp := httptest.NewRecorder()
		route.ServeHTTP(resp, req)
		return resp
	}
	grantUrl := "/api/v1/users/" + strconv.FormatInt(child.ID, 10) + "/file-grants"
	if got := call("PUT", grantUrl, `{"path":"shared","canWrite":true}`, admin); got.Code != 200 {
		t.Fatalf("cannot grant shared directory: %d %s", got.Code, got.Body.String())
	}
	for _, request := range []struct{ method, url, body string }{
		{"GET", "/api/v1/files/content?path=shared/link/private.txt", ""},
		{"GET", "/api/v1/files/preview?path=shared/alias.txt", ""},
		{"GET", "/api/v1/files?path=shared/link", ""},
		{"POST", "/api/v1/files/folders", `{"path":"shared/link/new"}`},
		{"PUT", "/api/v1/files/content?path=shared/link/modified.txt", "payload"},
		{"POST", "/api/v1/files/operations", `{"action":"copy","from":"shared/alias.txt","to":"shared/copied.txt"}`},
	} {
		w := call(request.method, request.url, request.body, token)
		if w.Code >= 200 && w.Code < 300 {
			t.Errorf("ACL symlink traversal succeeded: %s %s (%d)", request.method, request.url, w.Code)
		}
	}
	search := call("GET", "/api/v1/files/search?path=.&query=private", "", token)
	if search.Code != 200 || bytes.Contains(search.Body.Bytes(), []byte("private.txt")) {
		t.Fatalf("search must never inspect unauthorized sibling: %d %s", search.Code, search.Body.String())
	}
	if err := share.MoveToTrash("secret/private.txt"); err != nil {
		t.Fatal(err)
	}
	if err := share.MoveToTrash("shared/child.txt"); err != nil {
		t.Fatal(err)
	}
	trash, err := share.TrashList()
	if err != nil {
		t.Fatal(err)
	}
	var own, other string
	for _, entry := range trash {
		if entry.OriginalPath == "shared/child.txt" {
			own = entry.ID
		}
		if entry.OriginalPath == "secret/private.txt" {
			other = entry.ID
		}
	}
	if own == "" || other == "" {
		t.Fatalf("missing fixtures: %+v", trash)
	}
	listing := call("GET", "/api/v1/files/trash", "", token)
	if listing.Code != 200 || !bytes.Contains(listing.Body.Bytes(), []byte("child.txt")) || bytes.Contains(listing.Body.Bytes(), []byte("private.txt")) {
		t.Fatalf("trash metadata leak: %d %s", listing.Code, listing.Body.String())
	}
	if w := call("POST", "/api/v1/files/trash/"+other+"/restore", "", token); w.Code != 403 {
		t.Fatalf("restored other member's private trash: %d", w.Code)
	}
	if w := call("POST", "/api/v1/files/trash/"+own+"/restore", "", token); w.Code != 200 {
		t.Fatalf("cannot restore own subtree trash: %d %s", w.Code, w.Body.String())
	}
	if err := accounts.SetEnabled(admin, child.ID, false); err != nil {
		t.Fatal(err)
	}
	if w := call("GET", "/api/v1/files/content?path=shared/child.txt", "", token); w.Code != 401 {
		t.Fatalf("disabled session still authorized: %d", w.Code)
	}
}
