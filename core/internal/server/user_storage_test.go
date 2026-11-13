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

func TestUserStorageQuotaAPIIsAdminOnlyAndExplicitlyUnenforced(t *testing.T) {
	store, err := auth.Open(filepath.Join(t.TempDir(), "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.Setup("owner", "owner-strong-password-2026"); err != nil {
		t.Fatal(err)
	}
	admin, err := store.Login("owner", "owner-strong-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	member, err := store.CreateUser(admin, "family", "family-strong-password-2026", auth.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	memberSession, err := store.Login("family", "family-strong-password-2026")
	if err != nil {
		t.Fatal(err)
	}
	const rootID = "11111111111111111111111111111111"
	if _, err := store.AssignUserStorage(admin, member.ID, auth.StorageFiles, rootID, 3); err != nil {
		t.Fatal(err)
	}
	h := New("", store, nil)
	base := "/api/v2/users/" + strconv.FormatInt(member.ID, 10) + "/storage"
	perRoot := base + "/roots/" + rootID + "/quota"
	call := func(method, path, session, body string, withOriginGuard bool) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, path, strings.NewReader(body))
		if withOriginGuard {
			r.Header.Set("X-LightIsle-Request", "1")
		}
		if session != "" {
			r.AddCookie(&http.Cookie{Name: sessionCookie, Value: session})
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	for _, tc := range []struct {
		path, session, body string
		guard               bool
		want                int
	}{
		{perRoot, "", `{"quotaBytes":1000,"generation":3}`, true, 401},
		{perRoot, memberSession, `{"quotaBytes":1000,"generation":3}`, true, 403},
		{perRoot, admin, `{"quotaBytes":1000,"generation":3}`, false, 403},
		{perRoot, admin, `{"quotaBytes":1000}`, true, 400},
		{perRoot, admin, `{"quotaBytes":1000,"generation":4}`, true, 409},
		{perRoot, admin, `{"quotaBytes":-1,"generation":3}`, true, 400},
	} {
		response := call(http.MethodPut, tc.path, tc.session, tc.body, tc.guard)
		if response.Code != tc.want {
			t.Fatalf("%s got %d want %d: %s", tc.path, response.Code, tc.want, response.Body.String())
		}
	}
	unauthorized := call(http.MethodGet, base, memberSession, "", false)
	if unauthorized.Code != 403 {
		t.Fatalf("member listed another user's administrator endpoint: %d", unauthorized.Code)
	}
	self := call(http.MethodGet, "/api/v2/me/storage", memberSession, "", false)
	if self.Code != 200 {
		t.Fatalf("member cannot see own quota: %d %s", self.Code, self.Body.String())
	}
	var policy auth.StoragePolicy
	if err := json.Unmarshal(self.Body.Bytes(), &policy); err != nil || policy.QuotaBytes != nil ||
		len(policy.RootQuotas) != 1 || policy.RootQuotas[0].QuotaBytes == nil ||
		*policy.RootQuotas[0].QuotaBytes != auth.DefaultMemberQuotaBytes || policy.Enforcement != "pending" {
		t.Fatalf("default quota or pending status misreported: %+v %v", policy, err)
	}
	updated := call(http.MethodPut, perRoot, admin, `{"quotaBytes":21474836480,"generation":3}`, true)
	if updated.Code != 200 {
		t.Fatalf("admin failed to configure quota: %d %s", updated.Code, updated.Body.String())
	}
	if err := json.Unmarshal(updated.Body.Bytes(), &policy); err != nil || policy.QuotaBytes != nil ||
		len(policy.RootQuotas) != 1 || policy.RootQuotas[0].QuotaBytes == nil ||
		*policy.RootQuotas[0].QuotaBytes != 20<<30 || policy.Enforcement != "pending" {
		t.Fatalf("quota setting misreported actual enforcement: %+v %v", policy, err)
	}
}

func TestAllocateUserStorageSpaceAndAddDirectoriesAndModifyQuotaAPI(t *testing.T) {
	base := t.TempDir()
	volume := filepath.Join(base, "volume")
	private := filepath.Join(base, "private")
	diskPath := filepath.Join(volume, "disk1")
	for _, dir := range []string{volume, private, diskPath} {
		if err := os.Mkdir(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	registry, err := roots.OpenWithProvider(private, rootRoutingProvider{}, volume)
	if err != nil {
		t.Fatal(err)
	}
	disk, err := registry.Add(context.Background(), "Family Disk", diskPath)
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
	handler := NewWithRoots("", accounts, nil, nil, nil, nil, registry,
		func(_ context.Context, _ roots.Root, lease *roots.Lease) (*RootServices, error) {
			manager, err := files.NewPinnedManager(lease.Root)
			if err != nil {
				return nil, err
			}
			return &RootServices{Files: manager}, nil
		})
	defer handler.Close()

	uid := strconv.FormatInt(user.ID, 10)
	genStr := strconv.FormatUint(disk.Generation, 10)
	call := func(method, path, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, path, strings.NewReader(body))
		r.AddCookie(&http.Cookie{Name: sessionCookie, Value: admin})
		r.Header.Set("X-LightIsle-Request", "1")
		r.Header.Set(rootGenerationHeader, genStr)
		if body != "" {
			r.Header.Set("Content-Type", "application/json")
		}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}

	// 1. Allocate space with initial 200 GiB quota + files directory + custom subdirectory.
	quota200 := int64(200 << 30)
	allocResp := call(http.MethodPost, "/api/v2/roots/"+disk.ID+"/users/"+uid+"/storage",
		`{"quotaBytes":`+strconv.FormatInt(quota200, 10)+`,"categories":["files"],"subdirectories":["files/文档资料"]}`)
	if allocResp.Code != http.StatusOK {
		t.Fatalf("allocate space failed: %d %s", allocResp.Code, allocResp.Body.String())
	}
	if info, err := os.Stat(filepath.Join(diskPath, "Users", "u"+uid, "files", "文档资料")); err != nil || !info.IsDir() {
		t.Fatalf("expected subdirectory created on disk: %v", err)
	}

	// 2. Add photos category later via PUT without quotaBytes; 200 GiB quota must remain intact.
	addPhotos := call(http.MethodPut, "/api/v2/roots/"+disk.ID+"/users/"+uid+"/storage/photos", "")
	if addPhotos.Code != http.StatusOK {
		t.Fatalf("add photos category failed: %d %s", addPhotos.Code, addPhotos.Body.String())
	}
	var addPhotosPayload struct {
		Policy auth.StoragePolicy `json:"policy"`
	}
	if err := json.Unmarshal(addPhotos.Body.Bytes(), &addPhotosPayload); err != nil ||
		len(addPhotosPayload.Policy.Locations) != 2 ||
		len(addPhotosPayload.Policy.RootQuotas) != 1 ||
		addPhotosPayload.Policy.RootQuotas[0].QuotaBytes == nil ||
		*addPhotosPayload.Policy.RootQuotas[0].QuotaBytes != quota200 {
		t.Fatalf("expected 200GiB quota preserved after adding photos: %+v %v", addPhotosPayload, err)
	}

	// 3. Freely modify quota to 350 GiB via PUT /api/v2/users/{id}/storage/roots/{rootID}/quota.
	quota350 := int64(350 << 30)
	modQuota := call(http.MethodPut, "/api/v2/users/"+uid+"/storage/roots/"+disk.ID+"/quota",
		`{"quotaBytes":`+strconv.FormatInt(quota350, 10)+`,"generation":`+genStr+`}`)
	if modQuota.Code != http.StatusOK {
		t.Fatalf("modify quota failed: %d %s", modQuota.Code, modQuota.Body.String())
	}
	var policy auth.StoragePolicy
	if err := json.Unmarshal(modQuota.Body.Bytes(), &policy); err != nil ||
		len(policy.RootQuotas) != 1 || policy.RootQuotas[0].QuotaBytes == nil ||
		*policy.RootQuotas[0].QuotaBytes != quota350 {
		t.Fatalf("expected 350GiB quota after modification: %+v %v", policy, err)
	}
}
