package apps

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeTestPlugin(t *testing.T, pluginsDir, id, manifestJSON, scriptContent string, mode os.FileMode) {
	t.Helper()
	dir := filepath.Join(pluginsDir, id)
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "plugin.json"), []byte(manifestJSON), 0600); err != nil {
		t.Fatal(err)
	}
	if scriptContent != "" {
		if err := os.WriteFile(filepath.Join(dir, "run-web.sh"), []byte(scriptContent), mode); err != nil {
			t.Fatal(err)
		}
	}
}

func TestStartupFailureDiagnosticsAndMemberIsolation(t *testing.T) {
	dataDir := t.TempDir()
	pluginsDir := filepath.Join(dataDir, "plugins")
	mgr := NewManager(dataDir, "", nil)
	defer mgr.Close()

	// 1. Missing dependency / build artifact (exit 127 + node_modules/.bin/next not found)
	writeTestPlugin(t, pluginsDir, "missing-deps", `{
		"schemaVersion": 2,
		"id": "missing-deps",
		"name": "测试缺失依赖应用",
		"version": "1.0.0",
		"access": { "policy": "all_members" },
		"web": { "enabled": true, "mode": "on-demand", "runtime": "node", "entry": "run-web.sh", "readyTimeoutSeconds": 3 }
	}`, "#!/bin/sh\necho './run-web.sh: ./node_modules/.bin/next: No such file or directory' >&2\nexit 127\n", 0700)

	// 2. Port listen timeout (process stays alive on wrong port, never binds $PORT)
	writeTestPlugin(t, pluginsDir, "wrong-port", `{
		"schemaVersion": 2,
		"id": "wrong-port",
		"name": "未监听分配端口应用",
		"version": "1.0.0",
		"access": { "policy": "admin_only" },
		"web": { "enabled": true, "mode": "on-demand", "runtime": "shell", "entry": "run-web.sh", "readyTimeoutSeconds": 1 }
	}`, "#!/bin/sh\necho 'Listening on hardcoded port 9999 instead of PORT'\nsleep 5\n", 0700)

	// 3. Invalid manifest / missing script permission
	writeTestPlugin(t, pluginsDir, "bad-perm", `{
		"schemaVersion": 2,
		"id": "bad-perm",
		"name": "缺少执行权限应用",
		"version": "1.0.0",
		"access": { "policy": "admin_only" },
		"web": { "enabled": true, "mode": "on-demand", "entry": "run-web.sh" }
	}`, "#!/bin/sh\nsleep 1\n", 0600)

	if err := mgr.Reload(); err != nil {
		t.Fatal(err)
	}
	mgr.ActivateApp("missing-deps")
	mgr.ActivateApp("wrong-port")

	// Verify validation diagnostic for bad-perm
	badPermApp, err := mgr.GetForUser("bad-perm", 1, "admin")
	if err != nil {
		t.Fatal(err)
	}
	if badPermApp.Valid || badPermApp.Diagnostic == nil {
		t.Fatalf("expected validation diagnostic for bad-perm, got %+v", badPermApp)
	}
	if !strings.Contains(badPermApp.Diagnostic.Solutions[0], "chmod 700") {
		t.Fatalf("expected chmod 700 solution, got %+v", badPermApp.Diagnostic)
	}

	// Verify missing-deps wake failure produces reason + logExcerpt + checks + solutions + dataSafe
	_, wakeErr := mgr.WakeApp(context.Background(), "missing-deps")
	if wakeErr == nil {
		t.Fatal("expected WakeApp to fail for missing-deps")
	}
	if !strings.Contains(wakeErr.Error(), "排查：") || !strings.Contains(wakeErr.Error(), "解决：") {
		t.Fatalf("expected actionable wake error with check & solution, got: %v", wakeErr)
	}
	depApp, err := mgr.GetForUser("missing-deps", 1, "admin")
	if err != nil {
		t.Fatal(err)
	}
	if depApp.Diagnostic == nil {
		t.Fatalf("expected structured diagnostic on PublicApp, got %+v", depApp)
	}
	if !strings.Contains(depApp.Diagnostic.Summary, "缺少依赖") ||
		!strings.Contains(depApp.Diagnostic.LogExcerpt, "node_modules/.bin/next") ||
		len(depApp.Diagnostic.Checks) == 0 ||
		len(depApp.Diagnostic.Solutions) == 0 ||
		!strings.Contains(depApp.Diagnostic.DataSafe, "plugin-data/missing-deps") {
		t.Fatalf("unexpected diagnostic fields: %+v", depApp.Diagnostic)
	}

	// Non-admin member must NOT receive internal diagnostic / logExcerpt / host paths
	memberApp, err := mgr.GetForUser("missing-deps", 2, "member")
	if err != nil {
		t.Fatal(err)
	}
	if memberApp.Diagnostic != nil || memberApp.LastError != "" || memberApp.Web.LastError != "" {
		t.Fatalf("expected member view to strip internal diagnostics, got %+v", memberApp)
	}

	// Verify wrong-port timeout diagnostic mentions PORT
	_, portErr := mgr.WakeApp(context.Background(), "wrong-port")
	if portErr == nil {
		t.Fatal("expected WakeApp to timeout for wrong-port")
	}
	portApp, err := mgr.GetForUser("wrong-port", 1, "admin")
	if err != nil || portApp.Diagnostic == nil {
		t.Fatalf("expected diagnostic for wrong-port, got %+v %v", portApp, err)
	}
	if !strings.Contains(portApp.Diagnostic.Reason, "未在 127.0.0.1:") || !strings.Contains(portApp.Diagnostic.Checks[0], "PORT") {
		t.Fatalf("expected PORT binding diagnostic, got %+v", portApp.Diagnostic)
	}

	// Verify browser HTML gateway error page vs JSON API fallback
	adminTicket := mgr.IssueTicket("missing-deps", UserIdentity{ID: 1, Username: "admin", Role: "admin"})
	htmlReq := httptest.NewRequest(http.MethodGet, "/apps/missing-deps/?__li_ticket="+adminTicket, nil)
	htmlReq.Header.Set("Accept", "text/html,application/xhtml+xml")
	htmlRec := httptest.NewRecorder()
	mgr.ServeApp(htmlRec, htmlReq, func(_ *http.Request) (UserIdentity, bool) {
		return UserIdentity{ID: 1, Username: "admin", Role: "admin"}, true
	})
	// First request with __li_ticket redirects 302 to clean path with cookie
	if htmlRec.Code == http.StatusFound {
		cookies := htmlRec.Result().Cookies()
		htmlReq2 := httptest.NewRequest(http.MethodGet, "/apps/missing-deps/", nil)
		htmlReq2.Header.Set("Accept", "text/html,application/xhtml+xml")
		for _, c := range cookies {
			htmlReq2.AddCookie(c)
		}
		htmlRec = httptest.NewRecorder()
		mgr.ServeApp(htmlRec, htmlReq2, func(_ *http.Request) (UserIdentity, bool) {
			return UserIdentity{ID: 1, Username: "admin", Role: "admin"}, true
		})
	}
	body := htmlRec.Body.String()
	if htmlRec.Code != http.StatusBadGateway ||
		!strings.Contains(htmlRec.Header().Get("Content-Type"), "text/html") ||
		!strings.Contains(body, "问题原因") ||
		!strings.Contains(body, "如何排查") ||
		!strings.Contains(body, "解决办法") ||
		!strings.Contains(body, "node_modules/.bin/next") {
		t.Fatalf("expected rich HTML diagnostic page for admin, got status=%d ct=%s body=%s",
			htmlRec.Code, htmlRec.Header().Get("Content-Type"), body)
	}

	// Verify health check HTTP 500 failure classification directly
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	})}
	go func() { _ = srv.Serve(ln) }()
	defer srv.Close()

	diag := buildStartFailureDiagnostic(
		"hc-fail", "run-web.sh", "go", "/apps/hc-fail/health",
		port, 2, fmt.Errorf("%w (HTTP 500)", errHealthCheckFailed), nil, "db init error: disk readonly",
	)
	if !strings.Contains(diag.Summary, "健康检查") || !strings.Contains(diag.Reason, "HTTP 500") {
		t.Fatalf("expected health check failure diagnostic, got %+v", diag)
	}
}
