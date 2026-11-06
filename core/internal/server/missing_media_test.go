package server

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/mediapending"
)

func TestMissingMediaIsManagedByDirectoryOwner(t *testing.T) {
	f := newRootRoutingFixture(t)
	other, err := f.accounts.CreateUser(f.admin, "other", "other-password-2026", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	otherSession, err := f.accounts.Login("other", "other-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []int64{f.memberID, other.ID} {
		r := f.call(f.admin, http.MethodPut, rootRoute(f.rootA.ID, "/users/"+strconv.FormatInt(id, 10)+"/storage/photos"), "")
		if r.Code != 200 {
			t.Fatalf("assign: %d %s", r.Code, r.Body.String())
		}
		p := filepath.Join(f.pathA, "Users", "u"+strconv.FormatInt(id, 10), "photos", "photo.jpg")
		if err := os.WriteFile(p, []byte("photo"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	// Even a broad read grant must not let a member administer another
	// user's retained personal metadata.
	if err := f.accounts.SetRootGrant(f.admin, f.memberID, f.rootA.ID, ".", false); err != nil {
		t.Fatal(err)
	}
	startRootScans(t, f, f.rootA.ID)
	lib := f.services[f.rootA.ID].Gallery
	assets, _, err := lib.List(0, 30, 0, false)
	if err != nil || len(assets) != 2 {
		t.Fatalf("assets: %+v %v", assets, err)
	}
	for _, asset := range assets {
		if err := lib.Favorite(asset.ID, true); err != nil {
			t.Fatal(err)
		}
		if err := os.Remove(filepath.Join(f.pathA, filepath.FromSlash(asset.Path))); err != nil {
			t.Fatal(err)
		}
	}
	startRootScans(t, f, f.rootA.ID)
	list := func(session string) []mediapending.Item {
		t.Helper()
		r := f.call(session, http.MethodGet, rootRoute(f.rootA.ID, "/missing-media/photos"), "")
		if r.Code != 200 {
			t.Fatalf("list: %d %s", r.Code, r.Body.String())
		}
		var result struct {
			Items []mediapending.Item `json:"items"`
		}
		if err := json.Unmarshal(r.Body.Bytes(), &result); err != nil {
			t.Fatal(err)
		}
		return result.Items
	}
	adminItems, memberItems, otherItems := list(f.admin), list(f.member), list(otherSession)
	if len(adminItems) != 2 || len(memberItems) != 1 || len(otherItems) != 1 || memberItems[0].ID == otherItems[0].ID {
		t.Fatalf("scope mismatch: admin=%+v member=%+v other=%+v", adminItems, memberItems, otherItems)
	}
	path := "/missing-media/photos/" + strconv.FormatInt(otherItems[0].ID, 10)
	otherDirectory := "Users/u" + strconv.FormatInt(other.ID, 10) + "/photos"
	if err := f.accounts.SetRootGrant(f.admin, other.ID, f.rootA.ID, otherDirectory, false); err != nil {
		t.Fatal(err)
	}
	if got := list(otherSession); len(got) != 1 || got[0].CanManage {
		t.Fatalf("read-only owner visibility or write hint incorrect: %+v", got)
	}
	if r := f.call(otherSession, http.MethodDelete, rootRoute(f.rootA.ID, path), `{"confirm":true}`); r.Code != http.StatusNotFound {
		t.Fatalf("read-only owner discarded metadata: %d %s", r.Code, r.Body.String())
	}
	if err := f.accounts.SetRootGrant(f.admin, other.ID, f.rootA.ID, otherDirectory, true); err != nil {
		t.Fatal(err)
	}
	if r := f.call(f.member, http.MethodPost, rootRoute(f.rootA.ID, path+"/attach"), `{"confirm":true}`); r.Code != http.StatusNotFound {
		t.Fatalf("member attached another owner's item: %d %s", r.Code, r.Body.String())
	}
	if r := f.call(f.member, http.MethodDelete, rootRoute(f.rootA.ID, path), `{"confirm":true}`); r.Code != http.StatusNotFound {
		t.Fatalf("member discarded another owner's item: %d %s", r.Code, r.Body.String())
	}
	path = "/missing-media/photos/" + strconv.FormatInt(memberItems[0].ID, 10)
	if r := f.call(f.member, http.MethodDelete, rootRoute(f.rootA.ID, path), `{}`); r.Code != http.StatusBadRequest {
		t.Fatalf("discard without confirmation: %d %s", r.Code, r.Body.String())
	}
	if r := f.call(f.member, http.MethodDelete, rootRoute(f.rootA.ID, path), `{"confirm":true}`); r.Code != http.StatusOK {
		t.Fatalf("owner discard: %d %s", r.Code, r.Body.String())
	}
	if got := list(f.admin); len(got) != 1 || got[0].ID != otherItems[0].ID {
		t.Fatalf("discard affected other item: %+v", got)
	}
	if r := f.call(f.member, http.MethodPost, rootRoute(f.rootA.ID, "/missing-media/photos/recheck"), ""); r.Code != http.StatusAccepted {
		t.Fatalf("owner recheck: %d %s", r.Code, r.Body.String())
	}
}
