package apps

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/automation"
)

func TestBuiltInDemoAppAndStaticGateway(t *testing.T) {
	dataDir := t.TempDir()
	autoMgr, err := automation.New(dataDir, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer autoMgr.Close()

	mgr := NewManager(dataDir, "lightisled", autoMgr)
	defer mgr.Close()
	if err := mgr.Reload(); err != nil {
		t.Fatal(err)
	}

	adminApps := mgr.ListForUser(1, "admin")
	if len(adminApps) != 1 || adminApps[0].ID != "network-pulse" || !adminApps[0].Valid {
		t.Fatalf("expected built-in network-pulse demo app, got %+v", adminApps)
	}
	if adminApps[0].Web.Status != StatusStatic {
		t.Fatalf("expected static status, got %s", adminApps[0].Web.Status)
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mgr.ServeApp(w, r, func(_ *http.Request) (UserIdentity, bool) {
			return UserIdentity{ID: 2, Username: "alice", Role: "member"}, true
		})
	}))
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/apps/network-pulse/")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK || !strings.Contains(string(body), "轻屿网络与系统脉搏") {
		t.Fatalf("unexpected static response: %d %s", resp.StatusCode, string(body))
	}
	if got := resp.Header.Get("X-Frame-Options"); got != "SAMEORIGIN" {
		t.Fatalf("expected X-Frame-Options SAMEORIGIN, got %q", got)
	}
	if got := resp.Header.Get("Content-Security-Policy"); !strings.Contains(got, "frame-ancestors 'self'") {
		t.Fatalf("expected frame-ancestors 'self', got %q", got)
	}

	// Icon endpoint
	iconResp, err := http.Get(srv.URL + "/apps/network-pulse/__lightisle_icon")
	if err != nil {
		t.Fatal(err)
	}
	iconResp.Body.Close()
	if iconResp.StatusCode != http.StatusOK || !strings.Contains(iconResp.Header.Get("Content-Type"), "image/svg+xml") {
		t.Fatalf("unexpected icon response: %d %s", iconResp.StatusCode, iconResp.Header.Get("Content-Type"))
	}

	// Deleting demo app should not recreate it on reload because .demo-initialized exists
	if err := mgr.DeleteApp("network-pulse", true); err != nil {
		t.Fatal(err)
	}
	if len(mgr.ListForUser(1, "admin")) != 0 {
		t.Fatal("expected 0 apps after deleting demo app")
	}
}

func TestOnDemandWakeSingleflightProxyIsolationAndIdleReaper(t *testing.T) {
	dataDir := t.TempDir()
	mgr := NewManager(dataDir, "lightisled", nil)
	mgr.SetReapInterval(80 * time.Millisecond)
	defer mgr.Close()

	pluginDir := filepath.Join(dataDir, "plugins", "echo-app")
	if err := os.MkdirAll(pluginDir, 0700); err != nil {
		t.Fatal(err)
	}
	manifest := PluginManifest{
		SchemaVersion: 2,
		ID:            "echo-app",
		Name:          "Echo On-Demand",
		Version:       "1.0.0",
		Access:        AccessConfig{Policy: AccessSelectedMembers, AllowedUserIDs: []int64{42}},
		Web: &WebConfig{
			Enabled:             true,
			Mode:                WebModeOnDemand,
			Runtime:             "python",
			Entry:               "run-web.sh",
			Port:                0,
			BasePath:            "/apps/echo-app",
			IdleTimeoutSeconds:  1,
			ReadyTimeoutSeconds: 10,
		},
	}
	rawManifest, _ := json.MarshalIndent(manifest, "", "  ")
	if err := os.WriteFile(filepath.Join(pluginDir, "plugin.json"), rawManifest, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(pluginDir, "env.json"), []byte(`{"GREETING":"hello-from-env"}`), 0600); err != nil {
		t.Fatal(err)
	}
	script := `#!/bin/sh
set -eu
exec python3 -c '
import http.server, os, json
port = int(os.environ["PORT"])
secret = os.environ["LIGHTISLE_PROXY_SECRET"]
greeting = os.environ.get("GREETING", "")
data_dir = os.environ.get("LIGHTISLE_PLUGIN_DATA_DIR", "")
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        payload = {
            "path": self.path,
            "secretMatch": self.headers.get("X-LightIsle-Proxy-Secret") == secret and len(secret) == 64,
            "userId": self.headers.get("X-LightIsle-User-ID"),
            "username": self.headers.get("X-LightIsle-Username"),
            "role": self.headers.get("X-LightIsle-Role"),
            "authHeader": self.headers.get("Authorization", ""),
            "proxyAuthHeader": self.headers.get("Proxy-Authorization", ""),
            "spoofedHeader": self.headers.get("X-LightIsle-Spoof", ""),
            "cookie": self.headers.get("Cookie", ""),
            "greeting": greeting,
            "dataDirExists": os.path.isdir(data_dir),
            "pid": os.getpid(),
        }
        raw = json.dumps(payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)
    def log_message(self, format, *args):
        pass
class S(http.server.ThreadingHTTPServer):
    request_queue_size = 64
S(("127.0.0.1", port), H).serve_forever()
'
`
	if err := os.WriteFile(filepath.Join(pluginDir, "run-web.sh"), []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	if err := mgr.Reload(); err != nil {
		t.Fatal(err)
	}

	appView, err := mgr.GetForUser("echo-app", 1, "admin")
	if err != nil || appView.Web.Status != StatusSleeping {
		t.Fatalf("expected initial sleeping state, got %+v %v", appView, err)
	}

	// Verify RBAC for selected_members
	if !mgr.CanAccess("echo-app", 1, "admin") {
		t.Fatal("admin should have access")
	}
	if !mgr.CanAccess("echo-app", 42, "member") {
		t.Fatal("allowed member 42 should have access")
	}
	if mgr.CanAccess("echo-app", 99, "member") {
		t.Fatal("unlisted member 99 should not have access")
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mgr.ServeApp(w, r, func(req *http.Request) (UserIdentity, bool) {
			if req.Header.Get("X-Test-User") == "member42" {
				return UserIdentity{ID: 42, Username: "bob", Role: "member"}, true
			}
			if req.Header.Get("X-Test-User") == "member99" {
				return UserIdentity{ID: 99, Username: "eve", Role: "member"}, true
			}
			return UserIdentity{}, false
		})
	}))
	defer srv.Close()

	// Forbidden user gets 403 without waking process
	reqForbidden, _ := http.NewRequest(http.MethodGet, srv.URL+"/apps/echo-app/test", nil)
	reqForbidden.Header.Set("X-Test-User", "member99")
	respForbidden, err := http.DefaultClient.Do(reqForbidden)
	if err != nil {
		t.Fatal(err)
	}
	respForbidden.Body.Close()
	if respForbidden.StatusCode != http.StatusForbidden {
		t.Fatalf("expected 403 for member99, got %d", respForbidden.StatusCode)
	}

	// Concurrent requests coalesce onto a single process via singleflight Wake
	const concurrency = 6
	var wg sync.WaitGroup
	pids := make([]int, concurrency)
	errs := make([]error, concurrency)
	for i := range concurrency {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			req, _ := http.NewRequest(http.MethodGet, srv.URL+"/apps/echo-app/api/info", nil)
			req.Header.Set("X-Test-User", "member42")
			req.Header.Set("Authorization", "Bearer super-secret-host-bearer-token")
			req.Header.Set("Proxy-Authorization", "Basic secret-proxy")
			req.Header.Set("X-LightIsle-Role", "admin")
			req.Header.Set("X-LightIsle-Spoof", "evil")
			req.AddCookie(&http.Cookie{Name: "lightisle_session", Value: "super-secret-host-session"})
			req.AddCookie(&http.Cookie{Name: "lightisle_app_echo-app", Value: "gateway-cookie"})
			req.AddCookie(&http.Cookie{Name: "custom_cookie", Value: "kept"})
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				errs[idx] = err
				return
			}
			defer resp.Body.Close()
			var data struct {
				SecretMatch     bool   `json:"secretMatch"`
				UserID          string `json:"userId"`
				Username        string `json:"username"`
				Role            string `json:"role"`
				AuthHeader      string `json:"authHeader"`
				ProxyAuthHeader string `json:"proxyAuthHeader"`
				SpoofedHeader   string `json:"spoofedHeader"`
				Cookie          string `json:"cookie"`
				Greeting        string `json:"greeting"`
				DataDirExists   bool   `json:"dataDirExists"`
				PID             int    `json:"pid"`
			}
			if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
				errs[idx] = err
				return
			}
			if !data.SecretMatch || data.UserID != "42" || data.Username != "bob" || data.Role != "member" ||
				data.AuthHeader != "" || data.ProxyAuthHeader != "" || data.SpoofedHeader != "" ||
				strings.Contains(data.Cookie, "lightisle_") || !strings.Contains(data.Cookie, "custom_cookie=kept") ||
				data.Greeting != "hello-from-env" || !data.DataDirExists {
				t.Errorf("unexpected proxy payload: %+v", data)
			}
			pids[idx] = data.PID
		}(i)
	}
	wg.Wait()
	for i := range concurrency {
		if errs[i] != nil {
			t.Fatalf("request %d failed: %v", i, errs[i])
		}
		if pids[i] <= 0 || pids[i] != pids[0] {
			t.Fatalf("expected all concurrent requests to hit same PID, got %v", pids)
		}
	}

	// Wait for idle reaper (idleTimeoutSeconds = 1s)
	deadline := time.Now().Add(4 * time.Second)
	reaped := false
	for time.Now().Before(deadline) {
		view, _ := mgr.GetForUser("echo-app", 1, "admin")
		if view.Web.Status == StatusSleeping && view.Web.PID == 0 && view.Web.RSSBytes == 0 {
			reaped = true
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if !reaped {
		view, _ := mgr.GetForUser("echo-app", 1, "admin")
		t.Fatalf("expected on-demand app to return to sleeping after idle timeout, got %+v", view.Web)
	}
}

func TestLaunchTicketSingleUseAndScopedCookie(t *testing.T) {
	dataDir := t.TempDir()
	mgr := NewManager(dataDir, "lightisled", nil)
	defer mgr.Close()
	if err := mgr.Reload(); err != nil {
		t.Fatal(err)
	}

	user := UserIdentity{ID: 7, Username: "mobileuser", Role: "member", SessionToken: "raw-host-session-secret-token-999"}
	ticket := mgr.IssueTicket("network-pulse", user)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mgr.ServeApp(w, r, nil)
	}))
	defer srv.Close()

	noRedirectClient := &http.Client{
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}

	// 1. SEC-01: Exchange single-use ticket -> 302 Redirect to clean /apps/network-pulse/ (NO credential in URL) + encrypted HttpOnly Set-Cookie
	resp, err := noRedirectClient.Get(srv.URL + "/apps/network-pulse?__li_ticket=" + ticket)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusFound {
		t.Fatalf("expected 302 redirect on ticket exchange, got %d", resp.StatusCode)
	}
	loc := resp.Header.Get("Location")
	if loc != "/apps/network-pulse/" || strings.Contains(loc, "_s/") || strings.Contains(loc, "__li_ticket") {
		t.Fatalf("expected clean redirect location /apps/network-pulse/ without URL credentials, got %q", loc)
	}
	var appCookie *http.Cookie
	for _, c := range resp.Cookies() {
		if c.Name == "lightisle_app_network-pulse" {
			appCookie = c
			break
		}
	}
	if appCookie == nil || appCookie.Path != "/apps/network-pulse" || !appCookie.HttpOnly {
		t.Fatalf("expected scoped HttpOnly app cookie, got %+v", appCookie)
	}
	// Verify cookie is AES-256-GCM encrypted and NEVER contains raw SessionToken or plaintext JSON
	if strings.Contains(appCookie.Value, "raw-host-session-secret-token-999") || strings.Contains(appCookie.Value, "mobileuser") {
		t.Fatalf("app cookie leaked raw session token or username: %s", appCookie.Value)
	}
	// Verify legacy /_s/<token>/ URL is NOT accepted as an authentication credential
	reqLegacyURL, _ := http.NewRequest(http.MethodGet, srv.URL+"/apps/network-pulse/_s/"+appCookie.Value+"/", nil)
	respLegacyURL, err := http.DefaultClient.Do(reqLegacyURL)
	if err != nil {
		t.Fatal(err)
	}
	respLegacyURL.Body.Close()
	if respLegacyURL.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401 when attempting to authenticate via URL path token, got %d", respLegacyURL.StatusCode)
	}

	// 2. Replaying the same ticket is rejected (single-use)
	respReplay, err := noRedirectClient.Get(srv.URL + "/apps/network-pulse?__li_ticket=" + ticket)
	if err != nil {
		t.Fatal(err)
	}
	respReplay.Body.Close()
	if respReplay.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401 on replayed ticket, got %d", respReplay.StatusCode)
	}

	// 3. Using the scoped cookie without main session succeeds while user/session is active
	sessionActive := true
	mgr.SetUserVerifier(func(u UserIdentity) (UserIdentity, bool) {
		if !sessionActive || u.ID != 7 {
			return UserIdentity{}, false
		}
		return u, true
	})
	reqWithCookie, _ := http.NewRequest(http.MethodGet, srv.URL+"/apps/network-pulse/", nil)
	reqWithCookie.AddCookie(appCookie)
	respOK, err := http.DefaultClient.Do(reqWithCookie)
	if err != nil {
		t.Fatal(err)
	}
	respOK.Body.Close()
	if respOK.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 with scoped app cookie, got %d", respOK.StatusCode)
	}

	// 4. P0-6: Once the user logs out or account is disabled, the old app cookie is immediately rejected (401)
	sessionActive = false
	reqRevoked, _ := http.NewRequest(http.MethodGet, srv.URL+"/apps/network-pulse/", nil)
	reqRevoked.AddCookie(appCookie)
	respRevoked, err := http.DefaultClient.Do(reqRevoked)
	if err != nil {
		t.Fatal(err)
	}
	respRevoked.Body.Close()
	if respRevoked.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401 after user session revocation/disable, got %d", respRevoked.StatusCode)
	}

	// 5. P0-3: Updating member access on static network-pulse (which has no Cron module) succeeds
	updatedStatic, err := mgr.UpdateApp("network-pulse", AppUpdateRequest{
		Access: &AccessConfig{
			Policy:         AccessSelectedMembers,
			AllowedUserIDs: []int64{2},
		},
	})
	if err != nil || updatedStatic.Access.Policy != AccessSelectedMembers || len(updatedStatic.Access.AllowedUserIDs) != 1 || updatedStatic.Access.AllowedUserIDs[0] != 2 {
		t.Fatalf("expected static app member access update to succeed, got %+v %v", updatedStatic, err)
	}
}

func TestPluginCronRegistrationExecutionAndPreservation(t *testing.T) {
	dataDir := t.TempDir()
	autoMgr, err := automation.New(dataDir, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer autoMgr.Close()

	mgr := NewManager(dataDir, "lightisled", autoMgr)
	defer mgr.Close()

	pluginDir := filepath.Join(dataDir, "plugins", "cpe-watchdog")
	if err := os.MkdirAll(pluginDir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(pluginDir, "email.html"), []byte("<p>{{task.name}} {{run.state}}</p>"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(pluginDir, "env.json"), []byte(`{"CPE_HOST":"192.168.8.1"}`), 0600); err != nil {
		t.Fatal(err)
	}
	cronScript := `#!/bin/sh
set -eu
echo "host=$CPE_HOST dir=$LIGHTISLE_PLUGIN_DIR data=$LIGHTISLE_PLUGIN_DATA_DIR"
echo "$CPE_HOST" > "$LIGHTISLE_PLUGIN_DATA_DIR/last_host.txt"
`
	if err := os.WriteFile(filepath.Join(pluginDir, "run-cron.sh"), []byte(cronScript), 0700); err != nil {
		t.Fatal(err)
	}
	manifest := PluginManifest{
		SchemaVersion: 2,
		ID:            "cpe-watchdog",
		Name:          "CPE 掉线自愈",
		Version:       "1.0.0",
		Access:        AccessConfig{Policy: AccessAdminOnly, AllowedUserIDs: []int64{}},
		Cron: &CronConfig{
			Enabled:        true,
			Entry:          "run-cron.sh",
			Schedule:       automation.Schedule{Cron: "*/15 * * * *", Timezone: "Asia/Shanghai"},
			TimeoutSeconds: 60,
			Notification: automation.Notification{
				Events:   []string{"failure", "timeout"},
				Channels: []string{"email"},
				Email: &automation.EmailTemplate{
					Mode:    "content",
					File:    "email.html",
					Subject: "CPE 状态告警",
				},
			},
		},
	}
	raw, _ := json.MarshalIndent(manifest, "", "  ")
	if err := os.WriteFile(filepath.Join(pluginDir, "plugin.json"), raw, 0600); err != nil {
		t.Fatal(err)
	}

	if err := mgr.Reload(); err != nil {
		t.Fatal(err)
	}
	// Reloading automation.Manager must preserve plugin tasks!
	if err := autoMgr.Reload(); err != nil {
		t.Fatal(err)
	}
	if _, ok := autoMgr.GetTaskView("app-cpe-watchdog"); !ok {
		t.Fatal("expected app-cpe-watchdog to remain registered after automation.Reload()")
	}

	if err := autoMgr.RunSync("app-cpe-watchdog"); err != nil {
		t.Fatal(err)
	}
	runs, err := mgr.GetCronRuns("cpe-watchdog", 10)
	if err != nil || len(runs) != 1 || runs[0].State != "success" || !strings.Contains(runs[0].Output, "host=192.168.8.1") {
		t.Fatalf("unexpected plugin cron run history: %+v %v", runs, err)
	}
	savedHost, err := os.ReadFile(filepath.Join(dataDir, "plugin-data", "cpe-watchdog", "last_host.txt"))
	if err != nil || strings.TrimSpace(string(savedHost)) != "192.168.8.1" {
		t.Fatalf("expected cron script to write to LIGHTISLE_PLUGIN_DATA_DIR, got %q %v", string(savedHost), err)
	}

	// Updating cron schedule via UpdateApp preserves notification.email
	newCron := "*/30 * * * *"
	updated, err := mgr.UpdateApp("cpe-watchdog", AppUpdateRequest{
		Cron: &CronUpdateInput{
			Cron:     &newCron,
			Events:   []string{"success", "failure"},
			Channels: []string{"bark", "email"},
		},
	})
	if err != nil || updated.Cron.Cron != "*/30 * * * *" {
		t.Fatalf("unexpected updated cron view: %+v %v", updated, err)
	}
	diskRaw, _ := os.ReadFile(filepath.Join(pluginDir, "plugin.json"))
	if !strings.Contains(string(diskRaw), `"email.html"`) || !strings.Contains(string(diskRaw), `"CPE 状态告警"`) {
		t.Fatalf("UpdateApp lost script-owned notification.email settings: %s", string(diskRaw))
	}
}

func TestMCPSwitchAndToolsEndToEnd(t *testing.T) {
	dataDir := t.TempDir()
	mgr := NewManager(dataDir, "lightisled", nil)
	defer mgr.Close()
	if err := mgr.Reload(); err != nil {
		t.Fatal(err)
	}

	callMCP := func(reqs ...map[string]any) []jsonRPCResponse {
		var inBuf, outBuf bytes.Buffer
		for _, r := range reqs {
			line, _ := json.Marshal(r)
			inBuf.Write(line)
			inBuf.WriteByte('\n')
		}
		if err := RunMCP(context.Background(), dataDir, "lightisled", &inBuf, &outBuf); err != nil {
			t.Fatalf("RunMCP error: %v", err)
		}
		var resps []jsonRPCResponse
		for _, line := range bytes.Split(bytes.TrimSpace(outBuf.Bytes()), []byte("\n")) {
			if len(line) == 0 {
				continue
			}
			var resp jsonRPCResponse
			if err := json.Unmarshal(line, &resp); err != nil {
				t.Fatalf("unmarshal response %q: %v", string(line), err)
			}
			resps = append(resps, resp)
		}
		return resps
	}

	// 1. Default MCPEnabled is false -> tools/call is blocked with clear guidance
	if mgr.MCPEnabled() {
		t.Fatal("expected MCPEnabled false by default")
	}
	resps := callMCP(
		map[string]any{"jsonrpc": "2.0", "id": 1, "method": "initialize"},
		map[string]any{"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": map[string]any{"name": "lightisle_get_environment"}},
		map[string]any{"jsonrpc": "2.0", "id": 3, "method": "resources/read", "params": map[string]any{"uri": "lightisle://specs/plugin-v2"}},
	)
	if len(resps) != 3 {
		t.Fatalf("expected 3 responses, got %d", len(resps))
	}
	rawToolBlocked, _ := json.Marshal(resps[1].Result)
	if !strings.Contains(string(rawToolBlocked), MCPDisabledMessage) || !strings.Contains(string(rawToolBlocked), `"isError":true`) {
		t.Fatalf("expected MCP disabled message on tools/call, got %s", string(rawToolBlocked))
	}
	if resps[2].Error == nil || resps[2].Error.Message != MCPDisabledMessage {
		t.Fatalf("expected MCP disabled error on resources/read, got %+v", resps[2].Error)
	}

	// 2. Enable MCP and set up local-reload test listener
	mcpEnabled := true
	if _, err := mgr.SetMCPConfig(&mcpEnabled, nil); err != nil {
		t.Fatal(err)
	}
	if !mgr.MCPEnabled() {
		t.Fatal("expected MCPEnabled true")
	}
	reloadSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		tok := r.Header.Get("X-LightIsle-MCP-Token")
		if !mgr.VerifyReloadToken(tok) {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		_ = mgr.ReloadFromMCP()
		w.WriteHeader(http.StatusOK)
	}))
	defer reloadSrv.Close()
	t.Setenv("LIGHTISLE_CORE_URL", reloadSrv.URL)

	// 3. Call scaffold_app and validate_and_reload via MCP
	respsEnabled := callMCP(
		map[string]any{
			"jsonrpc": "2.0",
			"id":      10,
			"method":  "tools/call",
			"params": map[string]any{
				"name": "lightisle_scaffold_app",
				"arguments": map[string]any{
					"id":      "hello-mcp",
					"name":    "MCP Scaffolded App",
					"mode":    "on-demand",
					"runtime": "python",
					"hasCron": true,
				},
			},
		},
		map[string]any{
			"jsonrpc": "2.0",
			"id":      11,
			"method":  "tools/call",
			"params": map[string]any{
				"name":      "lightisle_validate_and_reload",
				"arguments": map[string]any{"id": "hello-mcp"},
			},
		},
	)
	if len(respsEnabled) != 2 {
		t.Fatalf("expected 2 responses, got %d", len(respsEnabled))
	}
	rawReloadRes, _ := json.Marshal(respsEnabled[1].Result)
	if !strings.Contains(string(rawReloadRes), `\"reloaded\": true`) && !strings.Contains(string(rawReloadRes), `"reloaded":true`) {
		t.Fatalf("expected validate_and_reload to hot-reload Core, got %s", string(rawReloadRes))
	}
	if _, err := mgr.GetForUser("hello-mcp", 1, "admin"); err != nil {
		t.Fatalf("expected scaffolded app hello-mcp to be loaded in Manager: %v", err)
	}

	// 4. P0-1: Calling lightisle_scaffold_app on an existing plugin ID returns conflict error and never overwrites user files
	envPath := filepath.Join(dataDir, "plugins", "hello-mcp", "env.json")
	customEnv := `{"USER_SECRET":"do-not-overwrite"}`
	if err := os.WriteFile(envPath, []byte(customEnv), 0600); err != nil {
		t.Fatal(err)
	}
	respsConflict := callMCP(map[string]any{
		"jsonrpc": "2.0",
		"id":      12,
		"method":  "tools/call",
		"params": map[string]any{
			"name": "lightisle_scaffold_app",
			"arguments": map[string]any{
				"id":      "hello-mcp",
				"name":    "Overwrite Attempt",
				"mode":    "static",
				"runtime": "static",
			},
		},
	})
	rawConflict, _ := json.Marshal(respsConflict[0].Result)
	if !strings.Contains(string(rawConflict), `"isError":true`) || !strings.Contains(string(rawConflict), "app_already_exists") {
		t.Fatalf("expected app_already_exists conflict error on existing plugin, got %s", string(rawConflict))
	}
	afterEnv, err := os.ReadFile(envPath)
	if err != nil || string(afterEnv) != customEnv {
		t.Fatalf("expected existing env.json to remain untouched, got %q %v", string(afterEnv), err)
	}

	// 5. P1-3 & P1-5: Scaffolding a Node.js app generates server.mjs/collect.mjs (not Python) and keeps PendingActivation=true & Cron.Enabled=false on MCP reload
	respsNode := callMCP(
		map[string]any{
			"jsonrpc": "2.0",
			"id":      13,
			"method":  "tools/call",
			"params": map[string]any{
				"name": "lightisle_scaffold_app",
				"arguments": map[string]any{
					"id":      "node-demo",
					"name":    "Node Demo App",
					"mode":    "persistent",
					"runtime": "node",
					"hasCron": true,
				},
			},
		},
		map[string]any{
			"jsonrpc": "2.0",
			"id":      14,
			"method":  "tools/call",
			"params": map[string]any{
				"name":      "lightisle_validate_and_reload",
				"arguments": map[string]any{"id": "node-demo"},
			},
		},
	)
	if len(respsNode) != 2 {
		t.Fatalf("expected 2 responses for node-demo, got %d", len(respsNode))
	}
	if _, err := os.Stat(filepath.Join(dataDir, "plugins", "node-demo", "server.mjs")); err != nil {
		t.Fatalf("expected node runtime scaffold to create server.mjs: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dataDir, "plugins", "node-demo", "collect.mjs")); err != nil {
		t.Fatalf("expected node cron scaffold to create collect.mjs: %v", err)
	}
	nodeApp, err := mgr.GetForUser("node-demo", 1, "admin")
	if err != nil {
		t.Fatalf("expected node-demo in manager: %v", err)
	}
	if !nodeApp.PendingActivation || nodeApp.Cron.Enabled || nodeApp.Web.Status == StatusRunning {
		t.Fatalf("expected MCP-reloaded persistent/cron app to stay PendingActivation with Cron disabled and Web stopped, got %+v", nodeApp)
	}

	// 6. P0-2: Ordinary Reload() (e.g. POST /api/v2/apps/refresh) AND Core restart (NewManager) MUST preserve PendingActivation!
	if err := mgr.Reload(); err != nil {
		t.Fatal(err)
	}
	nodeAfterRefresh, err := mgr.GetForUser("node-demo", 1, "admin")
	if err != nil || !nodeAfterRefresh.PendingActivation || nodeAfterRefresh.Web.Status == StatusRunning {
		t.Fatalf("expected PendingActivation to survive ordinary Reload(), got %+v %v", nodeAfterRefresh, err)
	}
	mgrRestarted := NewManager(dataDir, "lightisled", nil)
	defer mgrRestarted.Close()
	if err := mgrRestarted.Reload(); err != nil {
		t.Fatal(err)
	}
	nodeAfterRestart, err := mgrRestarted.GetForUser("node-demo", 1, "admin")
	if err != nil || !nodeAfterRestart.PendingActivation || nodeAfterRestart.Web.Status == StatusRunning {
		t.Fatalf("expected PendingActivation to survive Core restart, got %+v %v", nodeAfterRestart, err)
	}

	// 7. P1-5: Verify Go runtime scaffold generates main.go + collect.go, and unknown runtime is rejected
	respsGo := callMCP(
		map[string]any{
			"jsonrpc": "2.0",
			"id":      15,
			"method":  "tools/call",
			"params": map[string]any{
				"name": "lightisle_scaffold_app",
				"arguments": map[string]any{
					"id":      "go-demo",
					"name":    "Go Demo App",
					"mode":    "on-demand",
					"runtime": "go",
					"hasCron": true,
				},
			},
		},
		map[string]any{
			"jsonrpc": "2.0",
			"id":      16,
			"method":  "tools/call",
			"params": map[string]any{
				"name": "lightisle_scaffold_app",
				"arguments": map[string]any{
					"id":      "bad-rt",
					"name":    "Bad Runtime",
					"mode":    "on-demand",
					"runtime": "ruby-invalid",
				},
			},
		},
	)
	if len(respsGo) != 2 {
		t.Fatalf("expected 2 responses, got %d", len(respsGo))
	}
	if _, err := os.Stat(filepath.Join(dataDir, "plugins", "go-demo", "main.go")); err != nil {
		t.Fatalf("expected go scaffold to create main.go: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dataDir, "plugins", "go-demo", "collect.go")); err != nil {
		t.Fatalf("expected go cron scaffold to create collect.go: %v", err)
	}
	rawBadRT, _ := json.Marshal(respsGo[1].Result)
	if !strings.Contains(string(rawBadRT), `"isError":true`) {
		t.Fatalf("expected unknown runtime to return isError:true, got %s", string(rawBadRT))
	}
}
