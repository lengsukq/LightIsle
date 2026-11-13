package server

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/apps"
	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/automation"
	"github.com/lengsukq/lightisle/core/internal/storageidentity"
)

type stubServerStorageProvider struct {
	offline bool
}

func (s *stubServerStorageProvider) Capture(_ context.Context, path string) (storageidentity.Binding, error) {
	return storageidentity.Binding{Path: filepath.Clean(path), VolumeUUID: "server-test-uuid"}, nil
}

func (s *stubServerStorageProvider) Verify(_ context.Context, _ storageidentity.Binding) error {
	if s.offline {
		return os.ErrNotExist
	}
	return nil
}

func TestAppsStorageHTTPRoutes(t *testing.T) {
	dataDir := t.TempDir()
	extPrefix := t.TempDir()
	extVol := filepath.Join(extPrefix, "MediaUSB")
	extDir := filepath.Join(extVol, "LightIsleApps")
	if err := os.MkdirAll(extVol, 0700); err != nil {
		t.Fatal(err)
	}

	accounts, err := auth.Open(filepath.Join(dataDir, "accounts.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer accounts.Close()
	if err := accounts.Setup("owner", "owner-password-12345"); err != nil {
		t.Fatal(err)
	}
	adminTok, err := accounts.Login("owner", "owner-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := accounts.CreateUser(adminTok, "alice", "alice-password-12345", auth.RoleMember); err != nil {
		t.Fatal(err)
	}
	memberTok, err := accounts.Login("alice", "alice-password-12345")
	if err != nil {
		t.Fatal(err)
	}

	autoMgr, err := automation.New(dataDir, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer autoMgr.Close()

	stub := &stubServerStorageProvider{}
	appsMgr := apps.NewManager(dataDir, "lightisled", autoMgr)
	defer appsMgr.Close()
	appsMgr.SetStoragePolicyForTesting(stub, []string{extPrefix})
	if err := appsMgr.Reload(); err != nil {
		t.Fatal(err)
	}

	handler := WithApps(New("", accounts, nil), "", accounts, appsMgr)
	call := func(method, path, session string, body any) *httptest.ResponseRecorder {
		t.Helper()
		var buf bytes.Buffer
		if body != nil {
			if err := json.NewEncoder(&buf).Encode(body); err != nil {
				t.Fatal(err)
			}
		}
		req := httptest.NewRequest(method, path, &buf)
		if session != "" {
			req.AddCookie(&http.Cookie{Name: sessionCookie, Value: session})
		}
		if method != http.MethodGet {
			req.Header.Set("X-LightIsle-Request", "1")
		}
		if body != nil {
			req.Header.Set("Content-Type", "application/json")
		}
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		return rec
	}

	// Member cannot access storage management endpoint.
	if rec := call("GET", "/api/v2/apps/storage", memberTok, nil); rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403 for member storage GET, got %d", rec.Code)
	}

	// Admin gets initial appStorage inside /api/v2/apps and /api/v2/apps/storage.
	rec := call("GET", "/api/v2/apps/storage", adminTok, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 GET /api/v2/apps/storage, got %d (%s)", rec.Code, rec.Body.String())
	}

	// Add external slot.
	rec = call("PUT", "/api/v2/apps/storage", adminTok, apps.AppStorageMutationRequest{
		Action: "add",
		Kind:   apps.AppStorageKindExternal,
		Path:   extDir,
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 adding external storage, got %d (%s)", rec.Code, rec.Body.String())
	}

	// Second add fails with 409 app_storage_slot_limit.
	rec = call("PUT", "/api/v2/apps/storage", adminTok, apps.AppStorageMutationRequest{
		Action: "add",
		Kind:   apps.AppStorageKindExternal,
		Path:   filepath.Join(extVol, "AnotherDir"),
	})
	if rec.Code != http.StatusConflict || !bytes.Contains(rec.Body.Bytes(), []byte("app_storage_slot_limit")) {
		t.Fatalf("expected 409 app_storage_slot_limit, got %d (%s)", rec.Code, rec.Body.String())
	}

	// Install template onto external location.
	rec = call("POST", "/api/v2/apps/templates/family-subscriptions/install", adminTok, map[string]string{
		"locationId": apps.AppStorageIDExternal,
	})
	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201 installing template to external, got %d (%s)", rec.Code, rec.Body.String())
	}
	var installResp struct {
		App apps.PublicApp `json:"app"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &installResp); err != nil {
		t.Fatal(err)
	}
	if installResp.App.LocationID != apps.AppStorageIDExternal {
		t.Fatalf("expected installed app on external location, got %q", installResp.App.LocationID)
	}

	// Offline external blocks installation without falling back.
	stub.offline = true
	rec = call("POST", "/api/v2/apps/templates/family-board/install", adminTok, map[string]string{
		"locationId": apps.AppStorageIDExternal,
	})
	if rec.Code != http.StatusConflict || !bytes.Contains(rec.Body.Bytes(), []byte("app_storage_offline")) {
		t.Fatalf("expected 409 app_storage_offline, got %d (%s)", rec.Code, rec.Body.String())
	}

	// Safe removal removes external slot without deleting files.
	rec = call("PUT", "/api/v2/apps/storage", adminTok, apps.AppStorageMutationRequest{
		Action: "remove_external",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 remove_external, got %d (%s)", rec.Code, rec.Body.String())
	}
	if _, err := os.Stat(filepath.Join(extDir, "plugins", "family-subscriptions", "plugin.json")); err != nil {
		t.Fatalf("expected external files untouched after remove_external: %v", err)
	}
}
