package server

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestLegacyFileAPICannotReadOrWriteNewPersonalHomes(t *testing.T) {
	dir := t.TempDir()
	accounts, err := auth.Open(filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("owner", "owner-pass-123456"); err != nil {
		t.Fatal(err)
	}
	admin, err := accounts.Login("owner", "owner-pass-123456")
	if err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(dir, "share")
	if err := os.MkdirAll(filepath.Join(root, "Users", "u2", "files"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "Users", "u2", "files", "private.txt"), []byte("secret"), 0600); err != nil {
		t.Fatal(err)
	}
	store, err := files.Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	handler := New("", accounts, store)
	call := func(method, target, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, target, strings.NewReader(body))
		r.AddCookie(&http.Cookie{Name: sessionCookie, Value: admin})
		r.Header.Set("X-LightIsle-Request", "1")
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}
	for _, request := range []struct{ method, path, body string }{
		{"GET", "/api/v1/files?path=Users", ""},
		{"GET", "/api/v1/files/content?path=Users/u2/files/private.txt", ""},
		{"GET", "/api/v1/files/content?path=users/u2/files/private.txt", ""},
		{"PUT", "/api/v1/files/content?path=Users/u2/files/injected.txt", "bad"},
		{"PUT", "/api/v1/files/content?path=USERS/u2/files/injected.txt", "bad"},
		{"POST", "/api/v1/files/folders", `{"path":"Users/u2/files/new-folder"}`},
		{"GET", "/api/v1/files/search?path=Users&query=private", ""},
	} {
		if got := call(request.method, request.path, request.body); got.Code != http.StatusForbidden {
			t.Fatalf("legacy %s %s = %d %s", request.method, request.path, got.Code, got.Body.String())
		}
	}
	if got := call("GET", "/api/v1/files?path=.", ""); got.Code != http.StatusOK || strings.Contains(got.Body.String(), `"name":"Users"`) {
		t.Fatalf("legacy root listing leaked Users or failed: %d %s", got.Code, got.Body.String())
	}
	if _, err := os.Stat(filepath.Join(root, "Users", "u2", "files", "injected.txt")); !os.IsNotExist(err) {
		t.Fatalf("legacy wrote private file: %v", err)
	}
}
