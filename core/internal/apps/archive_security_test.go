package apps

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func buildTestTarGz(t *testing.T, files map[string][]byte) []byte {
	t.Helper()
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	for name, content := range files {
		hdr := &tar.Header{
			Name:    name,
			Size:    int64(len(content)),
			Mode:    0600,
			ModTime: time.Now(),
		}
		if err := tw.WriteHeader(hdr); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write(content); err != nil {
			t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestArchiveSQLiteFailureAbortsAndRestoreVerifiesManifestAndPreservesRunningState(t *testing.T) {
	dataDir := t.TempDir()
	mgr := NewManager(dataDir, "lightisled", nil)
	defer mgr.Close()

	pluginDir := filepath.Join(dataDir, "plugins", "vault-app")
	appDataDir := filepath.Join(dataDir, "plugin-data", "vault-app")
	if err := os.MkdirAll(pluginDir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(appDataDir, 0700); err != nil {
		t.Fatal(err)
	}

	manifest := PluginManifest{
		SchemaVersion: 2,
		ID:            "vault-app",
		Name:          "Vault App",
		Version:       "1.0.0",
		Access:        AccessConfig{Policy: AccessAdminOnly, AllowedUserIDs: []int64{}},
		Web: &WebConfig{
			Enabled:             true,
			Mode:                WebModeOnDemand,
			Runtime:             "python",
			Entry:               "run-web.sh",
			Port:                0,
			BasePath:            "/apps/vault-app",
			IdleTimeoutSeconds:  600,
			ReadyTimeoutSeconds: 10,
		},
	}
	rawManifest, _ := json.MarshalIndent(manifest, "", "  ")
	if err := os.WriteFile(filepath.Join(pluginDir, "plugin.json"), rawManifest, 0600); err != nil {
		t.Fatal(err)
	}
	script := `#!/bin/sh
set -eu
exec python3 -c '
import http.server, os
port = int(os.environ["PORT"])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")
    def log_message(self, format, *args):
        pass
http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
'
`
	if err := os.WriteFile(filepath.Join(pluginDir, "run-web.sh"), []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	if err := mgr.Reload(); err != nil {
		t.Fatal(err)
	}

	// 1. DATA-01: Corrupt SQLite file in plugin-data/<id>/ MUST abort ExportAppData (never fall back to raw copy)
	corruptDB := filepath.Join(appDataDir, "corrupt.db")
	if err := os.WriteFile(corruptDB, []byte("not-a-valid-sqlite-database"), 0600); err != nil {
		t.Fatal(err)
	}
	var badExport bytes.Buffer
	if err := mgr.ExportAppData(context.Background(), "vault-app", &badExport); err == nil {
		t.Fatal("DATA-01: expected ExportAppData to fail when SQLite VACUUM INTO snapshot fails on corrupt.db")
	}
	_ = os.Remove(corruptDB)

	// 2. Create a valid SQLite database + state.json in plugin-data/vault-app
	validDBPath := filepath.Join(appDataDir, "vault.sqlite")
	db, err := sql.Open("sqlite3", validDBPath)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`CREATE TABLE items (k TEXT PRIMARY KEY, v TEXT); INSERT INTO items VALUES ('k1', 'v1');`); err != nil {
		db.Close()
		t.Fatal(err)
	}
	db.Close()
	stateFile := filepath.Join(appDataDir, "state.json")
	if err := os.WriteFile(stateFile, []byte(`{"version":1,"important":"keep-me"}`), 0600); err != nil {
		t.Fatal(err)
	}

	// Export valid archive
	var validArchive bytes.Buffer
	if err := mgr.ExportAppData(context.Background(), "vault-app", &validArchive); err != nil {
		t.Fatalf("ExportAppData failed on valid SQLite DB: %v", err)
	}

	// Wake vault-app so it is StatusRunning before testing failed and successful restores (P1-6)
	woken, err := mgr.WakeApp(context.Background(), "vault-app")
	if err != nil || woken.Web.Status != StatusRunning || woken.Web.PID <= 0 {
		t.Fatalf("expected vault-app running, got %+v %v", woken, err)
	}
	pidBeforeFailedRestore := woken.Web.PID

	// 3. DATA-02 & P1-6: Reject empty archive (missing backup-manifest.json) without stopping running process or deleting data
	emptyArchive := buildTestTarGz(t, map[string][]byte{})
	if err := mgr.RestoreAppData(context.Background(), "vault-app", bytes.NewReader(emptyArchive)); !errors.Is(err, ErrInvalid) {
		t.Fatalf("DATA-02: expected ErrInvalid on empty archive, got %v", err)
	}

	// 4. DATA-02: Reject archive with manifest that has 0 business data files (prevents wiping dataDir with empty dir)
	zeroDataManifest, _ := json.Marshal(PluginBackupManifest{
		SchemaVersion: PluginBackupSchemaVersion,
		AppID:         "vault-app",
		DataFileCount: 0,
		Files:         []PluginBackupFileEntry{},
	})
	zeroDataArchive := buildTestTarGz(t, map[string][]byte{
		backupManifestArchivePath: zeroDataManifest,
	})
	if err := mgr.RestoreAppData(context.Background(), "vault-app", bytes.NewReader(zeroDataArchive)); !errors.Is(err, ErrInvalid) {
		t.Fatalf("DATA-02: expected ErrInvalid on archive with 0 data files, got %v", err)
	}

	// 5. DATA-02: Reject archive from a different plugin ID ("other-app")
	wrongAppManifest, _ := json.Marshal(PluginBackupManifest{
		SchemaVersion: PluginBackupSchemaVersion,
		AppID:         "other-app",
		DataFileCount: 1,
		Files: []PluginBackupFileEntry{
			{Path: "data/state.json", Size: 2, SHA256: "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"},
		},
	})
	wrongAppArchive := buildTestTarGz(t, map[string][]byte{
		"data/state.json":         []byte(`{}`),
		backupManifestArchivePath: wrongAppManifest,
	})
	if err := mgr.RestoreAppData(context.Background(), "vault-app", bytes.NewReader(wrongAppArchive)); !errors.Is(err, ErrInvalid) {
		t.Fatalf("DATA-02: expected ErrInvalid on mismatched appId archive, got %v", err)
	}

	// 6. DATA-02: Reject archive with tampered SHA-256 checksum
	tamperedManifest, _ := json.Marshal(PluginBackupManifest{
		SchemaVersion: PluginBackupSchemaVersion,
		AppID:         "vault-app",
		DataFileCount: 1,
		Files: []PluginBackupFileEntry{
			{Path: "data/state.json", Size: 2, SHA256: "0000000000000000000000000000000000000000000000000000000000000000"},
		},
	})
	tamperedArchive := buildTestTarGz(t, map[string][]byte{
		"data/state.json":         []byte(`{}`),
		backupManifestArchivePath: tamperedManifest,
	})
	if err := mgr.RestoreAppData(context.Background(), "vault-app", bytes.NewReader(tamperedArchive)); !errors.Is(err, ErrInvalid) {
		t.Fatalf("DATA-02: expected ErrInvalid on tampered SHA-256 archive, got %v", err)
	}

	// Verify P1-6: After all 4 rejected restore attempts, vault-app is STILL running with the SAME PID and original data is intact!
	afterFailedView, err := mgr.GetForUser("vault-app", 1, "admin")
	if err != nil || afterFailedView.Web.Status != StatusRunning || afterFailedView.Web.PID != pidBeforeFailedRestore {
		t.Fatalf("P1-6: expected running instance to remain untouched after failed restore validation, got %+v", afterFailedView.Web)
	}
	origState, err := os.ReadFile(stateFile)
	if err != nil || !strings.Contains(string(origState), "keep-me") {
		t.Fatalf("DATA-02: expected original state.json to remain intact after rejected restores, got %q %v", string(origState), err)
	}

	// 7. Mutate state.json, then perform a valid restore -> data is restored AND running state is automatically resumed!
	if err := os.WriteFile(stateFile, []byte(`{"version":2,"important":"mutated"}`), 0600); err != nil {
		t.Fatal(err)
	}
	if err := mgr.RestoreAppData(context.Background(), "vault-app", bytes.NewReader(validArchive.Bytes())); err != nil {
		t.Fatalf("valid RestoreAppData failed: %v", err)
	}
	restoredState, err := os.ReadFile(stateFile)
	if err != nil || string(restoredState) != `{"version":1,"important":"keep-me"}` {
		t.Fatalf("expected restored state.json to match backup, got %q %v", string(restoredState), err)
	}
	afterValidRestore, err := mgr.GetForUser("vault-app", 1, "admin")
	if err != nil || afterValidRestore.Web.Status != StatusRunning {
		t.Fatalf("P1-6: expected running app to resume StatusRunning after valid restore, got %+v %v", afterValidRestore.Web, err)
	}
}

func TestPendingActivationUniformEnforcement(t *testing.T) {
	dataDir := t.TempDir()
	mgr := NewManager(dataDir, "lightisled", nil)
	defer mgr.Close()

	// Create a plugin whose manifest declares policy: "all_members", loaded via ReloadFromMCP (pendingActivation = true)
	pluginDir := filepath.Join(dataDir, "plugins", "pending-all")
	if err := os.MkdirAll(pluginDir, 0700); err != nil {
		t.Fatal(err)
	}
	manifest := PluginManifest{
		SchemaVersion: 2,
		ID:            "pending-all",
		Name:          "Pending All Members App",
		Version:       "1.0.0",
		Access:        AccessConfig{Policy: AccessAllMembers, AllowedUserIDs: []int64{}},
		Web: &WebConfig{
			Enabled:             true,
			Mode:                WebModeOnDemand,
			Runtime:             "python",
			Entry:               "run-web.sh",
			Port:                0,
			BasePath:            "/apps/pending-all",
			IdleTimeoutSeconds:  300,
			ReadyTimeoutSeconds: 10,
		},
	}
	raw, _ := json.MarshalIndent(manifest, "", "  ")
	if err := os.WriteFile(filepath.Join(pluginDir, "plugin.json"), raw, 0600); err != nil {
		t.Fatal(err)
	}
	script := "#!/bin/sh\nexec python3 -m http.server \"$PORT\" --bind 127.0.0.1\n"
	if err := os.WriteFile(filepath.Join(pluginDir, "run-web.sh"), []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	if err := mgr.ReloadFromMCP(); err != nil {
		t.Fatal(err)
	}

	// AUTH-01: Ordinary member CANNOT access or see pending-all even though policy is "all_members"
	if mgr.CanAccess("pending-all", 2, "member") {
		t.Fatal("AUTH-01: expected CanAccess=false for ordinary member while plugin is pendingActivation")
	}
	for _, a := range mgr.ListForUser(2, "member") {
		if a.ID == "pending-all" {
			t.Fatal("AUTH-01: pending-all must not appear in ListForUser for ordinary member")
		}
	}

	// AUTH-01: WakeApp refuses to wake or auto-activate a pending plugin
	if _, err := mgr.WakeApp(context.Background(), "pending-all"); !errors.Is(err, ErrPendingActivation) {
		t.Fatalf("AUTH-01: expected WakeApp to return ErrPendingActivation, got %v", err)
	}

	// AUTH-01: Gateway ServeApp refuses requests to a pending plugin with 403 app_pending_activation
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/apps/pending-all/", nil)
	mgr.ServeApp(rec, req, func(_ *http.Request) (UserIdentity, bool) {
		return UserIdentity{ID: 1, Username: "admin", Role: "admin"}, true
	})
	if rec.Code != http.StatusForbidden || !strings.Contains(rec.Body.String(), "app_pending_activation") {
		t.Fatalf("AUTH-01: expected ServeApp to return 403 app_pending_activation while pending, got %d %s", rec.Code, rec.Body.String())
	}

	// Explicit admin ApproveApp clears pendingActivation and unlocks access
	if _, err := mgr.ApproveApp("pending-all"); err != nil {
		t.Fatalf("ApproveApp failed: %v", err)
	}
	if !mgr.CanAccess("pending-all", 2, "member") {
		t.Fatal("expected CanAccess=true for member after admin ApproveApp")
	}
}

func TestMultiLanguageTemplatesSyntaxAndRustBuild(t *testing.T) {
	tmp := t.TempDir()
	for _, rt := range []string{"python", "node", "go", "rust", "java", "shell"} {
		dir := filepath.Join(tmp, rt)
		if err := os.MkdirAll(dir, 0700); err != nil {
			t.Fatal(err)
		}
		files, err := writeRuntimeScaffold(dir, "demo-"+rt, "Demo "+rt, rt, true)
		if err != nil || len(files) == 0 {
			t.Fatalf("writeRuntimeScaffold(%s) failed: %v", rt, err)
		}
	}

	// P1-4: Verify generated Rust main.rs has valid string escaping and compiles with rustc if installed
	rustSrc, err := os.ReadFile(filepath.Join(tmp, "rust", "main.rs"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(rustSrc), `let body = "{\"app\":\"demo-rust\",\"runtime\":\"rust\"}";`) {
		t.Fatalf("P1-4: unexpected Rust body literal in main.rs:\n%s", string(rustSrc))
	}
	if rustcPath, err := exec.LookPath("rustc"); err == nil {
		outBin := filepath.Join(tmp, "rust", "app")
		cmd := exec.Command(rustcPath, "-O", filepath.Join(tmp, "rust", "main.rs"), "-o", outBin)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("P1-4: rustc failed to compile generated main.rs: %v\n%s", err, string(out))
		}
	}
}
