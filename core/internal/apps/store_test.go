package apps

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func repoPluginsStoreDir(t *testing.T) string {
	t.Helper()
	dir, err := filepath.Abs(filepath.Join("..", "..", "..", "plugins-store"))
	if err != nil {
		t.Fatalf("resolve plugins-store dir: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "registry.json")); err != nil {
		t.Fatalf("expected plugins-store/registry.json at %s: %v", dir, err)
	}
	return dir
}

func startLocalGitStoreServer(t *testing.T, storeDir string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.FileServer(http.Dir(storeDir)))
	t.Cleanup(srv.Close)
	return srv
}

func attachRepoStoreForTest(t *testing.T, mgr *Manager) *httptest.Server {
	t.Helper()
	srv := startLocalGitStoreServer(t, repoPluginsStoreDir(t))
	mgr.SetStoreTestConfigForTesting(srv.URL+"/registry.json", true)
	return srv
}

func installRepoStorePlugin(t *testing.T, mgr *Manager, id, locationID string) PublicApp {
	t.Helper()
	attachRepoStoreForTest(t, mgr)
	app, err := mgr.InstallStorePlugin(context.Background(), id, locationID)
	if err != nil {
		t.Fatalf("InstallStorePlugin(%s) failed: %v", id, err)
	}
	return app
}

func TestGitStoreRefreshInstallAndAll10OfficialPackages(t *testing.T) {
	storeDir := repoPluginsStoreDir(t)
	srv := startLocalGitStoreServer(t, storeDir)

	dataDir := t.TempDir()
	mgr := NewManager(dataDir, "", nil)
	defer mgr.Close()
	if err := mgr.Reload(); err != nil {
		t.Fatal(err)
	}
	// Fresh manager should have zero built-in hardcoded apps.
	if got := mgr.ListForUser(0, "admin"); len(got) != 0 {
		t.Fatalf("expected 0 preinstalled apps without store install, got %d", len(got))
	}

	mgr.SetStoreTestConfigForTesting(srv.URL+"/registry.json", true)

	snap, err := mgr.RefreshStore(context.Background())
	if err != nil {
		t.Fatalf("RefreshStore failed: %v", err)
	}
	if snap.Source != "remote" || len(snap.Plugins) != 10 {
		t.Fatalf("expected 10 store plugins from remote, got source=%s count=%d", snap.Source, len(snap.Plugins))
	}

	// Verify store icon proxy caches SVG with safe sandbox headers.
	iconRec := httptest.NewRecorder()
	iconReq := httptest.NewRequest(http.MethodGet, "/api/v2/apps/store/family-subscriptions/icon", nil)
	mgr.ServeStoreIcon(iconRec, iconReq, "family-subscriptions")
	if iconRec.Code != http.StatusOK || !strings.Contains(iconRec.Header().Get("Content-Type"), "image/svg+xml") {
		t.Fatalf("expected 200 SVG icon, got %d %s", iconRec.Code, iconRec.Header().Get("Content-Type"))
	}
	if !strings.Contains(iconRec.Header().Get("Content-Security-Policy"), "sandbox") {
		t.Fatalf("expected sandbox CSP on store icon, got %q", iconRec.Header().Get("Content-Security-Policy"))
	}

	reminderApps := map[string]bool{
		"family-subscriptions": true,
		"warranty-vault":       true,
		"medicine-expiry":      true,
		"weekly-menu":          true,
		"pet-care":             true,
	}

	for _, item := range snap.Plugins {
		installed, err := mgr.InstallStorePlugin(context.Background(), item.ID, "")
		if err != nil {
			t.Fatalf("InstallStorePlugin(%s) failed: %v", item.ID, err)
		}
		if installed.ID != item.ID || installed.PendingActivation || !installed.Valid {
			t.Fatalf("expected official static plugin %s to auto-activate cleanly, got %+v", item.ID, installed)
		}
		htmlRaw, err := os.ReadFile(filepath.Join(dataDir, "plugins", item.ID, "ui", "index.html"))
		if err != nil {
			t.Fatalf("read installed index.html for %s: %v", item.ID, err)
		}
		html := string(htmlRaw)
		if strings.Contains(html, "/*__LIGHTISLE_SHARED_CSS__*/") || strings.Contains(html, "/*__LIGHTISLE_KV_JS__*/") {
			t.Fatalf("plugin %s contains unresolved shared placeholder", item.ID)
		}
		if item.ID != "network-pulse" {
			if !strings.Contains(html, "LightIsleKV.createStore") || !strings.Contains(html, "./__lightisle_kv/") {
				t.Fatalf("plugin %s missing LightIsleKV host bridge integration", item.ID)
			}
			if reminderApps[item.ID] && !strings.Contains(html, "buildReminders") {
				t.Fatalf("plugin %s missing buildReminders integration", item.ID)
			}
		}
	}

	// Duplicate install must fail cleanly with ErrAlreadyInstalled.
	if _, err := mgr.InstallStorePlugin(context.Background(), "family-subscriptions", ""); !errors.Is(err, ErrAlreadyInstalled) {
		t.Fatalf("expected ErrAlreadyInstalled on duplicate install, got %v", err)
	}
}

func makeSyntheticPackageZip(t *testing.T, id, name, version, htmlBody string) ([]byte, string) {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	manifest := PluginManifest{
		SchemaVersion: 2,
		ID:            id,
		Name:          name,
		Version:       version,
		Author:        "Test Author",
		Description:   "Synthetic store plugin",
		Category:      "family",
		Icon:          "icon.svg",
		Access:        AccessConfig{Policy: AccessAllMembers, AllowedUserIDs: []int64{}},
		Web: &WebConfig{
			Enabled:   true,
			Mode:      WebModeStatic,
			Runtime:   "static",
			StaticDir: "ui",
			BasePath:  "/apps/" + id,
		},
	}
	manifestBytes, _ := json.MarshalIndent(manifest, "", "  ")
	iconBytes := []byte(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" fill="#0E6B74"/></svg>`)
	htmlBytes := []byte(htmlBody)

	files := map[string][]byte{
		"plugin.json":   manifestBytes,
		"icon.svg":      iconBytes,
		"ui/index.html": htmlBytes,
	}
	var entries []PluginBackupFileEntry
	for name, content := range files {
		fw, err := zw.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := fw.Write(content); err != nil {
			t.Fatal(err)
		}
		sum := sha256.Sum256(content)
		entries = append(entries, PluginBackupFileEntry{
			Path:   name,
			Size:   int64(len(content)),
			SHA256: hex.EncodeToString(sum[:]),
		})
	}
	pkgManifest := PluginPackageManifest{
		SchemaVersion: PackageSchemaVersion,
		AppID:         id,
		Name:          name,
		Version:       version,
		FileCount:     len(entries),
		Files:         entries,
	}
	pmBytes, _ := json.MarshalIndent(pkgManifest, "", "  ")
	fw, _ := zw.Create(packageManifestPath)
	_, _ = fw.Write(pmBytes)
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	raw := buf.Bytes()
	sum := sha256.Sum256(raw)
	return raw, hex.EncodeToString(sum[:])
}

func TestGitStoreUpgradePreservesDataAndSettingsAndRejectsTamperedSHA(t *testing.T) {
	storeRoot := t.TempDir()
	_ = os.MkdirAll(filepath.Join(storeRoot, "packages"), 0700)

	zipV1, shaV1 := makeSyntheticPackageZip(t, "family-notes", "家庭便签", "1.0.0", "<h1>v1</h1>")
	zipV2, shaV2 := makeSyntheticPackageZip(t, "family-notes", "家庭便签", "1.2.0", "<h1>v2 upgraded</h1>")

	writeRegistry := func(version, sha string, pkgBytes []byte) {
		_ = os.WriteFile(filepath.Join(storeRoot, "packages", "family-notes.liapp.zip"), pkgBytes, 0600)
		doc := StoreRegistryDocument{
			SchemaVersion: StoreSchemaVersion,
			StoreName:     "Test Store",
			Plugins: []StorePluginEntry{{
				ID:          "family-notes",
				Name:        "家庭便签",
				Version:     version,
				Category:    "family",
				Mode:        WebModeStatic,
				Description: "test",
				PackagePath: "packages/family-notes.liapp.zip",
				SHA256:      sha,
				SizeBytes:   int64(len(pkgBytes)),
			}},
		}
		raw, _ := json.MarshalIndent(doc, "", "  ")
		_ = os.WriteFile(filepath.Join(storeRoot, "registry.json"), raw, 0600)
	}

	srv := startLocalGitStoreServer(t, storeRoot)
	dataDir := t.TempDir()
	mgr := NewManager(dataDir, "", nil)
	defer mgr.Close()

	// 1. Third-party custom store (treatAsOfficial=false) must require activation, and tampered SHA must be rejected.
	writeRegistry("1.0.0", strings.Repeat("a", 64), zipV1)
	mgr.SetStoreTestConfigForTesting(srv.URL+"/registry.json", false)
	if _, err := mgr.RefreshStore(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := mgr.InstallStorePlugin(context.Background(), "family-notes", ""); !errors.Is(err, ErrStoreChecksumMismatch) {
		t.Fatalf("expected ErrStoreChecksumMismatch on tampered digest, got %v", err)
	}

	// 2. Fix SHA & install as custom store -> pendingActivation=true until admin approves.
	writeRegistry("1.0.0", shaV1, zipV1)
	_, _ = mgr.RefreshStore(context.Background())
	installed, err := mgr.InstallStorePlugin(context.Background(), "family-notes", "")
	if err != nil {
		t.Fatalf("install v1 failed: %v", err)
	}
	if !installed.PendingActivation {
		t.Fatalf("expected third-party store plugin to require admin activation")
	}
	if _, err := mgr.ApproveApp("family-notes"); err != nil {
		t.Fatalf("ApproveApp failed: %v", err)
	}

	// Customize access policy, env.json, and plugin-data KV store.
	if _, err := mgr.UpdateApp("family-notes", AppUpdateRequest{
		Access: &AccessConfig{Policy: AccessSelectedMembers, AllowedUserIDs: []int64{42}},
	}); err != nil {
		t.Fatalf("UpdateApp access failed: %v", err)
	}
	envPath := filepath.Join(dataDir, "plugins", "family-notes", "env.json")
	_ = os.WriteFile(envPath, []byte(`{"CUSTOM_KEY":"keep-me"}`), 0600)
	kvFile := filepath.Join(dataDir, "plugin-data", "family-notes", "kv", "notes.json")
	_ = os.MkdirAll(filepath.Dir(kvFile), 0700)
	_ = os.WriteFile(kvFile, []byte(`{"items":["milk"]}`), 0600)

	// No update available when store is still v1.0.0.
	if _, err := mgr.UpgradeStorePlugin(context.Background(), "family-notes"); !errors.Is(err, ErrStoreNoUpdate) {
		t.Fatalf("expected ErrStoreNoUpdate when version unchanged, got %v", err)
	}

	// 3. Publish v1.2.0 and treat as official so upgrade auto-stays active and preserves user data + settings.
	writeRegistry("1.2.0", shaV2, zipV2)
	mgr.SetStoreTestConfigForTesting(srv.URL+"/registry.json", true)
	snap, err := mgr.RefreshStore(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(snap.Plugins) != 1 || !snap.Plugins[0].UpdateAvailable || snap.Plugins[0].InstalledVersion != "1.0.0" {
		t.Fatalf("expected updateAvailable=true from 1.0.0 to 1.2.0, got %+v", snap.Plugins)
	}

	upgraded, err := mgr.UpgradeStorePlugin(context.Background(), "family-notes")
	if err != nil {
		t.Fatalf("UpgradeStorePlugin failed: %v", err)
	}
	if upgraded.Version != "1.2.0" || upgraded.PendingActivation {
		t.Fatalf("unexpected upgraded app state: %+v", upgraded)
	}
	if upgraded.Access.Policy != AccessSelectedMembers || len(upgraded.Access.AllowedUserIDs) != 1 || upgraded.Access.AllowedUserIDs[0] != 42 {
		t.Fatalf("expected access policy preserved across upgrade, got %+v", upgraded.Access)
	}
	if gotEnv, err := os.ReadFile(envPath); err != nil || !strings.Contains(string(gotEnv), "keep-me") {
		t.Fatalf("expected env.json preserved across upgrade, got %q err=%v", string(gotEnv), err)
	}
	if gotKV, err := os.ReadFile(kvFile); err != nil || string(gotKV) != `{"items":["milk"]}` {
		t.Fatalf("expected plugin-data KV preserved across upgrade, got %q err=%v", string(gotKV), err)
	}
	if gotHTML, err := os.ReadFile(filepath.Join(dataDir, "plugins", "family-notes", "ui", "index.html")); err != nil || string(gotHTML) != "<h1>v2 upgraded</h1>" {
		t.Fatalf("expected upgraded HTML v2, got %q err=%v", string(gotHTML), err)
	}
}

func TestStoreURLValidationMirrorAndSemver(t *testing.T) {
	if _, err := ValidateStoreRegistryURL("http://example.com/registry.json", false); !errors.Is(err, ErrStoreInvalidConfig) {
		t.Fatalf("expected HTTP non-loopback rejected, got %v", err)
	}
	if _, err := ValidateStoreRegistryURL("https://127.0.0.1:8443/registry.json", false); !errors.Is(err, ErrStoreInvalidConfig) {
		t.Fatalf("expected loopback rejected in production, got %v", err)
	}
	if _, err := ValidateStoreRegistryURL("https://169.254.169.254/latest/meta-data", false); !errors.Is(err, ErrStoreInvalidConfig) {
		t.Fatalf("expected link-local metadata IP rejected, got %v", err)
	}
	if got := ApplyStoreMirror(DefaultOfficialStoreURL, "https://ghfast.top"); got != "https://ghfast.top/"+DefaultOfficialStoreURL {
		t.Fatalf("unexpected mirrored URL: %q", got)
	}
	if got := ApplyStoreMirror("https://git.myhome.example/store/registry.json", "https://ghfast.top/"); got != "https://git.myhome.example/store/registry.json" {
		t.Fatalf("non-GitHub custom URL should not be rewritten by GitHub mirror, got %q", got)
	}
	if CompareSemver("1.10.0", "1.2.0") <= 0 || CompareSemver("1.1.0", "1.1.0-beta.1") <= 0 || CompareSemver("1.0.0", "1.0.0") != 0 {
		t.Fatalf("unexpected CompareSemver ordering")
	}
}
