package server

import (
	"bytes"
	"encoding/json"
	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
)

func TestAccountAndFilesAPI(t *testing.T) {
	dir := t.TempDir()
	accounts, err := auth.Open(filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	share, err := files.Open(filepath.Join(dir, "SharedFiles"))
	if err != nil {
		t.Fatal(err)
	}
	defer share.Close()
	handler := New("", accounts, share)
	call := func(method, url, body, remote string, cookie *http.Cookie, withHeader bool) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, url, bytes.NewReader([]byte(body)))
		if remote != "" {
			req.RemoteAddr = remote
		}
		if withHeader {
			req.Header.Set("X-LightIsle-Request", "1")
		}
		if cookie != nil {
			req.AddCookie(cookie)
		}
		out := httptest.NewRecorder()
		handler.ServeHTTP(out, req)
		return out
	}
	setup := `{"username":"owner","password":"long-initial-password"}`
	if out := call("POST", "/api/v1/auth/setup", setup, "192.168.1.4:1000", nil, true); out.Code != 405 {
		t.Fatalf("remote setup %d", out.Code)
	}
	if out := call("POST", "/api/v1/auth/setup", setup, "127.0.0.1:1000", nil, true); out.Code != 405 {
		t.Fatalf("initial setup %d %s", out.Code, out.Body.String())
	}
	if err := accounts.Setup("owner", "long-initial-password"); err != nil {
		t.Fatal(err)
	}
	if out := call("GET", "/api/v1/system", "", "", nil, false); out.Code != 401 {
		t.Fatalf("metrics open %d", out.Code)
	}
	if out := call("GET", "/api/v1/files?path=.", "", "", nil, false); out.Code != 401 {
		t.Fatalf("files open %d", out.Code)
	}
	login := call("POST", "/api/v1/auth/login", setup, "127.0.0.1:1000", nil, true)
	if login.Code != 200 || len(login.Result().Cookies()) == 0 {
		t.Fatalf("login %d %s", login.Code, login.Body.String())
	}
	session := login.Result().Cookies()[0]
	if !session.HttpOnly || session.SameSite != http.SameSiteStrictMode {
		t.Fatal("insecure cookie")
	}
	if out := call("GET", "/api/v1/system", "", "", session, false); out.Code != 200 {
		t.Fatalf("private metrics %d", out.Code)
	}
	if out := call("POST", "/api/v1/files/folders", `{"path":"Photos"}`, "", session, true); out.Code != 201 {
		t.Fatalf("mkdir %d: %s", out.Code, out.Body.String())
	}
	if out := call("PUT", "/api/v1/files/content?path=Photos/test.txt", "hello", "", session, true); out.Code != 201 {
		t.Fatalf("upload %d: %s", out.Code, out.Body.String())
	}
	if out := call("GET", "/api/v1/files?path=Photos", "", "", session, false); out.Code != 200 || !bytes.Contains(out.Body.Bytes(), []byte("test.txt")) {
		t.Fatalf("list %d %s", out.Code, out.Body.String())
	}
	if out := call("GET", "/api/v1/files/content?path=Photos/test.txt", "", "", session, false); out.Code != 200 || out.Body.String() != "hello" {
		t.Fatalf("download %d %s", out.Code, out.Body.String())
	}
	if out := call("GET", "/api/v1/files/preview?path=Photos/test.txt", "", "", nil, false); out.Code != 401 {
		t.Fatalf("unauthorized preview: %d", out.Code)
	}
	if out := call("GET", "/api/v1/files/preview?path=Photos/test.txt", "", "", session, false); out.Code != 200 || out.Body.String() != "hello" {
		t.Fatalf("text preview %d %s", out.Code, out.Body.String())
	}
	if out := call("PUT", "/api/v1/files/content?path=Photos/code.html", "<script>hi</script>", "", session, true); out.Code != 201 {
		t.Fatalf("test HTML upload: %d", out.Code)
	}
	if out := call("GET", "/api/v1/files/preview?path=Photos/code.html", "", "", session, false); out.Code != 415 {
		t.Fatalf("unsafe HTML preview enabled: %d", out.Code)
	}
	if out := call("DELETE", "/api/v1/files?path=Photos/test.txt", "", "", session, true); out.Code != 200 {
		t.Fatalf("trash %d", out.Code)
	}
	trash := call("GET", "/api/v1/files/trash", "", "", session, false)
	if trash.Code != 200 {
		t.Fatalf("trash list %d", trash.Code)
	}
	var content struct {
		Entries []files.TrashEntry `json:"entries"`
	}
	if err := json.Unmarshal(trash.Body.Bytes(), &content); err != nil || len(content.Entries) != 1 {
		t.Fatalf("trash list: %+v %v", content, err)
	}
	if out := call("POST", "/api/v1/files/trash/"+content.Entries[0].ID+"/restore", "", "", session, true); out.Code != 200 {
		t.Fatalf("restore %d %s", out.Code, out.Body.String())
	}
	if out := call("GET", "/api/v1/files/content?path=Photos/test.txt", "", "", session, false); out.Code != 200 || out.Body.String() != "hello" {
		t.Fatalf("restored original data %d", out.Code)
	}
	if out := call("GET", "/api/v1/files/content?path=..%2Fprivate", "", "", session, false); out.Code == 200 {
		t.Fatal("path traversal accepted")
	}
	if out := call("POST", "/api/v1/users", `{"username":"guest","password":"guest-password-12345","role":"member"}`, "", session, true); out.Code != 201 {
		t.Fatalf("admin create member %d %s", out.Code, out.Body.String())
	}
	guest := call("POST", "/api/v1/auth/login", `{"username":"guest","password":"guest-password-12345"}`, "", nil, true)
	if guest.Code != 200 || len(guest.Result().Cookies()) == 0 {
		t.Fatalf("guest login %d", guest.Code)
	}
	guestCookie := guest.Result().Cookies()[0]
	if out := call("POST", "/api/v1/users", `{"username":"hack","password":"hack-password-12345"}`, "", guestCookie, true); out.Code != 403 {
		t.Fatalf("guest created user %d", out.Code)
	}
	if out := call("PATCH", "/api/v1/users/1", `{"enabled":false}`, "", session, true); out.Code != 403 {
		t.Fatalf("founder disabled %d", out.Code)
	}
	if out := call("POST", "/api/v1/auth/login", setup, "", nil, false); out.Code != 403 {
		t.Fatalf("CSRF header missing %d", out.Code)
	}
}
