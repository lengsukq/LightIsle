package server

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/apps"
	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/automation"
)

func TestAppsServerRoutesContractsAndSessionInvalidation(t *testing.T) {
	dataDir := t.TempDir()
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
	memberUser, err := accounts.CreateUser(adminTok, "alice", "alice-password-12345", auth.RoleMember)
	if err != nil {
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

	appsMgr := apps.NewManager(dataDir, "lightisled", autoMgr)
	defer appsMgr.Close()
	appsMgr.SetConfiguredChannels(func() []string { return []string{"bark", "email"} })

	// Create a plugin with run-cron.sh to test /action and /actions
	cronPluginDir := filepath.Join(dataDir, "plugins", "cron-demo")
	if err := os.MkdirAll(cronPluginDir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cronPluginDir, "run-cron.sh"), []byte("#!/bin/sh\necho cron-ok\n"), 0700); err != nil {
		t.Fatal(err)
	}
	cronManifest := `{"schemaVersion":2,"id":"cron-demo","name":"Cron Demo","version":"1.0.0","access":{"policy":"admin_only","allowedUserIDs":[]},"cron":{"enabled":true,"entry":"run-cron.sh","schedule":{"cron":"*/15 * * * *","timezone":"Asia/Shanghai"},"timeoutSeconds":30,"notification":{"events":["failure"],"channels":[]}}}`
	if err := os.WriteFile(filepath.Join(cronPluginDir, "plugin.json"), []byte(cronManifest), 0600); err != nil {
		t.Fatal(err)
	}

	if err := appsMgr.Reload(); err != nil {
		t.Fatal(err)
	}

	handler := WithApps(New("", accounts, nil), "", accounts, appsMgr)
	call := func(method, path, session string, body []byte, extra func(*http.Request)) *httptest.ResponseRecorder {
		t.Helper()
		req := httptest.NewRequest(method, path, bytes.NewReader(body))
		if session != "" {
			req.AddCookie(&http.Cookie{Name: sessionCookie, Value: session})
		}
		if len(body) > 0 {
			req.Header.Set("Content-Type", "application/json")
		}
		if method != http.MethodGet {
			req.Header.Set("X-LightIsle-Request", "1")
		}
		if extra != nil {
			extra(req)
		}
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		return rec
	}

	// 1. Admin GET /api/v2/apps returns isAdmin, mcpEnabled, mcpPrompt, members, configuredChannels
	resAdmin := call(http.MethodGet, "/api/v2/apps", adminTok, nil, nil)
	if resAdmin.Code != http.StatusOK {
		t.Fatalf("admin GET /api/v2/apps = %d %s", resAdmin.Code, resAdmin.Body.String())
	}
	var adminPayload map[string]any
	if err := json.Unmarshal(resAdmin.Body.Bytes(), &adminPayload); err != nil {
		t.Fatal(err)
	}
	if adminPayload["isAdmin"] != true || adminPayload["mcpEnabled"] != false || adminPayload["mcpPrompt"] == "" {
		t.Fatalf("missing top-level admin fields: %+v", adminPayload)
	}

	// 2. P0-3: Updating member access (selected_members) on static network-pulse (no Cron) succeeds
	updateBody := []byte(`{"access":{"policy":"selected_members","allowedUserIDs":[` + "2" + `]}}`)
	resUpdate := call(http.MethodPut, "/api/v2/apps/network-pulse", adminTok, updateBody, nil)
	if resUpdate.Code != http.StatusOK {
		t.Fatalf("PUT /api/v2/apps/network-pulse failed: %d %s", resUpdate.Code, resUpdate.Body.String())
	}

	// 3. P0-2: Both POST /api/v2/apps/{id}/action and /actions work
	if resAct := call(http.MethodPost, "/api/v2/apps/cron-demo/action", adminTok, []byte(`{"action":"run_cron"}`), nil); resAct.Code != http.StatusOK {
		t.Fatalf("POST /api/v2/apps/cron-demo/action failed: %d %s", resAct.Code, resAct.Body.String())
	}
	if resActs := call(http.MethodPost, "/api/v2/apps/cron-demo/actions", adminTok, []byte(`{"action":"stop"}`), nil); resActs.Code != http.StatusOK {
		t.Fatalf("POST /api/v2/apps/cron-demo/actions failed: %d %s", resActs.Code, resActs.Body.String())
	}

	// 4. P0-6: Member launches network-pulse -> exchanges ticket for app cookie -> after logout, cookie is immediately invalidated
	resLaunch := call(http.MethodPost, "/api/v2/apps/network-pulse/launch", memberTok, []byte(`{}`), nil)
	if resLaunch.Code != http.StatusOK {
		t.Fatalf("member launch failed: %d %s", resLaunch.Code, resLaunch.Body.String())
	}
	var launchData struct {
		LaunchURL string `json:"launchUrl"`
	}
	if err := json.Unmarshal(resLaunch.Body.Bytes(), &launchData); err != nil {
		t.Fatal(err)
	}
	resExchange := call(http.MethodGet, launchData.LaunchURL, "", nil, nil)
	if resExchange.Code != http.StatusFound {
		t.Fatalf("ticket exchange expected 302, got %d", resExchange.Code)
	}
	var appCookie *http.Cookie
	for _, c := range resExchange.Result().Cookies() {
		if c.Name == "lightisle_app_network-pulse" {
			appCookie = c
			break
		}
	}
	if appCookie == nil {
		t.Fatal("expected lightisle_app_network-pulse cookie")
	}
	// Access with appCookie while session is valid -> 200 OK
	resWithCookie := call(http.MethodGet, "/apps/network-pulse/", "", nil, func(r *http.Request) {
		r.AddCookie(appCookie)
	})
	if resWithCookie.Code != http.StatusOK {
		t.Fatalf("expected 200 OK with valid appCookie, got %d", resWithCookie.Code)
	}
	// Logout member session -> old appCookie must be immediately rejected (401)
	if err := accounts.Logout(memberTok); err != nil {
		t.Fatal(err)
	}
	resAfterLogout := call(http.MethodGet, "/apps/network-pulse/", "", nil, func(r *http.Request) {
		r.AddCookie(appCookie)
	})
	if resAfterLogout.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 after member logout, got %d (memberID=%d)", resAfterLogout.Code, memberUser.ID)
	}

	// 5. Origin Isolation Guard blocks Referer /apps/*, Origin: null (opaque sandboxed iframe), and Sec-Fetch-Site: cross-site even without Referer
	resIsolated := call(http.MethodGet, "/api/v2/apps", adminTok, nil, func(r *http.Request) {
		r.Header.Set("Referer", "http://127.0.0.1:8090/apps/network-pulse/index.html")
	})
	if resIsolated.Code != http.StatusForbidden || !strings.Contains(resIsolated.Body.String(), "app_origin_isolated") {
		t.Fatalf("expected 403 app_origin_isolated on Referer /apps/*, got %d %s", resIsolated.Code, resIsolated.Body.String())
	}
	resNullOrigin := call(http.MethodGet, "/api/v2/apps", adminTok, nil, func(r *http.Request) {
		r.Header.Set("Origin", "null")
	})
	if resNullOrigin.Code != http.StatusForbidden || !strings.Contains(resNullOrigin.Body.String(), "app_origin_isolated") {
		t.Fatalf("expected 403 app_origin_isolated on Origin: null (no Referer), got %d %s", resNullOrigin.Code, resNullOrigin.Body.String())
	}
	resCrossSite := call(http.MethodPost, "/api/v2/apps/refresh", adminTok, []byte(`{}`), func(r *http.Request) {
		r.Header.Set("Sec-Fetch-Site", "cross-site")
	})
	if resCrossSite.Code != http.StatusForbidden || !strings.Contains(resCrossSite.Body.String(), "app_origin_isolated") {
		t.Fatalf("expected 403 app_origin_isolated on Sec-Fetch-Site: cross-site (no Referer), got %d %s", resCrossSite.Code, resCrossSite.Body.String())
	}

	// 6. P2-2 & DATA-03: ExportAppData (GET /api/v2/apps/{id}/data-backup) and RestoreAppData (POST /api/v2/apps/{id}/data-restore)
	dataFile := filepath.Join(dataDir, "plugin-data", "cron-demo", "state.json")
	if err := os.MkdirAll(filepath.Dir(dataFile), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dataFile, []byte(`{"counter":42}`), 0600); err != nil {
		t.Fatal(err)
	}
	resBackup := call(http.MethodGet, "/api/v2/apps/cron-demo/data-backup", adminTok, nil, nil)
	if resBackup.Code != http.StatusOK || resBackup.Body.Len() == 0 {
		t.Fatalf("GET /api/v2/apps/cron-demo/data-backup failed: %d", resBackup.Code)
	}
	archiveBytes := append([]byte(nil), resBackup.Body.Bytes()...)
	// Corrupt/remove state.json, then restore from archiveBytes
	_ = os.Remove(dataFile)
	resRestore := call(http.MethodPost, "/api/v2/apps/cron-demo/data-restore", adminTok, archiveBytes, nil)
	if resRestore.Code != http.StatusOK {
		t.Fatalf("POST /api/v2/apps/cron-demo/data-restore failed: %d %s", resRestore.Code, resRestore.Body.String())
	}
	restoredBytes, err := os.ReadFile(dataFile)
	if err != nil || string(restoredBytes) != `{"counter":42}` {
		t.Fatalf("expected restored state.json to equal {\"counter\":42}, got %q %v", string(restoredBytes), err)
	}

	// 7. DATA-03: If ExportAppData fails (e.g. corrupt SQLite DB), GET /data-backup returns 400 JSON error (never partial 200 gzip)
	badDB := filepath.Join(dataDir, "plugin-data", "cron-demo", "broken.db")
	if err := os.WriteFile(badDB, []byte("corrupt-sqlite-bytes"), 0600); err != nil {
		t.Fatal(err)
	}
	resFailedBackup := call(http.MethodGet, "/api/v2/apps/cron-demo/data-backup", adminTok, nil, nil)
	_ = os.Remove(badDB)
	if resFailedBackup.Code != http.StatusBadRequest || !strings.Contains(resFailedBackup.Header().Get("Content-Type"), "application/json") {
		t.Fatalf("DATA-03: expected 400 application/json when backup fails, got %d %s %s", resFailedBackup.Code, resFailedBackup.Header().Get("Content-Type"), resFailedBackup.Body.String())
	}

	// 8. AUTH-01: Member cannot launch, wake, or get ticket for a pendingActivation plugin even if policy is all_members
	memberTok2, err := accounts.Login("alice", "alice-password-12345")
	if err != nil {
		t.Fatal(err)
	}
	pendingDir := filepath.Join(dataDir, "plugins", "mcp-pending")
	if err := os.MkdirAll(pendingDir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(pendingDir, "run-web.sh"), []byte("#!/bin/sh\nexec python3 -m http.server \"$PORT\" --bind 127.0.0.1\n"), 0700); err != nil {
		t.Fatal(err)
	}
	pendingManifest := `{"schemaVersion":2,"id":"mcp-pending","name":"MCP Pending","version":"1.0.0","access":{"policy":"all_members","allowedUserIDs":[]},"web":{"enabled":true,"mode":"on-demand","runtime":"python","entry":"run-web.sh","port":0,"basePath":"/apps/mcp-pending"}}`
	if err := os.WriteFile(filepath.Join(pendingDir, "plugin.json"), []byte(pendingManifest), 0600); err != nil {
		t.Fatal(err)
	}
	if err := appsMgr.ReloadFromMCP(); err != nil {
		t.Fatal(err)
	}
	if resMemberLaunch := call(http.MethodPost, "/api/v2/apps/mcp-pending/launch", memberTok2, []byte(`{}`), nil); resMemberLaunch.Code != http.StatusForbidden {
		t.Fatalf("AUTH-01: expected 403 when member calls /launch on pending plugin, got %d %s", resMemberLaunch.Code, resMemberLaunch.Body.String())
	}
	if resMemberStart := call(http.MethodPost, "/api/v2/apps/mcp-pending/start", memberTok2, []byte(`{}`), nil); resMemberStart.Code != http.StatusForbidden {
		t.Fatalf("AUTH-01: expected 403 when member calls /start on pending plugin, got %d %s", resMemberStart.Code, resMemberStart.Body.String())
	}
	stillPending, err := appsMgr.GetForUser("mcp-pending", 1, auth.RoleAdmin)
	if err != nil || !stillPending.PendingActivation {
		t.Fatalf("AUTH-01: expected mcp-pending to remain PendingActivation after blocked member attempts, got %+v %v", stillPending, err)
	}
}

func TestLANMCPEndpointsDebugProbeAndTokenRotation(t *testing.T) {
	dataDir := t.TempDir()
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

	appsMgr := apps.NewManager(dataDir, "lightisled", nil)
	defer appsMgr.Close()
	if err := appsMgr.Reload(); err != nil {
		t.Fatal(err)
	}

	handler := WithApps(New("", accounts, nil), "", accounts, appsMgr)
	call := func(method, path, session, remoteAddr string, body []byte, headers map[string]string) *httptest.ResponseRecorder {
		t.Helper()
		req := httptest.NewRequest(method, path, bytes.NewReader(body))
		if remoteAddr != "" {
			req.RemoteAddr = remoteAddr
		}
		if session != "" {
			req.AddCookie(&http.Cookie{Name: sessionCookie, Value: session})
		}
		if len(body) > 0 {
			req.Header.Set("Content-Type", "application/json")
		}
		if method != http.MethodGet {
			req.Header.Set("X-LightIsle-Request", "1")
		}
		for k, v := range headers {
			req.Header.Set(k, v)
		}
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		return rec
	}

	// 1. Enable local MCP only (mcpLanEnabled = false)
	resMcpLocal := call(http.MethodPut, "/api/v2/apps/mcp", adminTok, "127.0.0.1:50000", []byte(`{"mcpEnabled":true,"mcpLanEnabled":false}`), nil)
	if resMcpLocal.Code != http.StatusOK {
		t.Fatalf("PUT /api/v2/apps/mcp failed: %d %s", resMcpLocal.Code, resMcpLocal.Body.String())
	}
	mcpToken := appsMgr.ReadMCPToken()
	if mcpToken == "" {
		t.Fatal("expected non-empty mcpToken")
	}

	// LAN client rejected when mcpLanEnabled is false
	rpcInit := []byte(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`)
	resLanBlocked := call(http.MethodPost, "/api/v2/mcp", "", "192.168.1.50:54321", rpcInit, map[string]string{
		"Authorization": "Bearer " + mcpToken,
	})
	if resLanBlocked.Code != http.StatusForbidden || !strings.Contains(resLanBlocked.Body.String(), "mcp_lan_disabled") {
		t.Fatalf("expected 403 mcp_lan_disabled from LAN IP when mcpLanEnabled=false, got %d %s", resLanBlocked.Code, resLanBlocked.Body.String())
	}

	// 2. Enable LAN MCP
	resMcpLan := call(http.MethodPut, "/api/v2/apps/mcp", adminTok, "127.0.0.1:50000", []byte(`{"mcpEnabled":true,"mcpLanEnabled":true}`), nil)
	if resMcpLan.Code != http.StatusOK {
		t.Fatalf("enable LAN MCP failed: %d %s", resMcpLan.Code, resMcpLan.Body.String())
	}

	// LAN client succeeds with valid Bearer token
	resLanOK := call(http.MethodPost, "/api/v2/mcp", "", "192.168.1.50:54321", rpcInit, map[string]string{
		"Authorization": "Bearer " + mcpToken,
	})
	if resLanOK.Code != http.StatusOK || !strings.Contains(resLanOK.Body.String(), "lightisle-mcp") {
		t.Fatalf("expected 200 OK from LAN IP with valid Bearer token, got %d %s", resLanOK.Code, resLanOK.Body.String())
	}

	// Public WAN IP rejected even with valid Bearer token
	resWanBlocked := call(http.MethodPost, "/api/v2/mcp", "", "8.8.8.8:54321", rpcInit, map[string]string{
		"Authorization": "Bearer " + mcpToken,
	})
	if resWanBlocked.Code != http.StatusForbidden || !strings.Contains(resWanBlocked.Body.String(), "mcp_lan_only") {
		t.Fatalf("expected 403 mcp_lan_only from public WAN IP, got %d %s", resWanBlocked.Code, resWanBlocked.Body.String())
	}

	// 3. Rotate token -> old token rejected, new token accepted
	resRotate := call(http.MethodPost, "/api/v2/apps/mcp/token/rotate", adminTok, "127.0.0.1:50000", []byte(`{}`), nil)
	if resRotate.Code != http.StatusOK {
		t.Fatalf("token rotate failed: %d %s", resRotate.Code, resRotate.Body.String())
	}
	newToken := appsMgr.ReadMCPToken()
	if newToken == "" || newToken == mcpToken {
		t.Fatalf("expected rotated token, got %q", newToken)
	}
	resOldToken := call(http.MethodPost, "/api/v2/mcp", "", "192.168.1.50:54321", rpcInit, map[string]string{
		"Authorization": "Bearer " + mcpToken,
	})
	if resOldToken.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 with old token after rotation, got %d", resOldToken.Code)
	}

	// 4. Scaffold, Probe, Debug, and Logs endpoints
	resScaffold := call(http.MethodPost, "/api/v2/apps/scaffold", adminTok, "127.0.0.1:50000", []byte(`{"id":"probe-demo","name":"探针测试","mode":"static"}`), nil)
	if resScaffold.Code != http.StatusOK {
		t.Fatalf("POST /api/v2/apps/scaffold failed: %d %s", resScaffold.Code, resScaffold.Body.String())
	}
	resProbe := call(http.MethodPost, "/api/v2/apps/probe-demo/probe", adminTok, "127.0.0.1:50000", []byte(`{"method":"GET","path":"/"}`), nil)
	if resProbe.Code != http.StatusOK || !strings.Contains(resProbe.Body.String(), `"statusCode":200`) {
		t.Fatalf("POST /api/v2/apps/probe-demo/probe failed: %d %s", resProbe.Code, resProbe.Body.String())
	}
	resDebug := call(http.MethodPost, "/api/v2/apps/mcp/debug", adminTok, "127.0.0.1:50000", []byte(`{"method":"tools/list"}`), nil)
	if resDebug.Code != http.StatusOK || !strings.Contains(resDebug.Body.String(), "lightisle_probe_app") {
		t.Fatalf("POST /api/v2/apps/mcp/debug failed: %d %s", resDebug.Code, resDebug.Body.String())
	}
	resLogs := call(http.MethodGet, "/api/v2/apps/mcp/logs", adminTok, "127.0.0.1:50000", nil, nil)
	if resLogs.Code != http.StatusOK || !strings.Contains(resLogs.Body.String(), `"logs":[`) {
		t.Fatalf("GET /api/v2/apps/mcp/logs failed: %d %s", resLogs.Code, resLogs.Body.String())
	}
	resClearLogs := call(http.MethodDelete, "/api/v2/apps/mcp/logs", adminTok, "127.0.0.1:50000", nil, nil)
	if resClearLogs.Code != http.StatusOK {
		t.Fatalf("DELETE /api/v2/apps/mcp/logs failed: %d %s", resClearLogs.Code, resClearLogs.Body.String())
	}
}
