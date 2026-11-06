package server

import (
	"encoding/json"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestFolderAlbumsFollowDiskAndProtectNonemptyFolders(t *testing.T) {
	f := newRootRoutingFixture(t)
	base := rootRoute(f.rootA.ID, "/photos/folder-albums")
	assign := f.call(f.admin, http.MethodPut, rootRoute(f.rootA.ID, "/users/"+strconv.FormatInt(f.memberID, 10)+"/storage/photos"), "")
	if assign.Code != 200 {
		t.Fatalf("assign: %d %s", assign.Code, assign.Body.String())
	}
	created := f.call(f.member, http.MethodPost, base, `{"name":"家庭相册"}`)
	if created.Code != http.StatusCreated {
		t.Fatalf("create: %d %s", created.Code, created.Body.String())
	}
	var album struct{ Name, Path string }
	if err := json.Unmarshal(created.Body.Bytes(), &album); err != nil {
		t.Fatal(err)
	}
	actual := filepath.Join(f.pathA, filepath.FromSlash(album.Path))
	if info, err := os.Stat(actual); err != nil || !info.IsDir() {
		t.Fatalf("no real folder: %v", err)
	}
	outside := filepath.Join(f.pathA, "Users", "u"+strconv.FormatInt(f.memberID, 10), "photos", "other.jpg")
	inside := filepath.Join(actual, "one.jpg")
	for _, p := range []string{inside, outside} {
		if err := os.WriteFile(p, []byte("photo"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	listed := f.call(f.member, http.MethodGet, base, "")
	if listed.Code != 200 || !strings.Contains(listed.Body.String(), "家庭相册") {
		t.Fatalf("list: %d %s", listed.Code, listed.Body.String())
	}
	startRootScans(t, f, f.rootA.ID)
	page := f.call(f.member, http.MethodGet, rootRoute(f.rootA.ID, "/photos?directory="+url.QueryEscape(album.Path)), "")
	if page.Code != 200 || !strings.Contains(page.Body.String(), "one.jpg") || strings.Contains(page.Body.String(), "other.jpg") {
		t.Fatalf("folder filtering: %d %s", page.Code, page.Body.String())
	}
	deletePath := base + "/" + url.PathEscape(album.Name)
	blocked := f.call(f.member, http.MethodDelete, deletePath, "")
	if blocked.Code != http.StatusConflict || !strings.Contains(blocked.Body.String(), "album_not_empty") {
		t.Fatalf("nonempty album delete: %d %s", blocked.Code, blocked.Body.String())
	}
	if _, err := os.Stat(inside); err != nil {
		t.Fatalf("album file lost: %v", err)
	}
	if err := os.Remove(inside); err != nil {
		t.Fatal(err)
	}
	removed := f.call(f.member, http.MethodDelete, deletePath, "")
	if removed.Code != 200 {
		t.Fatalf("empty album delete: %d %s", removed.Code, removed.Body.String())
	}
	if _, err := os.Stat(actual); !os.IsNotExist(err) {
		t.Fatalf("empty folder still exists: %v", err)
	}
	bad := f.call(f.member, http.MethodPost, base, `{"name":"../escape"}`)
	if bad.Code != 400 {
		t.Fatalf("traversal accepted: %d %s", bad.Code, bad.Body.String())
	}
}
