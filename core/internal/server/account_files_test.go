package server

import (
	"bytes"
	"crypto/tls"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestLoginCookieSecureMatchesTransport(t *testing.T) {
	accounts, err := auth.Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("owner", "long-initial-password"); err != nil {
		t.Fatal(err)
	}
	handler := New("", accounts, nil)
	request := httptest.NewRequest(http.MethodPost, "/api/v1/auth/login", bytes.NewBufferString(`{"username":"owner","password":"long-initial-password"}`))
	request.RemoteAddr = "192.168.1.4:1000"
	request.Header.Set("X-LightIsle-Request", "1")
	request.TLS = &tls.ConnectionState{}
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("HTTPS login returned %d: %s", response.Code, response.Body.String())
	}
	cookies := response.Result().Cookies()
	if len(cookies) != 1 || !cookies[0].Secure {
		t.Fatalf("HTTPS login cookie is not Secure: %+v", cookies)
	}
}

func TestLoginRejectsSessionDisabledBeforeResponse(t *testing.T) {
	accounts, err := auth.Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("owner", "long-initial-password"); err != nil {
		t.Fatal(err)
	}
	admin, err := accounts.Login("owner", "long-initial-password")
	if err != nil {
		t.Fatal(err)
	}
	member, err := accounts.CreateUser(admin, "guest", "guest-password-12345", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	api := &API{auth: accounts, limiter: newLoginLimiter()}
	api.afterLogin = func() {
		if err := accounts.SetEnabled(admin, member.ID, false); err != nil {
			t.Errorf("disable during login: %v", err)
		}
	}
	request := httptest.NewRequest(http.MethodPost, "/api/v1/auth/login", bytes.NewBufferString(`{"username":"guest","password":"guest-password-12345"}`))
	request.RemoteAddr = "127.0.0.1:1000"
	response := httptest.NewRecorder()
	api.login(response, request)
	if response.Code != http.StatusInternalServerError || bytes.Contains(response.Body.Bytes(), []byte(`"authenticated":true`)) {
		t.Fatalf("disabled login = %d %s", response.Code, response.Body.String())
	}
	if cookies := response.Result().Cookies(); len(cookies) != 0 {
		t.Fatalf("disabled login emitted cookies: %+v", cookies)
	}
}

func TestLoginReportsStorageFailureAsServerError(t *testing.T) {
	accounts, err := auth.Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	if err := accounts.Setup("owner", "long-initial-password"); err != nil {
		t.Fatal(err)
	}
	// A closed database makes Login fail before any credential comparison,
	// exercising the non-401 storage-error mapping.
	if err := accounts.Close(); err != nil {
		t.Fatal(err)
	}
	handler := New("", accounts, nil)
	request := httptest.NewRequest(http.MethodPost, "/api/v1/auth/login", bytes.NewBufferString(`{"username":"owner","password":"long-initial-password"}`))
	request.RemoteAddr = "127.0.0.1:1000"
	request.Header.Set("X-LightIsle-Request", "1")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusInternalServerError {
		t.Fatalf("storage failure login = %d %s", response.Code, response.Body.String())
	}
	if !bytes.Contains(response.Body.Bytes(), []byte("login_failed")) {
		t.Fatalf("storage failure body = %s", response.Body.String())
	}
	if cookies := response.Result().Cookies(); len(cookies) != 0 {
		t.Fatalf("storage failure emitted cookies: %+v", cookies)
	}
}

func TestFileErrorReportsStorageSyncFailureAsServerError(t *testing.T) {
	response := httptest.NewRecorder()
	fileError(response, files.ErrPublishedSync)
	if response.Code != http.StatusServiceUnavailable || !bytes.Contains(response.Body.Bytes(), []byte("upload_outcome_uncertain")) {
		t.Fatalf("sync error response = %d %s", response.Code, response.Body.String())
	}
	response = httptest.NewRecorder()
	fileError(response, files.ErrStorageSync)
	if response.Code != http.StatusServiceUnavailable || !bytes.Contains(response.Body.Bytes(), []byte("storage_durability_failure")) {
		t.Fatalf("storage sync response = %d %s", response.Code, response.Body.String())
	}
}

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
	if session.MaxAge != int(auth.SessionLifetime.Seconds()) || session.Secure {
		t.Fatalf("loopback cookie attributes: MaxAge=%d Secure=%t", session.MaxAge, session.Secure)
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
