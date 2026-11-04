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
	var stage struct { ID string `json:"id"` }
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
	body := `{"action":"copy","from":"source.txt","to":"`+path+`"}`
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
