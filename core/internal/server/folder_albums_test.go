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

	"github.com/lengsukq/lightisle/core/internal/auth"
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

func TestFolderAlbumControlledSymlinkShareAndQuotaAccounting(t *testing.T) {
	f := newRootRoutingFixture(t)
	bobUser, err := f.accounts.CreateUser(f.admin, "bob", "MemberPass123!", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	bobTok, err := f.accounts.Login("bob", "MemberPass123!")
	if err != nil {
		t.Fatal(err)
	}

	// Assign photos storage on rootA for both member (owner) and bob (recipient).
	for _, uid := range []int64{f.memberID, bobUser.ID} {
		assign := f.call(f.admin, http.MethodPut, rootRoute(f.rootA.ID, "/users/"+strconv.FormatInt(uid, 10)+"/storage/photos"), "")
		if assign.Code != 200 {
			t.Fatalf("assign photos for %d: %d %s", uid, assign.Code, assign.Body.String())
		}
		if err := f.accounts.SetUserStorageRootQuota(f.admin, uid, f.rootA.ID, f.rootA.Generation, 1048576); err != nil {
			t.Fatal(err)
		}
	}

	base := rootRoute(f.rootA.ID, "/photos/folder-albums")
	if res := f.call(f.member, http.MethodPost, base, `{"name":"夏日旅行"}`); res.Code != http.StatusCreated {
		t.Fatalf("create owner album: %d %s", res.Code, res.Body.String())
	}
	ownerAlbumRel := "Users/u" + strconv.FormatInt(f.memberID, 10) + "/photos/夏日旅行"
	ownerPhotoDisk := filepath.Join(f.pathA, filepath.FromSlash(ownerAlbumRel), "beach.jpg")
	if err := os.WriteFile(ownerPhotoDisk, []byte("beach-bytes"), 0600); err != nil {
		t.Fatal(err)
	}
	startRootScans(t, f, f.rootA.ID)

	// Share read-only with bob first.
	shareURL := base + "/" + url.PathEscape("夏日旅行") + "/shares"
	sharedRO := f.call(f.member, http.MethodPost, shareURL, `{"memberUserId":`+strconv.FormatInt(bobUser.ID, 10)+`,"canWrite":false}`)
	if sharedRO.Code != http.StatusOK {
		t.Fatalf("share read-only: %d %s", sharedRO.Code, sharedRO.Body.String())
	}

	// Verify controlled relative symlink on disk in bob's photos directory.
	bobSymlinkDisk := filepath.Join(f.pathA, "Users", "u"+strconv.FormatInt(bobUser.ID, 10), "photos", "夏日旅行")
	linkTarget, err := os.Readlink(bobSymlinkDisk)
	if err != nil {
		t.Fatalf("expected symlink on disk: %v", err)
	}
	expectedRel := "../../u" + strconv.FormatInt(f.memberID, 10) + "/photos/夏日旅行"
	if linkTarget != expectedRel {
		t.Fatalf("unexpected symlink target: got %q, want %q", linkTarget, expectedRel)
	}

	// Bob sees the shared album in folder-albums list and can read its photos.
	bobList := f.call(bobTok, http.MethodGet, base, "")
	if bobList.Code != http.StatusOK || !strings.Contains(bobList.Body.String(), `"shared":true`) || !strings.Contains(bobList.Body.String(), ownerAlbumRel) {
		t.Fatalf("bob folder album list: %d %s", bobList.Code, bobList.Body.String())
	}
	bobPhotos := f.call(bobTok, http.MethodGet, rootRoute(f.rootA.ID, "/photos?directory="+url.QueryEscape(ownerAlbumRel)), "")
	if bobPhotos.Code != http.StatusOK || !strings.Contains(bobPhotos.Body.String(), "beach.jpg") {
		t.Fatalf("bob read shared album photos: %d %s", bobPhotos.Code, bobPhotos.Body.String())
	}

	// Read-only share rejects upload by bob.
	roUpload := f.call(bobTok, http.MethodPut, rootRoute(f.rootA.ID, "/files/content?path="+url.QueryEscape(ownerAlbumRel+"/bob_ro.jpg")), "blocked")
	if roUpload.Code != http.StatusForbidden {
		t.Fatalf("expected 403 on read-only shared album upload, got %d %s", roUpload.Code, roUpload.Body.String())
	}

	// Upgrade share to writable; bob's upload succeeds and charges owner's quota.
	sharedRW := f.call(f.member, http.MethodPost, shareURL, `{"memberUserId":`+strconv.FormatInt(bobUser.ID, 10)+`,"canWrite":true}`)
	if sharedRW.Code != http.StatusOK {
		t.Fatalf("share writable: %d %s", sharedRW.Code, sharedRW.Body.String())
	}
	payload := "bob-shared-photo-12345"
	rwUpload := f.call(bobTok, http.MethodPut, rootRoute(f.rootA.ID, "/files/content?path="+url.QueryEscape(ownerAlbumRel+"/bob_rw.jpg")), payload)
	if rwUpload.Code != http.StatusCreated {
		t.Fatalf("writable shared album upload: %d %s", rwUpload.Code, rwUpload.Body.String())
	}
	ownerMeter, err := f.accounts.StorageMeter(f.member, f.memberID)
	if err != nil {
		t.Fatal(err)
	}
	bobMeter, err := f.accounts.StorageMeter(bobTok, bobUser.ID)
	if err != nil {
		t.Fatal(err)
	}
	if ownerMeter.UsedBytes != int64(len(payload)) || bobMeter.UsedBytes != 0 {
		t.Fatalf("quota charge mismatch: owner=%d (want %d), bob=%d (want 0)", ownerMeter.UsedBytes, len(payload), bobMeter.UsedBytes)
	}

	// Unshare removes the symlink from bob's photos dir without deleting owner's files.
	unshare := f.call(f.member, http.MethodDelete, shareURL+"/"+strconv.FormatInt(bobUser.ID, 10), "")
	if unshare.Code != http.StatusOK {
		t.Fatalf("unshare: %d %s", unshare.Code, unshare.Body.String())
	}
	if _, err := os.Lstat(bobSymlinkDisk); !os.IsNotExist(err) {
		t.Fatalf("expected bob symlink removed after unshare, got %v", err)
	}
	if _, err := os.Stat(ownerPhotoDisk); err != nil {
		t.Fatalf("owner photo must remain intact after unshare: %v", err)
	}
	deniedAfter := f.call(bobTok, http.MethodGet, rootRoute(f.rootA.ID, "/photos?directory="+url.QueryEscape(ownerAlbumRel)), "")
	if deniedAfter.Code != http.StatusNotFound {
		t.Fatalf("expected 404 after unshare, got %d %s", deniedAfter.Code, deniedAfter.Body.String())
	}
}
