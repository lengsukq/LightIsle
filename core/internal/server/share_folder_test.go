package server

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
)

type folderShareFixture struct {
	t        *testing.T
	handler  http.Handler
	accounts *auth.Store
	store    files.Access
	admin    *http.Cookie
}

func newFolderShareFixture(t *testing.T) *folderShareFixture {
	t.Helper()
	dir := t.TempDir()
	accounts, err := auth.Open(filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { accounts.Close() })
	if err := accounts.Setup("owner", "owner-password-12345"); err != nil {
		t.Fatal(err)
	}
	store, err := files.Open(filepath.Join(dir, "SharedFiles"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.Close() })
	f := &folderShareFixture{t: t, handler: New("", accounts, store), accounts: accounts, store: store}
	f.admin = f.login("owner", "owner-password-12345")
	return f
}

func (f *folderShareFixture) login(username, password string) *http.Cookie {
	f.t.Helper()
	request := httptest.NewRequest(http.MethodPost, "/api/v2/auth/login",
		strings.NewReader(`{"username":"`+username+`","password":"`+password+`"}`))
	request.RemoteAddr = "192.168.1.4:1000"
	request.Header.Set("X-LightIsle-Request", "1")
	response := httptest.NewRecorder()
	f.handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		f.t.Fatalf("login %s: %d %s", username, response.Code, response.Body.String())
	}
	for _, cookie := range response.Result().Cookies() {
		if cookie.Name == sessionCookie {
			return cookie
		}
	}
	f.t.Fatal("login did not set a session cookie")
	return nil
}

func (f *folderShareFixture) call(method, url, body string, cookie *http.Cookie) *httptest.ResponseRecorder {
	f.t.Helper()
	request := httptest.NewRequest(method, url, strings.NewReader(body))
	request.RemoteAddr = "192.168.1.4:1000"
	if method != http.MethodGet && method != http.MethodHead {
		request.Header.Set("X-LightIsle-Request", "1")
	}
	if cookie != nil {
		request.AddCookie(cookie)
	}
	response := httptest.NewRecorder()
	f.handler.ServeHTTP(response, request)
	return response
}

func (f *folderShareFixture) seedAlbum() {
	f.t.Helper()
	for _, dir := range []string{"album", "album/inner"} {
		if err := f.store.Mkdir(dir); err != nil {
			f.t.Fatal(err)
		}
	}
	for path, content := range map[string]string{
		"album/one.txt":     "first",
		"album/two.txt":     "second",
		"album/inner/3.txt": "third",
	} {
		if _, err := f.store.Upload(path, strings.NewReader(content)); err != nil {
			f.t.Fatal(err)
		}
	}
}

// createFolderShare publishes a link through the real HTTP endpoint.
func (f *folderShareFixture) createFolderShare(cookie *http.Cookie, path, extra string) string {
	f.t.Helper()
	payload := `{"path":"` + path + `","hours":2` + extra + `}`
	response := f.call(http.MethodPost, "/api/v2/file-shares", payload, cookie)
	if response.Code != http.StatusCreated {
		f.t.Fatalf("create share %s: %d %s", path, response.Code, response.Body.String())
	}
	var created struct {
		Share struct {
			Kind string `json:"kind"`
		} `json:"share"`
		Token string `json:"token"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &created); err != nil || created.Token == "" {
		f.t.Fatalf("share response: %v %s", err, response.Body.String())
	}
	if created.Share.Kind != auth.ShareKindDir {
		f.t.Fatalf("folder share kind = %q, want dir", created.Share.Kind)
	}
	return created.Token
}

func zipNames(t *testing.T, body []byte) map[string]string {
	t.Helper()
	reader, err := zip.NewReader(bytes.NewReader(body), int64(len(body)))
	if err != nil {
		t.Fatalf("public folder response is not a zip: %v", err)
	}
	names := map[string]string{}
	for _, file := range reader.File {
		if file.FileInfo().IsDir() {
			names[file.Name] = ""
			continue
		}
		rc, err := file.Open()
		if err != nil {
			t.Fatalf("zip entry %s: %v", file.Name, err)
		}
		content, err := io.ReadAll(rc)
		rc.Close()
		if err != nil {
			t.Fatalf("zip entry %s: %v", file.Name, err)
		}
		names[file.Name] = string(content)
	}
	return names
}

func TestPublicFolderShareStreamsZip(t *testing.T) {
	f := newFolderShareFixture(t)
	f.seedAlbum()
	token := f.createFolderShare(f.admin, "album", "")

	link := "/api/v2/public/file/" + token
	if head := f.call(http.MethodHead, link, "", nil); head.Code != http.StatusOK {
		t.Fatalf("HEAD folder link: %d %s", head.Code, head.Body.String())
	}
	download := f.call(http.MethodGet, link, "", nil)
	if download.Code != http.StatusOK {
		t.Fatalf("GET folder link: %d %s", download.Code, download.Body.String())
	}
	if got := download.Header().Get("Content-Type"); got != "application/zip" {
		t.Fatalf("content type = %q", got)
	}
	if got := download.Header().Get("Content-Disposition"); !strings.Contains(got, "album.zip") {
		t.Fatalf("disposition = %q", got)
	}
	names := zipNames(t, download.Body.Bytes())
	for name, want := range map[string]string{
		"album/":            "",
		"album/one.txt":     "first",
		"album/two.txt":     "second",
		"album/inner/":      "",
		"album/inner/3.txt": "third",
	} {
		if names[name] != want {
			t.Fatalf("zip entry %q = %q, want %q; all=%v", name, names[name], want, names)
		}
	}

	listed := f.call(http.MethodGet, "/api/v2/file-shares", "", f.admin)
	if listed.Code != http.StatusOK || !strings.Contains(listed.Body.String(), `"kind":"dir"`) {
		t.Fatalf("share list missing dir kind: %d %s", listed.Code, listed.Body.String())
	}
}

func TestPublicFolderShareQuotaExhaustion(t *testing.T) {
	f := newFolderShareFixture(t)
	f.seedAlbum()
	token := f.createFolderShare(f.admin, "album", `,"maxDownloads":1`)
	link := "/api/v2/public/file/" + token
	if first := f.call(http.MethodGet, link, "", nil); first.Code != http.StatusOK {
		t.Fatalf("first download: %d %s", first.Code, first.Body.String())
	}
	if second := f.call(http.MethodGet, link, "", nil); second.Code != http.StatusNotFound {
		t.Fatalf("exhausted folder link: %d", second.Code)
	}
}

func TestPublicFolderShareInvalidatedByReplacement(t *testing.T) {
	f := newFolderShareFixture(t)
	f.seedAlbum()
	token := f.createFolderShare(f.admin, "album", "")
	link := "/api/v2/public/file/" + token
	if err := f.store.MoveToTrash("album"); err != nil {
		t.Fatal(err)
	}
	if err := f.store.Mkdir("album"); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.Upload("album/other.txt", strings.NewReader("different")); err != nil {
		t.Fatal(err)
	}
	// The recreated folder is a different directory instance.
	if response := f.call(http.MethodGet, link, "", nil); response.Code != http.StatusNotFound {
		t.Fatalf("replaced folder still served: %d", response.Code)
	}
}

func TestPublicFolderShareDepthLimitIsHonest(t *testing.T) {
	f := newFolderShareFixture(t)
	deep := "nested"
	if err := f.store.Mkdir(deep); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < archiveMaxDepth+2; i++ {
		deep += "/d"
		if err := f.store.Mkdir(deep); err != nil {
			t.Fatal(err)
		}
	}
	token := f.createFolderShare(f.admin, "nested", "")
	if response := f.call(http.MethodGet, "/api/v2/public/file/"+token, "", nil); response.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("deep folder share: %d %s", response.Code, response.Body.String())
	}
}

func TestPublicFolderShareFollowsMemberGrants(t *testing.T) {
	f := newFolderShareFixture(t)
	f.seedAlbum()
	created := f.call(http.MethodPost, "/api/v2/users", `{"username":"member","password":"member-password-123"}`, f.admin)
	if created.Code != http.StatusCreated {
		t.Fatalf("add member: %d %s", created.Code, created.Body.String())
	}
	var member struct {
		ID int64 `json:"id"`
	}
	if err := json.Unmarshal(created.Body.Bytes(), &member); err != nil {
		t.Fatal(err)
	}
	memberCookie := f.login("member", "member-password-123")
	if denied := f.call(http.MethodPost, "/api/v2/file-shares", `{"path":"album","hours":1}`, memberCookie); denied.Code != http.StatusForbidden {
		t.Fatalf("ungranted member shared folder: %d %s", denied.Code, denied.Body.String())
	}
	adminToken := f.admin.Value
	if err := f.accounts.SetFileGrant(adminToken, member.ID, "album", false); err != nil {
		t.Fatal(err)
	}
	token := f.createFolderShare(memberCookie, "album", "")
	link := "/api/v2/public/file/" + token
	if served := f.call(http.MethodGet, link, "", nil); served.Code != http.StatusOK {
		t.Fatalf("granted member folder link: %d %s", served.Code, served.Body.String())
	}
	if err := f.accounts.RemoveFileGrant(adminToken, member.ID, "album"); err != nil {
		t.Fatal(err)
	}
	if revoked := f.call(http.MethodGet, link, "", nil); revoked.Code != http.StatusNotFound {
		t.Fatalf("revoked grant still serves folder: %d", revoked.Code)
	}
}
