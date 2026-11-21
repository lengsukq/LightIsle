package server

import (
	"bytes"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

func TestMemberGrantsAreEnforced(t *testing.T) {
	f := newRootRoutingFixture(t)
	for _, folder := range []string{"family", "private"} {
		if err := os.MkdirAll(filepath.Join(f.pathA, folder), 0700); err != nil {
			t.Fatal(err)
		}
	}
	for _, p := range []string{"family/photo.txt", "private/secret.txt"} {
		if err := os.WriteFile(filepath.Join(f.pathA, p), []byte("test"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	rURL := func(suffix string) string { return rootRoute(f.rootA.ID, suffix) }
	// Before receiving any grant on rootA, the member cannot even discover the root (404).
	if w := f.call(f.member, "GET", rURL("/files/content?path=private/secret.txt"), ""); w.Code != http.StatusNotFound && w.Code != http.StatusForbidden {
		t.Fatalf("member could read secret: %d", w.Code)
	}
	if w := f.call(f.member, "GET", rURL("/cinema"), ""); w.Code != http.StatusNotFound && w.Code != http.StatusForbidden {
		t.Fatalf("member can browse cinema: %d", w.Code)
	}
	target := rURL("/users/" + strconv.FormatInt(f.memberID, 10) + "/file-grants")
	if w := f.call(f.admin, "PUT", target, `{"path":"family","canWrite":false}`); w.Code != 200 {
		t.Fatalf("grant %d %s", w.Code, w.Body.String())
	}
	if w := f.call(f.member, "GET", rURL("/files/content?path=private/secret.txt"), ""); w.Code != http.StatusForbidden {
		t.Fatalf("granted member could read sibling secret: %d", w.Code)
	}
	if w := f.call(f.member, "GET", rURL("/files?path=."), ""); w.Code != 200 || !bytes.Contains(w.Body.Bytes(), []byte("family")) || bytes.Contains(w.Body.Bytes(), []byte("private")) {
		t.Fatalf("root filtering %d %s", w.Code, w.Body.String())
	}
	if w := f.call(f.member, "GET", rURL("/files/content?path=family/photo.txt"), ""); w.Code != 200 {
		t.Fatalf("read grant %d", w.Code)
	}
	if w := f.call(f.member, "DELETE", rURL("/files?path=family/photo.txt"), ""); w.Code != 403 {
		t.Fatalf("read-only deletion %d", w.Code)
	}
	if w := f.call(f.member, "GET", rURL("/files/search?query=secret"), ""); w.Code != 200 || bytes.Contains(w.Body.Bytes(), []byte("secret.txt")) {
		t.Fatalf("search leak %d %s", w.Code, w.Body.String())
	}
	if w := f.call(f.admin, "PUT", target, `{"path":"family","canWrite":true}`); w.Code != 200 {
		t.Fatalf("write grant %d", w.Code)
	}
	if w := f.call(f.member, "POST", rURL("/files/folders"), `{"path":"family/new"}`); w.Code != 201 {
		t.Fatalf("write grant failed %d", w.Code)
	}
	if w := f.call(f.admin, "DELETE", target+"?path=family", ""); w.Code != 200 {
		t.Fatalf("revoke %d", w.Code)
	}
	if w := f.call(f.member, "GET", rURL("/files/content?path=family/photo.txt"), ""); w.Code != http.StatusForbidden && w.Code != http.StatusNotFound {
		t.Fatalf("revocation failed %d", w.Code)
	}
	if w := f.call(f.admin, "PUT", target, `{"path":"../private","canWrite":true}`); w.Code == http.StatusOK {
		t.Fatal("unsafe grant accepted")
	}
}
