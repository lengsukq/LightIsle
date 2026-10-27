package server

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestTemporaryShareIsScopedRevocableAndBoundToSourceFile(t *testing.T) {
	dir := t.TempDir()
	accounts, err := auth.Open(filepath.Join(dir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("owner", "owner-password-12345"); err != nil {
		t.Fatal(err)
	}
	admin, err := accounts.Login("owner", "owner-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	member, err := accounts.CreateUser(admin, "reader", "reader-password-12345", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	reader, err := accounts.Login("reader", "reader-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	other, err := accounts.CreateUser(admin, "outsider", "outsider-password-12345", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	outsider, err := accounts.Login(other.Username, "outsider-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	store, err := files.Open(filepath.Join(dir, "SharedFiles"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	for _, name := range []string{"family", "secret"} {
		if err := store.Mkdir(name); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := store.Upload("family/photo.txt", strings.NewReader("the original family photo")); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Upload("secret/hidden.txt", strings.NewReader("not shared")); err != nil {
		t.Fatal(err)
	}
	if err := accounts.SetFileGrant(admin, member.ID, "family", false); err != nil {
		t.Fatal(err)
	}
	h := New("", accounts, store)
	call := func(method, url, session, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, url, strings.NewReader(body))
		if method == http.MethodPost || method == http.MethodDelete {
			r.Header.Set("X-LightIsle-Request", "1")
		}
		if session != "" {
			r.AddCookie(&http.Cookie{Name: sessionCookie, Value: session})
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	if w := call("POST", "/api/v2/file-shares", reader, `{"path":"secret/hidden.txt","hours":1}`); w.Code != 403 {
		t.Fatalf("unauthorized share: %d", w.Code)
	}
	if w := call("POST", "/api/v2/file-shares", reader, `{"path":"family/photo.txt","hours":169}`); w.Code != 400 {
		t.Fatalf("invalid expiry: %d", w.Code)
	}
	// Folder links are a supported share kind: a granted reader can publish
	// one (served as a bounded ZIP), with full coverage in share_folder_test.
	if w := call("POST", "/api/v2/file-shares", reader, `{"path":"family","hours":1}`); w.Code != 201 {
		t.Fatalf("granted folder share rejected: %d %s", w.Code, w.Body.String())
	}
	if w := call("POST", "/api/v2/file-shares", reader, `{"path":"secret","hours":1}`); w.Code != 403 {
		t.Fatalf("unauthorized folder share: %d", w.Code)
	}
	if w := call("POST", "/api/v2/file-shares", outsider, `{"path":"family/photo.txt","hours":1}`); w.Code != 403 {
		t.Fatalf("outsider share: %d", w.Code)
	}
	w := call("POST", "/api/v2/file-shares", reader, `{"path":"family/photo.txt","hours":1}`)
	if w.Code != 201 {
		t.Fatalf("create: %d %s", w.Code, w.Body.String())
	}
	var payload struct {
		Share auth.FileShare `json:"share"`
		Token string         `json:"token"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if len(payload.Token) != 43 || len(payload.Share.ID) != 64 {
		t.Fatal("invalid capability token format")
	}
	if payload.Share.ExpiresAt-payload.Share.CreatedAt != 3600 {
		t.Fatal("invalid TTL")
	}
	url := "/api/v2/public/file/" + payload.Token
	if w := call("GET", url, "", ""); w.Code != 200 || w.Body.String() != "the original family photo" {
		t.Fatalf("anonymous download: %d %s", w.Code, w.Body.String())
	}
	if w := call("HEAD", url, "", ""); w.Code != 200 || w.Body.Len() != 0 {
		t.Fatalf("anonymous HEAD: %d %s", w.Code, w.Body.String())
	}
	list := call("GET", "/api/v2/file-shares", reader, "")
	if list.Code != 200 || !bytes.Contains(list.Body.Bytes(), []byte(payload.Share.ID)) || bytes.Contains(list.Body.Bytes(), []byte(payload.Token)) {
		t.Fatalf("list leaks token or not listed: %d %s", list.Code, list.Body.String())
	}
	if w := call("DELETE", "/api/v2/file-shares/"+payload.Share.ID, outsider, ""); w.Code != 200 {
		t.Fatal("other account revoke returned invalid HTTP status")
	}
	if w := call("GET", url, "", ""); w.Code != 200 {
		t.Fatal("outsider revoked another account's share")
	}
	if err := accounts.RemoveFileGrant(admin, member.ID, "family"); err != nil {
		t.Fatal(err)
	}
	if w := call("GET", url, "", ""); w.Code != 404 {
		t.Fatalf("revoked access still public: %d", w.Code)
	}
	if err := accounts.SetFileGrant(admin, member.ID, "family", false); err != nil {
		t.Fatal(err)
	}
	if w := call("GET", url, "", ""); w.Code != 404 {
		t.Fatalf("old share resurrected when grant was restored: %d", w.Code)
	}
	fresh := call("POST", "/api/v2/file-shares", reader, `{"path":"family/photo.txt","hours":1}`)
	if fresh.Code != 201 {
		t.Fatalf("new share denied after re-grant: %d %s", fresh.Code, fresh.Body.String())
	}
	var next struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(fresh.Body.Bytes(), &next); err != nil {
		t.Fatal(err)
	}
	newURL := "/api/v2/public/file/" + next.Token
	if w := call("GET", newURL, "", ""); w.Code != 200 {
		t.Fatalf("newly authorized share: %d", w.Code)
	}
	if err := store.MoveToTrash("family/photo.txt"); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Upload("family/photo.txt", strings.NewReader("different replacement bytes")); err != nil {
		t.Fatal(err)
	}
	if w := call("GET", newURL, "", ""); w.Code != 404 {
		t.Fatalf("replaced file was shared: %d %s", w.Code, w.Body.String())
	}
	if w := call("DELETE", "/api/v2/file-shares/"+payload.Share.ID, reader, ""); w.Code != 200 {
		t.Fatalf("revoke: %d", w.Code)
	}
	if w := call("GET", url, "", ""); w.Code != 404 {
		t.Fatalf("revoke ineffective: %d", w.Code)
	}
	if w := call("GET", "/api/v2/public/file/invalid-token", "", ""); w.Code != 404 {
		t.Fatalf("invalid link: %d", w.Code)
	}
}
