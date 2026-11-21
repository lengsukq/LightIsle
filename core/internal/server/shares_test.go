package server

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
)

func TestTemporaryShareIsScopedRevocableAndBoundToSourceFile(t *testing.T) {
	f := newRootRoutingFixture(t)
	other, err := f.accounts.CreateUser(f.admin, "outsider", "outsider-password-12345", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	outsider, err := f.accounts.Login(other.Username, "outsider-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"family", "secret"} {
		if err := os.MkdirAll(filepath.Join(f.pathA, name), 0700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(f.pathA, "family", "photo.txt"), []byte("the original family photo"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(f.pathA, "secret", "hidden.txt"), []byte("not shared"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := f.accounts.SetRootGrant(f.admin, f.memberID, f.rootA.ID, "family", false); err != nil {
		t.Fatal(err)
	}
	reader := f.member
	call := func(method, url, session, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, url, strings.NewReader(body))
		if method == http.MethodPost || method == http.MethodDelete {
			r.Header.Set("X-LightIsle-Request", "1")
			r.Header.Set("X-LightIsle-Root-Generation", strconv.FormatUint(f.rootA.Generation, 10))
		}
		if session != "" {
			r.AddCookie(&http.Cookie{Name: sessionCookie, Value: session})
		}
		w := httptest.NewRecorder()
		f.server.ServeHTTP(w, r)
		return w
	}
	sharesURL := rootRoute(f.rootA.ID, "/file-shares")
	publicPrefix := rootRoute(f.rootA.ID, "/public/file/")
	if w := call("POST", sharesURL, reader, `{"path":"secret/hidden.txt","hours":1}`); w.Code != 403 {
		t.Fatalf("unauthorized share: %d", w.Code)
	}
	if w := call("POST", sharesURL, reader, `{"path":"family/photo.txt","hours":169}`); w.Code != 400 {
		t.Fatalf("invalid expiry: %d", w.Code)
	}
	// Folder links are a supported share kind: a granted reader can publish
	// one (served as a bounded ZIP), with full coverage in share_folder_test.
	if w := call("POST", sharesURL, reader, `{"path":"family","hours":1}`); w.Code != 201 {
		t.Fatalf("granted folder share rejected: %d %s", w.Code, w.Body.String())
	}
	if w := call("POST", sharesURL, reader, `{"path":"secret","hours":1}`); w.Code != 403 {
		t.Fatalf("unauthorized folder share: %d", w.Code)
	}
	if w := call("POST", sharesURL, outsider, `{"path":"family/photo.txt","hours":1}`); w.Code != http.StatusForbidden && w.Code != http.StatusNotFound {
		t.Fatalf("outsider share: %d", w.Code)
	}
	w := call("POST", sharesURL, reader, `{"path":"family/photo.txt","hours":1}`)
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
	url := publicPrefix + payload.Token
	if w := call("GET", url+"?view=1", "", ""); w.Code != 200 || !strings.Contains(w.Body.String(), "photo.txt") || !strings.Contains(w.Body.String(), "立即下载") {
		t.Fatalf("share preview landing page: %d %s", w.Code, w.Body.String())
	}
	if w := call("GET", url, "", ""); w.Code != 200 || w.Body.String() != "the original family photo" {
		t.Fatalf("anonymous download: %d %s", w.Code, w.Body.String())
	}
	if w := call("HEAD", url, "", ""); w.Code != 200 || w.Body.Len() != 0 {
		t.Fatalf("anonymous HEAD: %d %s", w.Code, w.Body.String())
	}
	list := call("GET", sharesURL, reader, "")
	if list.Code != 200 || !bytes.Contains(list.Body.Bytes(), []byte(payload.Share.ID)) || bytes.Contains(list.Body.Bytes(), []byte(payload.Token)) {
		t.Fatalf("list leaks token or not listed: %d %s", list.Code, list.Body.String())
	}
	if w := call("DELETE", sharesURL+"/"+payload.Share.ID, outsider, ""); w.Code != http.StatusOK && w.Code != http.StatusNotFound && w.Code != http.StatusForbidden {
		t.Fatalf("other account revoke returned invalid HTTP status: %d", w.Code)
	}
	if w := call("GET", url, "", ""); w.Code != 200 {
		t.Fatal("outsider revoked another account's share")
	}
	if err := f.accounts.RemoveRootGrant(f.admin, f.memberID, f.rootA.ID, "family"); err != nil {
		t.Fatal(err)
	}
	if w := call("GET", url, "", ""); w.Code != 404 {
		t.Fatalf("revoked access still public: %d", w.Code)
	}
	if err := f.accounts.SetRootGrant(f.admin, f.memberID, f.rootA.ID, "family", false); err != nil {
		t.Fatal(err)
	}
	if w := call("GET", url, "", ""); w.Code != 404 {
		t.Fatalf("old share resurrected when grant was restored: %d", w.Code)
	}
	fresh := call("POST", sharesURL, reader, `{"path":"family/photo.txt","hours":1}`)
	if fresh.Code != 201 {
		t.Fatalf("new share denied after re-grant: %d %s", fresh.Code, fresh.Body.String())
	}
	var next struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(fresh.Body.Bytes(), &next); err != nil {
		t.Fatal(err)
	}
	newURL := publicPrefix + next.Token
	if w := call("GET", newURL, "", ""); w.Code != 200 {
		t.Fatalf("newly authorized share: %d", w.Code)
	}
	if err := os.Remove(filepath.Join(f.pathA, "family", "photo.txt")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(f.pathA, "family", "photo.txt"), []byte("different replacement bytes"), 0600); err != nil {
		t.Fatal(err)
	}
	if w := call("GET", newURL, "", ""); w.Code != 404 {
		t.Fatalf("replaced file was shared: %d %s", w.Code, w.Body.String())
	}
	if w := call("DELETE", sharesURL+"/"+payload.Share.ID, reader, ""); w.Code != 200 {
		t.Fatalf("revoke: %d", w.Code)
	}
	if w := call("GET", url, "", ""); w.Code != 404 {
		t.Fatalf("revoke ineffective: %d", w.Code)
	}
	if w := call("GET", publicPrefix+"invalid-token", "", ""); w.Code != 404 {
		t.Fatalf("invalid link: %d", w.Code)
	}
}
