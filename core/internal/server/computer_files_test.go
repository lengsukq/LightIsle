package server

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
)

type computerTest struct {
	store         *auth.Store
	handler       http.Handler
	admin, member *http.Cookie
	memberID      int64
	root          string
}

func newComputerTest(t *testing.T) computerTest {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	store, err := auth.Open(filepath.Join(root, "data", "accounts.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.Close() })
	if err = store.Setup("owner", "owner-password-12345"); err != nil {
		t.Fatal(err)
	}
	adminToken, err := store.Login("owner", "owner-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	user, err := store.CreateUser(adminToken, "member", "member-password-12345", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	memberToken, err := store.Login("member", "member-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	return computerTest{store: store, handler: New("", store, nil), admin: &http.Cookie{Name: sessionCookie, Value: adminToken}, member: &http.Cookie{Name: sessionCookie, Value: memberToken}, memberID: user.ID, root: root}
}
func (f computerTest) call(method, path, body string, cookie *http.Cookie) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	r.Header.Set("X-LightIsle-Request", "1")
	if cookie != nil {
		r.AddCookie(cookie)
	}
	w := httptest.NewRecorder()
	f.handler.ServeHTTP(w, r)
	return w
}
func TestComputerFilesSwitchAndGrantRevocation(t *testing.T) {
	f := newComputerTest(t)
	file := filepath.Join(f.root, "note.txt")
	if err := os.WriteFile(file, []byte("hello"), 0600); err != nil {
		t.Fatal(err)
	}
	endpoint := "/api/v2/computer-files/content?path=" + url.QueryEscape(file)
	if w := f.call("GET", endpoint, "", f.admin); w.Code != 403 {
		t.Fatalf("default enabled: %d", w.Code)
	}
	if w := f.call("PUT", "/api/v2/computer-files/status", `{"enabled":true}`, f.admin); w.Code != 405 {
		t.Fatalf("HTTP enabled feature: %d", w.Code)
	}
	if err := f.store.SetComputerFilesEnabled(true); err != nil {
		t.Fatal(err)
	}
	if w := f.call("GET", endpoint, "", f.admin); w.Code != 200 || w.Body.String() != "hello" {
		t.Fatalf("admin read: %d %q", w.Code, w.Body.String())
	}
	if w := f.call("GET", endpoint, "", f.member); w.Code != 403 {
		t.Fatalf("ungranted read: %d", w.Code)
	}
	grantPath := "/api/v2/computer-files/grants/" + jsonNumber(f.memberID)
	if w := f.call("PUT", grantPath, `{"mode":"all","paths":[]}`, f.member); w.Code != 403 {
		t.Fatalf("member granted access: %d", w.Code)
	}
	if w := f.call("PUT", grantPath, `{"mode":"all","paths":[]}`, f.admin); w.Code != 200 {
		t.Fatalf("grant: %d %s", w.Code, w.Body.String())
	}
	if w := f.call("GET", endpoint, "", f.member); w.Code != 200 || w.Body.String() != "hello" {
		t.Fatalf("member read: %d %q", w.Code, w.Body.String())
	}
	api := &API{auth: f.store}
	req := httptest.NewRequest("GET", endpoint, nil)
	req.AddCookie(f.member)
	opened, access, err := api.openComputerFile(req, file)
	if err != nil {
		t.Fatal(err)
	}
	defer opened.Close()
	reader := computerReader{f: opened, access: access}
	if w := f.call("PUT", grantPath, `{"mode":"none","paths":[]}`, f.admin); w.Code != 200 {
		t.Fatalf("revoke: %d", w.Code)
	}
	if w := f.call("PUT", grantPath, `{"mode":"all","paths":[]}`, f.admin); w.Code != 200 {
		t.Fatalf("regrant: %d", w.Code)
	}
	if _, err := reader.Read(make([]byte, 1)); err == nil {
		t.Fatal("old reader survived revoke and regrant")
	}
	if err := f.store.SetComputerFilesEnabled(false); err != nil {
		t.Fatal(err)
	}
	if w := f.call("GET", endpoint, "", f.admin); w.Code != 403 {
		t.Fatalf("admin read while disabled: %d", w.Code)
	}
	if err := f.store.SetComputerFilesEnabled(true); err != nil {
		t.Fatal(err)
	}
	if w := f.call("GET", endpoint, "", f.member); w.Code != 200 {
		t.Fatalf("grant not restored: %d", w.Code)
	}
}
func jsonNumber(n int64) string { data, _ := json.Marshal(n); return string(data) }

func TestComputerFilesRejectLinksAndArchive(t *testing.T) {
	f := newComputerTest(t)
	if err := f.store.SetComputerFilesEnabled(true); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(f.root, "folder")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "note.txt"), []byte("hello"), 0600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link")
	if err := os.Symlink("note.txt", link); err != nil {
		t.Fatal(err)
	}
	endpoint := "/api/v2/computer-files/content?path=" + url.QueryEscape(link)
	if w := f.call("GET", endpoint, "", f.admin); w.Code == 200 {
		t.Fatal("followed symlink")
	}
	archive := "/api/v2/computer-files/archive?path=" + url.QueryEscape(dir)
	if w := f.call("GET", archive, "", f.admin); w.Code == 200 {
		t.Fatal("archive silently omitted symlink")
	}
	if err := os.Remove(link); err != nil {
		t.Fatal(err)
	}
	w := f.call("GET", archive, "", f.admin)
	if w.Code != 200 {
		t.Fatalf("archive: %d %s", w.Code, w.Body.String())
	}
	z, err := zip.NewReader(bytes.NewReader(w.Body.Bytes()), int64(w.Body.Len()))
	if err != nil {
		t.Fatal(err)
	}
	if len(z.File) != 2 || z.File[1].Name != "folder/note.txt" {
		t.Fatalf("archive entries: %#v", z.File)
	}
	r, err := z.File[1].Open()
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	contents, err := io.ReadAll(r)
	if err != nil || string(contents) != "hello" {
		t.Fatalf("archive content: %q %v", contents, err)
	}
}

func TestComputerFilesSelectedFolderIdentity(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("stable volume identity requires macOS")
	}
	f := newComputerTest(t)
	if err := f.store.SetComputerFilesEnabled(true); err != nil {
		t.Fatal(err)
	}
	folder := filepath.Join(f.root, "selected")
	if err := os.Mkdir(folder, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(folder, "allowed.txt"), []byte("allowed"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(f.root, "outside.txt"), []byte("private"), 0600); err != nil {
		t.Fatal(err)
	}
	body, _ := json.Marshal(map[string]any{"mode": "folders", "paths": []string{folder}})
	grant := "/api/v2/computer-files/grants/" + jsonNumber(f.memberID)
	w := f.call("PUT", grant, string(body), f.admin)
	if w.Code != 200 {
		t.Fatalf("directory grant: %d %s", w.Code, w.Body.String())
	}
	content := func(p string) string { return "/api/v2/computer-files/content?path=" + url.QueryEscape(p) }
	if w = f.call("GET", content(filepath.Join(folder, "allowed.txt")), "", f.member); w.Code != 200 || w.Body.String() != "allowed" {
		t.Fatalf("allowed: %d %s", w.Code, w.Body.String())
	}
	if w = f.call("GET", content(filepath.Join(f.root, "outside.txt")), "", f.member); w.Code != 403 {
		t.Fatalf("outside: %d", w.Code)
	}
	if err := os.Rename(folder, folder+"-old"); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(folder, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(folder, "allowed.txt"), []byte("replacement"), 0600); err != nil {
		t.Fatal(err)
	}
	if w = f.call("GET", content(filepath.Join(folder, "allowed.txt")), "", f.member); w.Code != 409 {
		t.Fatalf("replaced directory inherited grant: %d %s", w.Code, w.Body.String())
	}
}

func TestComputerFilesRangeAndSwitchGeneration(t *testing.T) {
	f := newComputerTest(t)
	file := filepath.Join(f.root, "range.txt")
	if err := os.WriteFile(file, []byte("0123456789"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := f.store.SetComputerFilesEnabled(true); err != nil {
		t.Fatal(err)
	}
	endpoint := "/api/v2/computer-files/content?path=" + url.QueryEscape(file)
	r := httptest.NewRequest("GET", endpoint, nil)
	r.AddCookie(f.admin)
	r.Header.Set("Range", "bytes=2-4")
	w := httptest.NewRecorder()
	f.handler.ServeHTTP(w, r)
	if w.Code != http.StatusPartialContent || w.Body.String() != "234" {
		t.Fatalf("range: %d %q", w.Code, w.Body.String())
	}
	api := &API{auth: f.store}
	opened, access, err := api.openComputerFile(r, file)
	if err != nil {
		t.Fatal(err)
	}
	defer opened.Close()
	if err := f.store.SetComputerFilesEnabled(false); err != nil {
		t.Fatal(err)
	}
	if err := f.store.SetComputerFilesEnabled(true); err != nil {
		t.Fatal(err)
	}
	if _, err := (computerReader{f: opened, access: access}).Read(make([]byte, 1)); err == nil {
		t.Fatal("old reader survived disable and re-enable")
	}
	if w := f.call("GET", "/api/v2/computer-files/content?path="+url.QueryEscape(f.root+"/../outside"), "", f.admin); w.Code != 400 {
		t.Fatalf("traversal: %d", w.Code)
	}
	if w := f.call("PUT", endpoint, "bad", f.admin); w.Code != 405 {
		t.Fatalf("write endpoint exists: %d", w.Code)
	}
	// Protected LightIsle dataDir and SSH key directories must remain blocked even when enabled.
	sshDir := filepath.Join(f.root, ".ssh")
	if err := os.MkdirAll(sshDir, 0700); err != nil {
		t.Fatal(err)
	}
	sshKey := filepath.Join(sshDir, "id_ed25519")
	if err := os.WriteFile(sshKey, []byte("private"), 0600); err != nil {
		t.Fatal(err)
	}
	if w := f.call("GET", "/api/v2/computer-files/content?path="+url.QueryEscape(sshKey), "", f.admin); w.Code != http.StatusForbidden {
		t.Fatalf("ssh key exposed over computer-files: %d", w.Code)
	}
	dbFile := filepath.Join(f.root, "data", "accounts.db")
	if w := f.call("GET", "/api/v2/computer-files/content?path="+url.QueryEscape(dbFile), "", f.admin); w.Code != http.StatusForbidden {
		t.Fatalf("accounts.db exposed over computer-files: %d", w.Code)
	}
}
