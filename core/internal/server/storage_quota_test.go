package server

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/roots"
)

func TestScopedQuotaDirectResumableAbortAndCommit(t *testing.T) {
	base := t.TempDir()
	volume := filepath.Join(base, "volume")
	private := filepath.Join(base, "private")
	folder := filepath.Join(volume, "share")
	for _, p := range []string{volume, private, folder} {
		if err := os.Mkdir(p, 0700); err != nil {
			t.Fatal(err)
		}
	}
	registry, err := roots.OpenWithProvider(private, rootRoutingProvider{}, volume)
	if err != nil {
		t.Fatal(err)
	}
	root, err := registry.Add(context.Background(), "Share", folder)
	if err != nil {
		t.Fatal(err)
	}
	accounts, err := auth.Open(filepath.Join(private, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("owner", "storage-owner-password-2026"); err != nil {
		t.Fatal(err)
	}
	admin, err := accounts.Login("owner", "storage-owner-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	member, err := accounts.CreateUser(admin, "family", "storage-member-password-2026", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	memberSession, err := accounts.Login("family", "storage-member-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	server := NewWithRoots("", accounts, nil, nil, nil, nil, registry,
		func(_ context.Context, _ roots.Root, lease *roots.Lease) (*RootServices, error) {
			manager, err := files.NewPinnedManager(lease.Root)
			if err != nil {
				return nil, err
			}
			return &RootServices{Files: manager}, nil
		})
	defer server.Close()
	baseURL := "/api/v2/roots/" + root.ID
	call := func(method, url, session string, body []byte, headers map[string]string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, url, bytes.NewReader(body))
		if session != "" {
			r.AddCookie(&http.Cookie{Name: sessionCookie, Value: session})
		}
		r.Header.Set(rootGenerationHeader, strconv.FormatUint(root.Generation, 10))
		r.Header.Set("X-LightIsle-Request", "1")
		for k, v := range headers {
			r.Header.Set(k, v)
		}
		w := httptest.NewRecorder()
		server.ServeHTTP(w, r)
		return w
	}
	assign := call("PUT", baseURL+"/users/"+strconv.FormatInt(member.ID, 10)+"/storage/files", admin, nil, nil)
	if assign.Code != 200 {
		t.Fatalf("assign failed %d: %s", assign.Code, assign.Body.String())
	}
	if err := accounts.SetUserStorageQuota(admin, member.ID, 5); err != nil {
		t.Fatal(err)
	}
	prefix := "Users/u" + strconv.FormatInt(member.ID, 10) + "/files/"
	url := func(name string) string { return baseURL + "/files/content?path=" + prefix + name }
	response := call("PUT", url("a.txt"), memberSession, []byte("one"), nil)
	if response.Code != 201 {
		t.Fatalf("direct upload: %d %s", response.Code, response.Body.String())
	}
	meter, err := accounts.StorageMeter(memberSession, member.ID)
	if err != nil || meter.UsedBytes != 3 || meter.ReservedBytes != 0 {
		t.Fatalf("direct accounting: %+v %v", meter, err)
	}
	response = call("PUT", url("oversize.txt"), memberSession, []byte("four"), nil)
	if response.Code != http.StatusInsufficientStorage {
		t.Fatalf("expected 507, got %d %s", response.Code, response.Body.String())
	}
	if _, err := os.Stat(filepath.Join(folder, filepath.FromSlash(prefix+"oversize.txt"))); !os.IsNotExist(err) {
		t.Fatalf("excess bytes reached disk: %v", err)
	}
	beginURL := baseURL + "/uploads"
	response = call("POST", beginURL, memberSession, []byte(`{"path":"`+prefix+`b.txt","size":2}`), nil)
	if response.Code != 201 {
		t.Fatalf("begin: %d %s", response.Code, response.Body.String())
	}
	var upload files.UploadState
	if err := json.Unmarshal(response.Body.Bytes(), &upload); err != nil {
		t.Fatal(err)
	}
	meter, err = accounts.StorageMeter(memberSession, member.ID)
	if err != nil || meter.UsedBytes != 3 || meter.ReservedBytes != 2 {
		t.Fatalf("begin reservation: %+v %v", meter, err)
	}
	response = call("POST", beginURL, memberSession, []byte(`{"path":"`+prefix+`c.txt","size":1}`), nil)
	if response.Code != http.StatusInsufficientStorage {
		t.Fatalf("concurrent excess begin allowed: %d %s", response.Code, response.Body.String())
	}
	response = call("DELETE", baseURL+"/uploads/"+upload.ID, memberSession, nil, nil)
	if response.Code != 200 {
		t.Fatalf("abort: %d %s", response.Code, response.Body.String())
	}
	meter, err = accounts.StorageMeter(memberSession, member.ID)
	if err != nil || meter.ReservedBytes != 0 {
		t.Fatalf("aborted bytes not released: %+v %v", meter, err)
	}
	response = call("POST", beginURL, memberSession, []byte(`{"path":"`+prefix+`b.txt","size":2}`), nil)
	if response.Code != 201 {
		t.Fatalf("retry begin: %d %s", response.Code, response.Body.String())
	}
	if err := json.Unmarshal(response.Body.Bytes(), &upload); err != nil {
		t.Fatal(err)
	}
	response = call("PATCH", baseURL+"/uploads/"+upload.ID, memberSession, []byte("ok"), map[string]string{"X-Upload-Offset": "0"})
	if response.Code != 200 {
		t.Fatalf("upload chunk: %d %s", response.Code, response.Body.String())
	}
	response = call("POST", baseURL+"/uploads/"+upload.ID+"/complete", memberSession, nil, nil)
	if response.Code != 200 {
		t.Fatalf("complete: %d %s", response.Code, response.Body.String())
	}
	meter, err = accounts.StorageMeter(admin, member.ID)
	if err != nil || meter.UsedBytes != 5 || meter.ReservedBytes != 0 || meter.AvailableBytes == nil || *meter.AvailableBytes != 0 {
		t.Fatalf("completed budget: %+v %v", meter, err)
	}
	response = call("PUT", url("no.txt"), admin, []byte("A"), nil)
	if response.Code != http.StatusInsufficientStorage {
		t.Fatalf("admin bypassed member quota: %d %s", response.Code, response.Body.String())
	}
	response = call("POST", baseURL+"/files/operations", memberSession, []byte(`{"action":"copy","from":"`+prefix+`a.txt","to":"`+prefix+`copy.txt"}`), nil)
	if response.Code != http.StatusInsufficientStorage {
		t.Fatalf("unmetered copy bypassed quota: %d %s", response.Code, response.Body.String())
	}
	response = call("DELETE", baseURL+"/files?path="+prefix+"a.txt", memberSession, nil, nil)
	if response.Code != 200 {
		t.Fatalf("trash: %d %s", response.Code, response.Body.String())
	}
	meter, err = accounts.StorageMeter(memberSession, member.ID)
	if err != nil || meter.UsedBytes != 5 {
		t.Fatalf("trash prematurely freed quota: %+v %v", meter, err)
	}
	response = call("GET", baseURL+"/files/trash", memberSession, nil, nil)
	if response.Code != 200 {
		t.Fatalf("trash listing failed: %d %s", response.Code, response.Body.String())
	}
	var listing struct {
		Entries []files.TrashEntry `json:"entries"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &listing); err != nil || len(listing.Entries) == 0 {
		t.Fatalf("missing trash entry: %v %s", err, response.Body.String())
	}
	var trashedID string
	for _, item := range listing.Entries {
		if item.OriginalPath == prefix+"a.txt" {
			trashedID = item.ID
		}
	}
	if trashedID == "" {
		t.Fatalf("missing original file in trash: %+v", listing.Entries)
	}
	response = call("DELETE", baseURL+"/files/trash/"+trashedID, admin, nil, nil)
	if response.Code != 200 {
		t.Fatalf("permanent purge: %d %s", response.Code, response.Body.String())
	}
	meter, err = accounts.StorageMeter(memberSession, member.ID)
	if err != nil || meter.UsedBytes != 2 {
		t.Fatalf("purge failed to free quota: %+v %v", meter, err)
	}
	response = call("PUT", url("reused.txt"), memberSession, []byte("new"), nil)
	if response.Code != 201 {
		t.Fatalf("purged capacity could not be reused: %d %s", response.Code, response.Body.String())
	}
}
