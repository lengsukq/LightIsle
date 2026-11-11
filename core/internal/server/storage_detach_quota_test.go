package server

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/files"
)

// Publishing through an already pinned directory can succeed while its mount
// path is concurrently replaced. Neither a new directory at that path nor
// bytes on the old descriptor prove the RootRegistry identity is current.
type detachAfterPublishFiles struct {
	files.Access
	detach func()
}

type detachAfterPurgeFiles struct {
	files.Access
	detach func()
}

type detachAfterTrashChangeFiles struct {
	files.Access
	detach  func()
	restore bool
}

func (f *detachAfterTrashChangeFiles) MoveToTrash(name string) error {
	if err := f.Access.MoveToTrash(name); err != nil {
		return err
	}
	if !f.restore {
		f.detach()
	}
	return nil
}

func (f *detachAfterTrashChangeFiles) Restore(id string) error {
	if err := f.Access.Restore(id); err != nil {
		return err
	}
	if f.restore {
		f.detach()
	}
	return nil
}

func TestTrashAndRestoreDuringRootSwapReportUncertainty(t *testing.T) {
	for _, restore := range []bool{false, true} {
		t.Run(strconv.FormatBool(restore), func(t *testing.T) {
			f := newRootRoutingFixture(t)
			category := assignFixtureMemberStorage(t, f)
			name := category + "/photo.jpg"
			base := rootRoute(f.rootA.ID, "")
			if r := f.call(f.member, http.MethodPut, base+"/files/content?path="+name, "abc"); r.Code != http.StatusCreated {
				t.Fatalf("upload: %d %s", r.Code, r.Body.String())
			}
			url, method := base+"/files?path="+name, http.MethodDelete
			if restore {
				if r := f.call(f.member, http.MethodDelete, url, ""); r.Code != http.StatusOK {
					t.Fatalf("trash: %d %s", r.Code, r.Body.String())
				}
				listing := f.call(f.member, http.MethodGet, base+"/files/trash", "")
				var result struct {
					Entries []files.TrashEntry `json:"entries"`
				}
				if err := json.Unmarshal(listing.Body.Bytes(), &result); err != nil || len(result.Entries) != 1 {
					t.Fatalf("trash listing: %s (%v)", listing.Body.String(), err)
				}
				url, method = base+"/files/trash/"+result.Entries[0].ID+"/restore", http.MethodPost
			}
			service := f.services[f.rootA.ID]
			service.Files = &detachAfterTrashChangeFiles{Access: service.Files, restore: restore, detach: func() {
				if err := os.Rename(f.pathA, f.pathA+"-detached"); err != nil {
					t.Fatal(err)
				}
				if err := os.Mkdir(f.pathA, 0700); err != nil {
					t.Fatal(err)
				}
			}}
			response := f.call(f.member, method, url, "")
			if response.Code != http.StatusServiceUnavailable || !strings.Contains(response.Body.String(), "storage_operation_uncertain") {
				t.Fatalf("detached operation reported success: %d %s", response.Code, response.Body.String())
			}
			if meter, err := f.accounts.StorageMeter(f.admin, f.memberID); err != nil || meter.UsedBytes != 3 {
				t.Fatalf("operation changed accounting: %+v %v", meter, err)
			}
			if _, err := os.Stat(filepath.Join(f.pathA, filepath.FromSlash(name))); !os.IsNotExist(err) {
				t.Fatalf("replacement disk inherited original content: %v", err)
			}
		})
	}
}

func TestDAVReplacementTrashPurgesAndRestoresExactVersion(t *testing.T) {
	f := newRootRoutingFixture(t)
	category := assignFixtureMemberStorage(t, f)
	name := category + "/photo.jpg"
	base := rootRoute(f.rootA.ID, "")
	if r := f.call(f.member, http.MethodPut, base+"/files/content?path="+name, "old"); r.Code != http.StatusCreated {
		t.Fatalf("upload: %d %s", r.Code, r.Body.String())
	}
	_, password, err := f.accounts.CreateDAVCredential(f.member, "replacement-test")
	if err != nil {
		t.Fatal(err)
	}
	dav := "/dav-roots/" + f.rootA.ID + "/" + strconv.FormatUint(f.rootA.Generation, 10) + "/"
	write := func(method, relative, body, destination string) {
		t.Helper()
		request := httptest.NewRequest(method, dav+relative, strings.NewReader(body))
		request.SetBasicAuth("member", password)
		if destination != "" {
			request.Header.Set("Destination", dav+destination)
		}
		recorder := httptest.NewRecorder()
		f.server.ServeHTTP(recorder, request)
		if recorder.Code < 200 || recorder.Code >= 300 {
			t.Fatalf("DAV %s: %d %s", method, recorder.Code, recorder.Body.String())
		}
	}
	listID := func() string {
		t.Helper()
		result := f.call(f.member, http.MethodGet, base+"/files/trash", "")
		var listing struct{ Entries []files.TrashEntry }
		if err := json.Unmarshal(result.Body.Bytes(), &listing); err != nil || len(listing.Entries) != 1 {
			t.Fatalf("trash listing: %s %v", result.Body.String(), err)
		}
		return listing.Entries[0].ID
	}
	write(http.MethodPut, name, "second", "")
	if r := f.call(f.member, http.MethodDelete, base+"/files/trash/"+listID(), ""); r.Code != http.StatusOK {
		t.Fatalf("purge old version: %d %s", r.Code, r.Body.String())
	}
	write(http.MethodPut, name, "new", "")
	id := listID()
	write("MOVE", name, "", category+"/renamed.jpg")
	if r := f.call(f.member, http.MethodPost, base+"/files/trash/"+id+"/restore", ""); r.Code != http.StatusOK {
		t.Fatalf("restore old version: %d %s", r.Code, r.Body.String())
	}
	content, err := os.ReadFile(filepath.Join(f.pathA, filepath.FromSlash(name)))
	if err != nil || string(content) != "second" {
		t.Fatalf("restored wrong version: %q %v", content, err)
	}
	meter, err := f.accounts.StorageMeter(f.admin, f.memberID)
	if err != nil || meter.UsedBytes != 9 || meter.ReservedBytes != 0 {
		t.Fatalf("restored/purged quota: %+v %v", meter, err)
	}
}

func TestBatchTrashStopsAfterRootSwap(t *testing.T) {
	f := newRootRoutingFixture(t)
	category := assignFixtureMemberStorage(t, f)
	base := rootRoute(f.rootA.ID, "")
	names := []string{category + "/one.txt", category + "/two.txt"}
	for _, name := range names {
		if r := f.call(f.member, http.MethodPut, base+"/files/content?path="+name, "abc"); r.Code != http.StatusCreated {
			t.Fatalf("upload: %d %s", r.Code, r.Body.String())
		}
	}
	service := f.services[f.rootA.ID]
	service.Files = &detachAfterTrashChangeFiles{Access: service.Files, detach: func() {
		if err := os.Rename(f.pathA, f.pathA+"-detached"); err != nil {
			t.Fatal(err)
		}
		if err := os.Mkdir(f.pathA, 0700); err != nil {
			t.Fatal(err)
		}
	}}
	body, _ := json.Marshal(map[string]any{"action": "trash", "paths": names})
	response := f.call(f.member, http.MethodPost, base+"/files/batch", string(body))
	var result struct {
		Results []struct {
			Success bool   `json:"success"`
			Error   string `json:"error"`
		} `json:"results"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &result); response.Code != http.StatusOK || err != nil || len(result.Results) != 2 ||
		result.Results[0].Success || result.Results[0].Error != "storage_operation_uncertain" ||
		result.Results[1].Success || result.Results[1].Error != "root_unavailable" {
		t.Fatalf("incorrect partial result: %d %s (%v)", response.Code, response.Body.String(), err)
	}
	if data, err := os.ReadFile(filepath.Join(f.pathA+"-detached", filepath.FromSlash(names[1]))); err != nil || string(data) != "abc" {
		t.Fatalf("batch continued on detached root: %q %v", data, err)
	}
}

type changedTrashFiles struct {
	files.Access
	calls int
}

func (f *changedTrashFiles) MoveToTrash(name string) error {
	f.calls++
	if f.calls == 1 {
		if err := f.Access.MoveToTrash(name); err != nil {
			return err
		}
		return files.ErrTrashChanged
	}
	return f.Access.MoveToTrash(name)
}

func TestBatchTrashStopsWhenObjectIdentityChanges(t *testing.T) {
	f := newRootRoutingFixture(t)
	category := assignFixtureMemberStorage(t, f)
	base := rootRoute(f.rootA.ID, "")
	names := []string{category + "/one.txt", category + "/two.txt"}
	for _, name := range names {
		if r := f.call(f.member, http.MethodPut, base+"/files/content?path="+name, "abc"); r.Code != http.StatusCreated {
			t.Fatalf("upload: %d %s", r.Code, r.Body.String())
		}
	}
	service := f.services[f.rootA.ID]
	changed := &changedTrashFiles{Access: service.Files}
	service.Files = changed
	body, _ := json.Marshal(map[string]any{"action": "trash", "paths": names})
	response := f.call(f.member, http.MethodPost, base+"/files/batch", string(body))
	var result struct {
		Results []struct {
			Success bool   `json:"success"`
			Error   string `json:"error"`
		} `json:"results"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &result); response.Code != http.StatusOK || err != nil || len(result.Results) != 2 ||
		result.Results[0].Success || result.Results[0].Error != "trash_item_changed" ||
		result.Results[1].Success || result.Results[1].Error != "operation_not_started" || changed.calls != 1 {
		t.Fatalf("incorrect partial result: %d %s (%v)", response.Code, response.Body.String(), err)
	}
	if data, err := os.ReadFile(filepath.Join(f.pathA, filepath.FromSlash(names[1]))); err != nil || string(data) != "abc" {
		t.Fatalf("batch continued after identity change: %q %v", data, err)
	}
}

func (f *detachAfterPurgeFiles) Purge(id string) error {
	if err := f.Access.Purge(id); err != nil {
		return err
	}
	f.detach()
	return nil
}

func TestSharedTrashPurgeDuringRootSwapDoesNotReportSuccess(t *testing.T) {
	f := newRootRoutingFixture(t)
	name := "shared.txt"
	if response := f.call(f.admin, http.MethodPut, rootRoute(f.rootA.ID, "/files/content?path="+name), "abc"); response.Code != http.StatusCreated {
		t.Fatalf("upload: %d %s", response.Code, response.Body.String())
	}
	if response := f.call(f.admin, http.MethodDelete, rootRoute(f.rootA.ID, "/files?path="+name), ""); response.Code != http.StatusOK {
		t.Fatalf("trash: %d %s", response.Code, response.Body.String())
	}
	listing := f.call(f.admin, http.MethodGet, rootRoute(f.rootA.ID, "/files/trash"), "")
	var result struct {
		Entries []files.TrashEntry `json:"entries"`
	}
	if err := json.Unmarshal(listing.Body.Bytes(), &result); listing.Code != http.StatusOK || err != nil || len(result.Entries) != 1 {
		t.Fatalf("trash listing: %d %s (%v)", listing.Code, listing.Body.String(), err)
	}
	service := f.services[f.rootA.ID]
	service.Files = &detachAfterPurgeFiles{Access: service.Files, detach: func() {
		if err := os.Rename(f.pathA, f.pathA+"-detached"); err != nil {
			t.Fatal(err)
		}
		if err := os.Mkdir(f.pathA, 0700); err != nil {
			t.Fatal(err)
		}
	}}
	response := f.call(f.admin, http.MethodDelete, rootRoute(f.rootA.ID, "/files/trash/"+result.Entries[0].ID), "")
	if response.Code != http.StatusServiceUnavailable || !strings.Contains(response.Body.String(), "storage_operation_uncertain") {
		t.Fatalf("detached purge was reported successful: %d %s", response.Code, response.Body.String())
	}
}

func TestSharedUploadDuringRootSwapNeverReportsSuccess(t *testing.T) {
	f := newRootRoutingFixture(t)
	root := f.rootA
	initial := f.call(f.admin, http.MethodGet, rootRoute(root.ID, "/files"), "")
	if initial.Code != http.StatusOK {
		t.Fatalf("initialize pinned shared root: %d %s", initial.Code, initial.Body.String())
	}
	_, detached := attachDetachingTestManager(t, f)
	result := f.call(f.admin, http.MethodPut, rootRoute(root.ID, "/files/content?path=family.txt"), "family")
	if result.Code != http.StatusServiceUnavailable ||
		!strings.Contains(result.Body.String(), "root_unavailable") {
		t.Fatalf("swapped shared root was reported uploaded: %d %s", result.Code, result.Body.String())
	}
	if data, err := os.ReadFile(filepath.Join(detached, "family.txt")); err != nil || string(data) != "family" {
		t.Fatalf("original shared root was modified or lost: %q %v", data, err)
	}
	if _, err := os.Stat(filepath.Join(f.pathA, "family.txt")); !os.IsNotExist(err) {
		t.Fatalf("replacement path inherited original shared file: %v", err)
	}
}

func TestSharedCopyDuringRootSwapNeverReportsSuccess(t *testing.T) {
	f := newRootRoutingFixture(t)
	root := f.rootA
	if err := os.WriteFile(filepath.Join(f.pathA, "old.txt"), []byte("source"), 0600); err != nil {
		t.Fatal(err)
	}
	initial := f.call(f.admin, http.MethodGet, rootRoute(root.ID, "/files"), "")
	if initial.Code != http.StatusOK {
		t.Fatalf("initialize shared root: %d %s", initial.Code, initial.Body.String())
	}
	_, detached := attachDetachingTestManager(t, f)
	result := f.call(f.admin, http.MethodPost, rootRoute(root.ID, "/files/operations"),
		`{"action":"copy","from":"old.txt","to":"new.txt"}`)
	if result.Code != http.StatusServiceUnavailable || !strings.Contains(result.Body.String(), "root_unavailable") {
		t.Fatalf("swapped shared root copy returned success: %d %s", result.Code, result.Body.String())
	}
	if data, err := os.ReadFile(filepath.Join(detached, "new.txt")); err != nil || string(data) != "source" {
		t.Fatalf("source root lost published copy: %q %v", data, err)
	}
	if _, err := os.Stat(filepath.Join(f.pathA, "new.txt")); !os.IsNotExist(err) {
		t.Fatalf("replacement path inherited old shared copy: %v", err)
	}
}

func TestPersonalChunkedFinishDuringRootSwapKeepsQuotaReservation(t *testing.T) {
	f := newRootRoutingFixture(t)
	root := f.rootA
	category := assignFixtureMemberStorage(t, f)
	_, detached := attachDetachingTestManager(t, f)
	path := category + "/chunked.bin"
	initial := f.call(f.member, http.MethodPost, rootRoute(root.ID, "/uploads"),
		`{"path":"`+path+`","size":3}`)
	if initial.Code != http.StatusCreated {
		t.Fatalf("begin chunked upload: %d %s", initial.Code, initial.Body.String())
	}
	var stage struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(initial.Body.Bytes(), &stage); err != nil || stage.ID == "" {
		t.Fatalf("invalid upload session: %+v %v", stage, err)
	}
	chunk := httptest.NewRequest(http.MethodPatch, rootRoute(root.ID, "/uploads/"+stage.ID),
		strings.NewReader("abc"))
	chunk.Header.Set("X-LightIsle-Request", "1")
	chunk.Header.Set(rootGenerationHeader, strconv.FormatUint(root.Generation, 10))
	chunk.Header.Set("X-Upload-Offset", "0")
	chunk.AddCookie(&http.Cookie{Name: sessionCookie, Value: f.member})
	result := httptest.NewRecorder()
	f.server.ServeHTTP(result, chunk)
	if result.Code != http.StatusOK {
		t.Fatalf("chunk upload: %d %s", result.Code, result.Body.String())
	}
	complete := f.call(f.member, http.MethodPost,
		rootRoute(root.ID, "/uploads/"+stage.ID+"/complete"), "")
	if complete.Code != http.StatusInternalServerError ||
		!strings.Contains(complete.Body.String(), "storage_accounting_uncertain") {
		t.Fatalf("root swap marked staged upload complete: %d %s", complete.Code, complete.Body.String())
	}
	meter, err := f.accounts.StorageMeter(f.admin, f.memberID)
	if err != nil || meter.UsedBytes != 0 || meter.ReservedBytes != 3 {
		t.Fatalf("staged upload reserved bytes were released: %+v %v", meter, err)
	}
	if content, err := os.ReadFile(filepath.Join(detached, filepath.FromSlash(path))); err != nil || string(content) != "abc" {
		t.Fatalf("published chunked bytes missing from detached original: %q %v", content, err)
	}
}

func TestAccountedCopyDuringRootSwapKeepsQuotaReservation(t *testing.T) {
	f := newRootRoutingFixture(t)
	root := f.rootA
	category := assignFixtureMemberStorage(t, f)
	if err := os.WriteFile(filepath.Join(f.pathA, "source.txt"), []byte("copy me"), 0600); err != nil {
		t.Fatal(err)
	}
	_, detached := attachDetachingTestManager(t, f)
	path := category + "/copied.txt"
	body := `{"action":"copy","from":"source.txt","to":"` + path + `"}`
	result := f.call(f.admin, http.MethodPost, rootRoute(root.ID, "/files/operations"), body)
	if result.Code != http.StatusInternalServerError ||
		!strings.Contains(result.Body.String(), "storage_accounting_uncertain") {
		t.Fatalf("root swap marked copy accounted: %d %s", result.Code, result.Body.String())
	}
	meter, err := f.accounts.StorageMeter(f.admin, f.memberID)
	if err != nil || meter.UsedBytes != 0 || meter.ReservedBytes != 7 {
		t.Fatalf("copy reserved bytes were lost: %+v %v", meter, err)
	}
	if content, err := os.ReadFile(filepath.Join(detached, filepath.FromSlash(path))); err != nil || string(content) != "copy me" {
		t.Fatalf("published copy missing from detached original: %q %v", content, err)
	}
}

func (f *detachAfterPublishFiles) FinishUpload(id string, owner int64) error {
	err := f.Access.FinishUpload(id, owner)
	if err == nil {
		f.detach()
	}
	return err
}

func (f *detachAfterPublishFiles) CopyContextWithOptions(ctx context.Context, from, to, policy string) (string, bool, error) {
	copyWithOptions, ok := f.Access.(interface {
		CopyContextWithOptions(context.Context, string, string, string) (string, bool, error)
	})
	if !ok {
		return "", false, files.ErrType
	}
	name, skipped, err := copyWithOptions.CopyContextWithOptions(ctx, from, to, policy)
	if err == nil && !skipped {
		f.detach()
	}
	return name, skipped, err
}

func attachDetachingTestManager(t *testing.T, f *rootRoutingFixture) (string, string) {
	t.Helper()
	path := f.pathA
	detached := path + "-disconnected"
	service := f.services[f.rootA.ID]
	if service == nil || service.Files == nil {
		t.Fatal("root services were not constructed")
	}
	service.Files = &detachAfterPublishFiles{
		Access: service.Files,
		detach: func() {
			if err := os.Rename(path, detached); err != nil {
				t.Fatal(err)
			}
			if err := os.Mkdir(path, 0700); err != nil {
				t.Fatal(err)
			}
		},
	}
	return path, detached
}

func assignFixtureMemberStorage(t *testing.T, f *rootRoutingFixture) string {
	t.Helper()
	root := f.rootA
	category := "Users/u" + strconv.FormatInt(f.memberID, 10) + "/files"
	assign := f.call(f.admin, http.MethodPut,
		rootRoute(root.ID, "/users/"+strconv.FormatInt(f.memberID, 10)+"/storage/files"), "")
	if assign.Code != http.StatusOK {
		t.Fatalf("assign storage: %d %s", assign.Code, assign.Body.String())
	}
	return category
}

func (f *detachAfterPublishFiles) Upload(path string, source io.Reader) (int64, error) {
	n, err := f.Access.Upload(path, source)
	if err == nil {
		f.detach()
	}
	return n, err
}

func TestPersonalUploadPublishedDuringRootSwapKeepsQuotaReservation(t *testing.T) {
	f := newRootRoutingFixture(t)
	root := f.rootA
	category := assignFixtureMemberStorage(t, f)
	_, detached := attachDetachingTestManager(t, f)
	file := category + "/original.jpg"
	result := f.call(f.member, http.MethodPut, rootRoute(root.ID, "/files/content?path="+file), "source bytes")
	if result.Code != http.StatusInternalServerError ||
		!strings.Contains(result.Body.String(), "storage_accounting_uncertain") {
		t.Fatalf("stale disk upload falsely succeeded: %d %s", result.Code, result.Body.String())
	}
	used, err := f.accounts.StorageMeter(f.admin, f.memberID)
	if err != nil || used.UsedBytes != 0 || used.ReservedBytes != int64(len("source bytes")) {
		t.Fatalf("detached publication cleared potentially live bytes: %+v %v", used, err)
	}
	data, err := os.ReadFile(filepath.Join(detached, filepath.FromSlash(file)))
	if err != nil || string(data) != "source bytes" {
		t.Fatalf("pinned original folder lost its file: %q %v", data, err)
	}
	if _, err := os.Stat(filepath.Join(f.pathA, filepath.FromSlash(file))); !os.IsNotExist(err) {
		t.Fatalf("replacement folder inherited old data: %v", err)
	}
	response := f.call(f.member, http.MethodGet, rootRoute(root.ID, "/files/content?path="+file), "")
	if response.Code == http.StatusOK {
		t.Fatalf("root registry followed impostor directory after swap: %d", response.Code)
	}
}
