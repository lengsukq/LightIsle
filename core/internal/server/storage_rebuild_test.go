package server

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/roots"
)

func TestHomeStorageRebuildRequiresRootRemovalAndPreservesOldDiskFiles(t *testing.T) {
	base := t.TempDir()
	volume := filepath.Join(base, "volume")
	private := filepath.Join(base, "private")
	oldPath := filepath.Join(volume, "old")
	newPath := filepath.Join(volume, "new")
	for _, dir := range []string{volume, private, oldPath, newPath} {
		if err := os.Mkdir(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	registry, err := roots.OpenWithProvider(private, rootRoutingProvider{}, volume)
	if err != nil {
		t.Fatal(err)
	}
	oldRoot, err := registry.Add(context.Background(), "broken disk", oldPath)
	if err != nil {
		t.Fatal(err)
	}
	newRoot, err := registry.Add(context.Background(), "new disk", newPath)
	if err != nil {
		t.Fatal(err)
	}
	accounts, err := auth.Open(filepath.Join(private, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("owner", "owner-storage-password-2026"); err != nil {
		t.Fatal(err)
	}
	admin, err := accounts.Login("owner", "owner-storage-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	user, err := accounts.CreateUser(admin, "member", "member-storage-password-2026", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	member, err := accounts.Login("member", "member-storage-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := accounts.AssignUserStorage(admin, user.ID, auth.StorageFiles, oldRoot.ID, oldRoot.Generation); err != nil {
		t.Fatal(err)
	}
	categoryDir := "Users/u" + strconv.FormatInt(user.ID, 10) + "/files"
	oldFile := filepath.Join(oldPath, filepath.FromSlash(categoryDir), "keep.txt")
	if err := os.MkdirAll(filepath.Dir(oldFile), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(oldFile, []byte("original"), 0600); err != nil {
		t.Fatal(err)
	}
	res, tracked, err := accounts.ReserveStorageUpload(member, oldRoot.ID, oldRoot.Generation, categoryDir+"/keep.txt", 8)
	if err != nil || !tracked {
		t.Fatalf("old accounting: %v %v", tracked, err)
	}
	if err := accounts.CommitStorageReservation(res); err != nil {
		t.Fatal(err)
	}
	handler := NewWithRoots("", accounts, nil, nil, nil, nil, registry,
		func(_ context.Context, _ roots.Root, lease *roots.Lease) (*RootServices, error) {
			manager, err := files.NewPinnedManager(lease.Root)
			if err != nil {
				return nil, err
			}
			return &RootServices{Files: manager}, nil
		})
	defer handler.Close()
	endpoint := "/api/v2/storage/users/" + strconv.FormatInt(user.ID, 10) + "/categories/files/abandon"
	reset := func(session string, rootID string, gen uint64, confirm bool) *httptest.ResponseRecorder {
		payload, _ := json.Marshal(map[string]any{"rootID": rootID, "generation": gen, "confirm": confirm})
		r := httptest.NewRequest(http.MethodPost, endpoint, strings.NewReader(string(payload)))
		r.AddCookie(&http.Cookie{Name: sessionCookie, Value: session})
		r.Header.Set("X-LightIsle-Request", "1")
		r.Header.Set("Content-Type", "application/json")
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, r)
		return response
	}
	if got := reset(admin, oldRoot.ID, oldRoot.Generation, false); got.Code != http.StatusBadRequest {
		t.Fatalf("unconfirmed reset: %d %s", got.Code, got.Body.String())
	}
	if got := reset(member, oldRoot.ID, oldRoot.Generation, true); got.Code != http.StatusForbidden {
		t.Fatalf("member reset: %d %s", got.Code, got.Body.String())
	}
	if got := reset(admin, oldRoot.ID, oldRoot.Generation, true); got.Code != http.StatusConflict {
		t.Fatalf("online registered root was abandoned: %d %s", got.Code, got.Body.String())
	}
	if err := registry.Remove(oldRoot.ID); err != nil {
		t.Fatal(err)
	}
	if got := reset(admin, oldRoot.ID, oldRoot.Generation+1, true); got.Code != http.StatusConflict {
		t.Fatalf("stale generation reset: %d %s", got.Code, got.Body.String())
	}
	if got := reset(admin, oldRoot.ID, oldRoot.Generation, true); got.Code != http.StatusOK {
		t.Fatalf("removed root reset: %d %s", got.Code, got.Body.String())
	}
	if data, err := os.ReadFile(oldFile); err != nil || string(data) != "original" {
		t.Fatalf("abandon modified old disk file: %q %v", data, err)
	}
	policy, err := accounts.StoragePolicy(admin, user.ID)
	if err != nil || len(policy.Locations) != 0 || policy.AccountedBytes != 0 || policy.ReservedBytes != 0 {
		t.Fatalf("old storage binding still charged: %+v %v", policy, err)
	}
	// Adding the old physical directory again creates a DIFFERENT root ID.
	// Never silently adopt its surviving files as a fresh zero-byte quota.
	readded, err := registry.Add(context.Background(), "old disk again", oldPath)
	if err != nil {
		t.Fatal(err)
	}
	preexisting := httptest.NewRequest("PUT", "/api/v2/roots/"+readded.ID+"/users/"+strconv.FormatInt(user.ID, 10)+"/storage/files", nil)
	preexisting.AddCookie(&http.Cookie{Name: sessionCookie, Value: admin})
	preexisting.Header.Set(rootGenerationHeader, strconv.FormatUint(readded.Generation, 10))
	preexisting.Header.Set("X-LightIsle-Request", "1")
	preexistingResponse := httptest.NewRecorder()
	handler.ServeHTTP(preexistingResponse, preexisting)
	if preexistingResponse.Code != http.StatusConflict || !strings.Contains(preexistingResponse.Body.String(), "storage_folder_not_empty") {
		t.Fatalf("unaccounted old files silently adopted: %d %s", preexistingResponse.Code, preexistingResponse.Body.String())
	}
	r := httptest.NewRequest("PUT", "/api/v2/roots/"+newRoot.ID+"/users/"+strconv.FormatInt(user.ID, 10)+"/storage/files", nil)
	r.AddCookie(&http.Cookie{Name: sessionCookie, Value: admin})
	r.Header.Set(rootGenerationHeader, strconv.FormatUint(newRoot.Generation, 10))
	r.Header.Set("X-LightIsle-Request", "1")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, r)
	if response.Code != http.StatusOK {
		t.Fatalf("new storage space not created: %d %s", response.Code, response.Body.String())
	}
	if info, err := os.Stat(filepath.Join(newPath, filepath.FromSlash(categoryDir))); err != nil || !info.IsDir() {
		t.Fatalf("new space missing: %v", err)
	}
	policy, err = accounts.StoragePolicy(admin, user.ID)
	if err != nil || len(policy.Locations) != 1 || policy.Locations[0].RootID != newRoot.ID {
		t.Fatalf("new space not assigned: %+v %v", policy, err)
	}
}
