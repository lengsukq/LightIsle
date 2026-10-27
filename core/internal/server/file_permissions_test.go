package server

import (
	"bytes"
	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"testing"
)

func TestMemberGrantsAreEnforced(t *testing.T) {
	dir := t.TempDir()
	accounts, e := auth.Open(filepath.Join(dir, "accounts.sqlite"))
	if e != nil {
		t.Fatal(e)
	}
	defer accounts.Close()
	share, e := files.Open(filepath.Join(dir, "share"))
	if e != nil {
		t.Fatal(e)
	}
	defer share.Close()
	if e = accounts.Setup("owner", "secure-password-12345"); e != nil {
		t.Fatal(e)
	}
	for _, folder := range []string{"family", "private"} {
		if e = share.Mkdir(folder); e != nil {
			t.Fatal(e)
		}
	}
	for _, p := range []string{"family/photo.txt", "private/secret.txt"} {
		if _, e = share.Upload(p, bytes.NewBufferString("test")); e != nil {
			t.Fatal(e)
		}
	}
	admin, e := accounts.Login("owner", "secure-password-12345")
	if e != nil {
		t.Fatal(e)
	}
	member, e := accounts.CreateUser(admin, "child", "secure-password-23456", auth.RoleMember)
	if e != nil {
		t.Fatal(e)
	}
	guest, e := accounts.Login("child", "secure-password-23456")
	if e != nil {
		t.Fatal(e)
	}
	h := New("", accounts, share)
	call := func(method, url, body, token string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, url, bytes.NewBufferString(body))
		r.Header.Set("X-LightIsle-Request", "1")
		if token != "" {
			r.AddCookie(&http.Cookie{Name: sessionCookie, Value: token})
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	if w := call("GET", "/api/v2/files/content?path=private/secret.txt", "", guest); w.Code != 403 {
		t.Fatalf("member could read secret: %d", w.Code)
	}
	if w := call("GET", "/api/v2/cinema", "", guest); w.Code != 403 {
		t.Fatalf("member can browse cinema: %d", w.Code)
	}
	target := "/api/v2/users/" + strconv.FormatInt(member.ID, 10) + "/file-grants"
	if w := call("PUT", target, `{"path":"family","canWrite":false}`, admin); w.Code != 200 {
		t.Fatalf("grant %d %s", w.Code, w.Body.String())
	}
	if w := call("GET", "/api/v2/files?path=.", "", guest); w.Code != 200 || !bytes.Contains(w.Body.Bytes(), []byte("family")) || bytes.Contains(w.Body.Bytes(), []byte("private")) {
		t.Fatalf("root filtering %d %s", w.Code, w.Body.String())
	}
	if w := call("GET", "/api/v2/files/content?path=family/photo.txt", "", guest); w.Code != 200 {
		t.Fatalf("read grant %d", w.Code)
	}
	if w := call("DELETE", "/api/v2/files?path=family/photo.txt", "", guest); w.Code != 403 {
		t.Fatalf("read-only deletion %d", w.Code)
	}
	if w := call("GET", "/api/v2/files/search?query=secret", "", guest); w.Code != 200 || bytes.Contains(w.Body.Bytes(), []byte("secret.txt")) {
		t.Fatalf("search leak %d %s", w.Code, w.Body.String())
	}
	if w := call("PUT", target, `{"path":"family","canWrite":true}`, admin); w.Code != 200 {
		t.Fatalf("write grant %d", w.Code)
	}
	if w := call("POST", "/api/v2/files/folders", `{"path":"family/new"}`, guest); w.Code != 201 {
		t.Fatalf("write grant failed %d", w.Code)
	}
	if w := call("DELETE", target+"?path=family", "", admin); w.Code != 200 {
		t.Fatalf("revoke %d", w.Code)
	}
	if w := call("GET", "/api/v2/files/content?path=family/photo.txt", "", guest); w.Code != 403 {
		t.Fatalf("revocation failed %d", w.Code)
	}
	if w := call("PUT", target, `{"path":"../private","canWrite":true}`, admin); w.Code == 200 {
		t.Fatal("unsafe grant accepted")
	}
}
