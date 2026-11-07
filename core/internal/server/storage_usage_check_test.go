package server

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/roots"
)

func TestLiveUsageReportKeepsDiskAccountingSeparate(t *testing.T) {
	f := newRootRoutingFixture(t)
	userID := strconv.FormatInt(f.memberID, 10)
	for _, test := range []struct {
		root     roots.Root
		category string
		contents string
		pending  int64
	}{
		{f.rootA, "files", "abc", 5},
		{f.rootB, "photos", "1234567", 11},
	} {
		base := rootRoute(test.root.ID, "")
		if response := f.call(f.admin, http.MethodPut, base+"/users/"+userID+"/storage/"+test.category, ""); response.Code != http.StatusOK {
			t.Fatalf("assign %s: %d %s", test.category, response.Code, response.Body.String())
		}
		prefix := "Users/u" + userID + "/" + test.category + "/"
		if response := f.call(f.member, http.MethodPut, base+"/files/content?path="+prefix+"file.dat", test.contents); response.Code != http.StatusCreated {
			t.Fatalf("upload %s: %d %s", test.category, response.Code, response.Body.String())
		}
		if _, tracked, err := f.accounts.ReserveStorageUpload(f.member, test.root.ID, test.root.Generation, prefix+"pending.dat", test.pending); err != nil || !tracked {
			t.Fatalf("reserve %s: tracked=%v err=%v", test.category, tracked, err)
		}
	}

	for _, test := range []struct {
		root     roots.Root
		live     int64
		reserved int64
	}{
		{f.rootA, 3, 5},
		{f.rootB, 7, 11},
	} {
		url := rootRoute(test.root.ID, "/storage/users/"+userID+"/usage-check")
		response := f.call(f.admin, http.MethodGet, url, "")
		if response.Code != http.StatusOK {
			t.Fatalf("check %s: %d %s", test.root.ID, response.Code, response.Body.String())
		}
		var report struct {
			RootID         string `json:"rootID"`
			RootGeneration uint64 `json:"rootGeneration"`
			LiveBytes      int64  `json:"liveBytes"`
			LedgerBytes    int64  `json:"ledgerBytes"`
			ReservedBytes  int64  `json:"reservedBytes"`
		}
		if err := json.Unmarshal(response.Body.Bytes(), &report); err != nil {
			t.Fatal(err)
		}
		if report.RootID != test.root.ID || report.RootGeneration != test.root.Generation || report.LiveBytes != test.live || report.LedgerBytes != test.live || report.ReservedBytes != test.reserved {
			t.Fatalf("wrong root-scoped report: %+v", report)
		}
	}
	if meter, err := f.accounts.StorageMeter(f.admin, f.memberID); err != nil || meter.UsedBytes != 10 || meter.ReservedBytes != 16 {
		t.Fatalf("read-only checks changed accounting: %+v, %v", meter, err)
	}
}

func TestDirectUploadPersistsPublishedFileIdentityAcrossRename(t *testing.T) {
	f := newRootRoutingFixture(t)
	category := assignFixtureMemberStorage(t, f)
	name := category + "/original.txt"
	newName := category + "/renamed.txt"
	base := rootRoute(f.rootA.ID, "")
	if response := f.call(f.member, http.MethodPut, base+"/files/content?path="+name, "abc"); response.Code != http.StatusCreated {
		t.Fatalf("upload: %d %s", response.Code, response.Body.String())
	}
	info, err := os.Stat(filepath.Join(f.pathA, filepath.FromSlash(name)))
	if err != nil {
		t.Fatal(err)
	}
	want := files.MediaFileIdentity(info)
	got, err := f.accounts.StorageFileIdentity(f.rootA.ID, f.rootA.Generation, name)
	if err != nil || want == "" || got != want {
		t.Fatalf("published identity: got %q want %q (%v)", got, want, err)
	}
	body, _ := json.Marshal(map[string]string{"action": "move", "from": name, "to": newName})
	if response := f.call(f.member, http.MethodPost, base+"/files/operations", string(body)); response.Code != http.StatusOK {
		t.Fatalf("rename: %d %s", response.Code, response.Body.String())
	}
	got, err = f.accounts.StorageFileIdentity(f.rootA.ID, f.rootA.Generation, newName)
	if err != nil || got != want {
		t.Fatalf("rename lost identity: %q (%v)", got, err)
	}
	if old, err := f.accounts.StorageFileIdentity(f.rootA.ID, f.rootA.Generation, name); err != nil || old != "" {
		t.Fatalf("old path kept identity: %q (%v)", old, err)
	}
	if other, err := f.accounts.StorageFileIdentity(f.rootB.ID, f.rootB.Generation, newName); err != nil || other != "" {
		t.Fatalf("identity crossed roots: %q (%v)", other, err)
	}
	body, _ = json.Marshal(map[string]string{"action": "copy", "from": newName, "to": name})
	if response := f.call(f.member, http.MethodPost, base+"/files/operations", string(body)); response.Code != http.StatusOK {
		t.Fatalf("copy: %d %s", response.Code, response.Body.String())
	}
	info, err = os.Stat(filepath.Join(f.pathA, filepath.FromSlash(name)))
	if err != nil {
		t.Fatal(err)
	}
	copyIdentity := files.MediaFileIdentity(info)
	got, err = f.accounts.StorageFileIdentity(f.rootA.ID, f.rootA.Generation, name)
	if err != nil || copyIdentity == "" || copyIdentity == want || got != copyIdentity {
		t.Fatalf("copy identity: got %q, copy %q, source %q (%v)", got, copyIdentity, want, err)
	}
}

func TestPurgingOldDirectoryDoesNotUnaccountRecreatedDirectory(t *testing.T) {
	f := newRootRoutingFixture(t)
	category := assignFixtureMemberStorage(t, f)
	dir := category + "/family"
	base := rootRoute(f.rootA.ID, "")
	for _, step := range []struct {
		method, path, body string
		status             int
	}{
		{http.MethodPost, "/files/folders", `{"path":"` + dir + `"}`, http.StatusCreated},
		{http.MethodPut, "/files/content?path=" + dir + "/old.txt", "abc", http.StatusCreated},
		{http.MethodDelete, "/files?path=" + dir, "", http.StatusOK},
		{http.MethodPost, "/files/folders", `{"path":"` + dir + `"}`, http.StatusCreated},
		{http.MethodPut, "/files/content?path=" + dir + "/new.txt", "1234", http.StatusCreated},
	} {
		response := f.call(f.member, step.method, base+step.path, step.body)
		if response.Code != step.status {
			t.Fatalf("%s %s: %d %s", step.method, step.path, response.Code, response.Body.String())
		}
	}
	listing := f.call(f.member, http.MethodGet, base+"/files/trash", "")
	var result struct {
		Entries []struct {
			ID string `json:"id"`
		} `json:"entries"`
	}
	if err := json.Unmarshal(listing.Body.Bytes(), &result); listing.Code != http.StatusOK || err != nil || len(result.Entries) != 1 {
		t.Fatalf("trash listing: %d %s (%v)", listing.Code, listing.Body.String(), err)
	}
	response := f.call(f.member, http.MethodDelete, base+"/files/trash/"+result.Entries[0].ID, "")
	if response.Code != http.StatusOK {
		t.Fatalf("safe purge of old directory failed: %d %s", response.Code, response.Body.String())
	}
	if meter, err := f.accounts.StorageMeter(f.admin, f.memberID); err != nil || meter.UsedBytes != 4 {
		t.Fatalf("purge should release old 3B and keep recreated 4B: %+v %v", meter, err)
	}
	renamedDir := category + "/family-renamed"
	moveBody, _ := json.Marshal(map[string]string{"action": "move", "from": dir, "to": renamedDir})
	if response := f.call(f.member, http.MethodPost, base+"/files/operations", string(moveBody)); response.Code != http.StatusOK {
		t.Fatalf("directory rename failed: %d %s", response.Code, response.Body.String())
	}
	if got, err := f.accounts.StorageFileIdentity(f.rootA.ID, f.rootA.Generation, renamedDir+"/new.txt"); err != nil || got == "" {
		t.Fatalf("directory rename lost file identity: %q %v", got, err)
	}
	if meter, err := f.accounts.StorageMeter(f.admin, f.memberID); err != nil || meter.UsedBytes != 4 {
		t.Fatalf("directory rename changed used bytes: %+v %v", meter, err)
	}
}
