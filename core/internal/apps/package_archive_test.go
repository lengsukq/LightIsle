package apps

import (
	"archive/zip"
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestExportAndImportAppPackage(t *testing.T) {
	ctx := context.Background()
	srcDir := t.TempDir()
	srcMgr := NewManager(srcDir, "", nil)
	defer srcMgr.Close()
	if err := srcMgr.Reload(); err != nil {
		t.Fatal(err)
	}

	// Create a custom static plugin with an env.json secret and selected_members allowlist.
	pluginDir := filepath.Join(srcMgr.PluginsDir(), "family-notes")
	if err := os.MkdirAll(filepath.Join(pluginDir, "ui"), 0700); err != nil {
		t.Fatal(err)
	}
	manifestJSON := `{
  "schemaVersion": 2,
  "id": "family-notes",
  "name": "家庭小笔记",
  "version": "1.2.0",
  "category": "lifestyle",
  "description": "可分享的静态小笔记",
  "access": { "policy": "selected_members", "allowedUserIds": [42, 99] },
  "web": { "enabled": true, "mode": "static", "runtime": "static", "staticDir": "ui", "basePath": "/apps/family-notes" }
}`
	if err := os.WriteFile(filepath.Join(pluginDir, "plugin.json"), []byte(manifestJSON), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(pluginDir, "ui", "index.html"), []byte("<h1>hello</h1>"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(pluginDir, "env.json"), []byte(`{"SECRET_KEY":"super-secret"}`), 0600); err != nil {
		t.Fatal(err)
	}
	if err := srcMgr.Reload(); err != nil {
		t.Fatal(err)
	}

	var buf bytes.Buffer
	if err := srcMgr.ExportAppPackage(ctx, "family-notes", &buf); err != nil {
		t.Fatalf("ExportAppPackage failed: %v", err)
	}

	// Verify exported zip strips env.json and private member IDs.
	zr, err := zip.NewReader(bytes.NewReader(buf.Bytes()), int64(buf.Len()))
	if err != nil {
		t.Fatalf("zip.NewReader failed: %v", err)
	}
	for _, f := range zr.File {
		if strings.Contains(f.Name, "env.json") {
			t.Fatalf("exported package must not contain env.json: %s", f.Name)
		}
	}

	// Import into a fresh LightIsle instance.
	dstDir := t.TempDir()
	dstMgr := NewManager(dstDir, "", nil)
	defer dstMgr.Close()
	if err := dstMgr.Reload(); err != nil {
		t.Fatal(err)
	}

	imported, err := dstMgr.ImportAppPackage(ctx, bytes.NewReader(buf.Bytes()), "")
	if err != nil {
		t.Fatalf("ImportAppPackage failed: %v", err)
	}
	if imported.ID != "family-notes" || !imported.Valid {
		t.Fatalf("unexpected imported app: %+v", imported)
	}
	if !imported.PendingActivation {
		t.Fatalf("expected imported package to enter pendingActivation=true")
	}
	if imported.Access.Policy != AccessAdminOnly || len(imported.Access.AllowedUserIDs) != 0 {
		t.Fatalf("expected sanitized access policy admin_only with empty allowlist, got %+v", imported.Access)
	}

	// Duplicate import must fail with ErrAlreadyInstalled.
	if _, err := dstMgr.ImportAppPackage(ctx, bytes.NewReader(buf.Bytes()), ""); !errors.Is(err, ErrAlreadyInstalled) {
		t.Fatalf("expected ErrAlreadyInstalled on duplicate import, got %v", err)
	}

	// Reload must keep pendingActivation=true until admin explicitly approves.
	if err := dstMgr.Reload(); err != nil {
		t.Fatal(err)
	}
	afterReload, err := dstMgr.GetForUser("family-notes", 0, "admin")
	if err != nil || !afterReload.PendingActivation {
		t.Fatalf("expected pendingActivation to persist across Reload, got %+v %v", afterReload, err)
	}

	approved, err := dstMgr.ApproveApp("family-notes")
	if err != nil || approved.PendingActivation {
		t.Fatalf("ApproveApp failed: %+v %v", approved, err)
	}
}

func TestImportAppPackageRejectsTraversalAndOfficialIDSpoof(t *testing.T) {
	ctx := context.Background()
	mgr := NewManager(t.TempDir(), "", nil)
	defer mgr.Close()
	if err := mgr.Reload(); err != nil {
		t.Fatal(err)
	}

	// 1. Path traversal must be rejected.
	var badZip bytes.Buffer
	zw := zip.NewWriter(&badZip)
	fw, _ := zw.Create("../escape.txt")
	_, _ = fw.Write([]byte("nope"))
	_ = zw.Close()
	if _, err := mgr.ImportAppPackage(ctx, bytes.NewReader(badZip.Bytes()), ""); !errors.Is(err, ErrInvalid) {
		t.Fatalf("expected ErrInvalid for path traversal zip, got %v", err)
	}

	// 2. Spoofing an official template ID must STILL enter pendingActivation=true.
	var spoofZip bytes.Buffer
	zw2 := zip.NewWriter(&spoofZip)
	f1, _ := zw2.Create("plugin.json")
	_, _ = f1.Write([]byte(`{
  "schemaVersion": 2,
  "id": "family-board",
  "name": "Fake Board",
  "version": "1.0.0",
  "access": { "policy": "all_members", "allowedUserIds": [] },
  "web": { "enabled": true, "mode": "static", "runtime": "static", "staticDir": "ui", "basePath": "/apps/family-board" }
}`))
	f2, _ := zw2.Create("ui/index.html")
	_, _ = f2.Write([]byte("<h1>spoof</h1>"))
	_ = zw2.Close()

	imported, err := mgr.ImportAppPackage(ctx, bytes.NewReader(spoofZip.Bytes()), "")
	if err != nil {
		t.Fatalf("ImportAppPackage(spoof) failed: %v", err)
	}
	if !imported.PendingActivation {
		t.Fatalf("imported package matching official template ID must still require pendingActivation")
	}
}
