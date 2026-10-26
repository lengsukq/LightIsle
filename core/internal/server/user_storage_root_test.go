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

func TestRootBoundPersonalStorageAssignmentRequiresAdminAndGeneration(t *testing.T) {
	base := t.TempDir()
	volume := filepath.Join(base, "volume")
	dataDir := filepath.Join(base, "private")
	rootPath := filepath.Join(volume, "family")
	for _, name := range []string{volume, dataDir, rootPath} {
		if err := os.Mkdir(name, 0700); err != nil {
			t.Fatal(err)
		}
	}
	registry, err := roots.OpenWithProvider(dataDir, rootRoutingProvider{}, volume)
	if err != nil {
		t.Fatal(err)
	}
	root, err := registry.Add(context.Background(), "Family", rootPath)
	if err != nil {
		t.Fatal(err)
	}
	store, err := auth.Open(filepath.Join(dataDir, "accounts.sqlite"))
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
	server := NewWithRoots("", store, nil, nil, nil, nil, registry, func(_ context.Context, _ roots.Root, lease *roots.Lease) (*RootServices, error) {
		manager, err := files.NewPinnedManager(lease.Root)
		if err != nil {
			return nil, err
		}
		return &RootServices{Files: manager}, nil
	})
	defer server.Close()
	endpoint := "/api/v2/roots/" + root.ID + "/users/" + strconv.FormatInt(member.ID, 10) + "/storage/photos"
	call := func(session, gen string, guard bool) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodPut, endpoint, strings.NewReader(""))
		if session != "" {
			r.AddCookie(&http.Cookie{Name: sessionCookie, Value: session})
		}
		if gen != "" {
			r.Header.Set(rootGenerationHeader, gen)
		}
		if guard {
			r.Header.Set("X-LightIsle-Request", "1")
		}
		w := httptest.NewRecorder()
		server.ServeHTTP(w, r)
		return w
	}
	if got := call(admin, "", true); got.Code != http.StatusPreconditionRequired {
		t.Fatalf("missing generation returned %d: %s", got.Code, got.Body.String())
	}
	if got := call(admin, "999", true); got.Code != http.StatusConflict {
		t.Fatalf("stale generation returned %d: %s", got.Code, got.Body.String())
	}
	current := strconv.FormatUint(root.Generation, 10)
	if got := call(memberSession, current, true); got.Code != http.StatusNotFound && got.Code != http.StatusForbidden {
		t.Fatalf("member assigned private root path: %d %s", got.Code, got.Body.String())
	}
	if got := call(admin, current, false); got.Code != http.StatusForbidden {
		t.Fatalf("missing CSRF guard returned %d: %s", got.Code, got.Body.String())
	}
	got := call(admin, current, true)
	if got.Code != http.StatusOK {
		t.Fatalf("root-bound assignment failed: %d %s", got.Code, got.Body.String())
	}
	var result struct {
		Location    auth.StorageLocation `json:"location"`
		Enforcement string               `json:"enforcement"`
	}
	if err := json.Unmarshal(got.Body.Bytes(), &result); err != nil ||
		result.Enforcement != "pending" || result.Location.RootID != root.ID ||
		result.Location.RootGeneration != root.Generation || result.Location.RelativePath != "Users/u2/photos" {
		t.Fatalf("wrong draft root-bound location: %+v %v", result, err)
	}
	if info, err := os.Stat(filepath.Join(rootPath, "Users", "u2", "photos")); err != nil || !info.IsDir() {
		t.Fatalf("personal folder was not provisioned: %v", err)
	}
	if !store.CanAccessRoot(memberSession, root.ID, "Users/u2/photos", true, false) {
		t.Fatal("new member could not write its assigned personal folder")
	}
	if store.CanAccessRoot(memberSession, root.ID, "Users/u3/photos", false, false) {
		t.Fatal("member could access another user personal folder")
	}
}
