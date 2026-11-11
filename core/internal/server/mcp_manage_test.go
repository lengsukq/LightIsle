package server

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/apps"
	"github.com/lengsukq/lightisle/core/internal/automation"
	"github.com/lengsukq/lightisle/core/internal/notify"
)

func TestMCPUnifiedManagementCapabilitiesRBACAndHighRiskGuardrails(t *testing.T) {
	f := newRootRoutingFixture(t, RootServerOptions{EnableDiscovery: true})

	// Seed a test file on Root A and grant member read/write on "shared" subtree.
	sharedFile := filepath.Join(f.pathA, "shared", "notes.txt")
	if err := os.MkdirAll(filepath.Dir(sharedFile), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(sharedFile, []byte("hello from lightisle nas"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := f.accounts.SetRootGrant(f.admin, f.memberID, f.rootA.ID, "shared", true); err != nil {
		t.Fatal(err)
	}

	// Seed a local automation script with a custom email template to verify preservation & trigger.
	markerPath := filepath.Join(f.dataDir, "triggered-marker.txt")
	scriptDir := filepath.Join(f.dataDir, "automation", "scripts", "daily-check")
	if err := os.MkdirAll(scriptDir, 0700); err != nil {
		t.Fatal(err)
	}
	scriptContent := "#!/bin/sh\necho ran > " + markerPath + "\n"
	if err := os.WriteFile(filepath.Join(scriptDir, "run.sh"), []byte(scriptContent), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(scriptDir, "mail.html"), []byte("<p>custom-mail</p>"), 0600); err != nil {
		t.Fatal(err)
	}
	taskJSON := `{"schemaVersion":1,"id":"daily-check","name":"每日巡检","enabled":false,"entry":"run.sh","schedule":{"cron":"0 9 * * *","timezone":"Asia/Shanghai"},"notification":{"events":["failure"],"channels":[],"email":{"mode":"content","file":"mail.html","subject":"巡检报告"}}}`
	if err := os.WriteFile(filepath.Join(scriptDir, "task.json"), []byte(taskJSON), 0600); err != nil {
		t.Fatal(err)
	}

	autoMgr, err := automation.New(f.dataDir, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer autoMgr.Close()
	hub, err := notify.New(notify.Config{})
	if err != nil {
		t.Fatal(err)
	}
	defer hub.Close()

	appsMgr := apps.NewManager(f.dataDir, "lightisled", autoMgr)
	defer appsMgr.Close()
	if err := appsMgr.Reload(); err != nil {
		t.Fatal(err)
	}
	if err := appsMgr.SetMCPEnabled(true); err != nil {
		t.Fatal(err)
	}

	var handler http.Handler = f.server
	handler = WithAutomation(handler, f.accounts, autoMgr, hub)
	handler = WithApps(handler, f.dataDir, f.accounts, appsMgr)

	// Create 3 MCP connections: admin write, member read-only, member read-write.
	_, adminBearer, err := f.accounts.CreateMCPConnection(f.admin, "admin-agent", true)
	if err != nil {
		t.Fatal(err)
	}
	_, memberROBearer, err := f.accounts.CreateMCPConnection(f.member, "member-ro", false)
	if err != nil {
		t.Fatal(err)
	}
	_, memberRWBearer, err := f.accounts.CreateMCPConnection(f.member, "member-rw", true)
	if err != nil {
		t.Fatal(err)
	}

	rpcCall := func(endpoint, bearer, method string, params any) map[string]any {
		t.Helper()
		payload, err := json.Marshal(map[string]any{
			"jsonrpc": "2.0",
			"id":      1,
			"method":  method,
			"params":  params,
		})
		if err != nil {
			t.Fatal(err)
		}
		req := httptest.NewRequest(http.MethodPost, endpoint, bytes.NewReader(payload))
		req.Host = "127.0.0.1:16666"
		req.RemoteAddr = "127.0.0.1:54000"
		req.Header.Set("Content-Type", "application/json")
		if bearer != "" {
			req.Header.Set("Authorization", "Bearer "+bearer)
		}
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("POST %s (%s) = %d %s", endpoint, method, rec.Code, rec.Body.String())
		}
		var out map[string]any
		if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
			t.Fatalf("invalid JSON-RPC response: %v (%s)", err, rec.Body.String())
		}
		return out
	}

	callTool := func(bearer, name string, args map[string]any) (map[string]any, bool) {
		t.Helper()
		resp := rpcCall("/api/v2/mcp", bearer, "tools/call", map[string]any{
			"name":      name,
			"arguments": args,
		})
		resMap, ok := resp["result"].(map[string]any)
		if !ok {
			t.Fatalf("tool %s missing result: %+v", name, resp)
		}
		isErr, _ := resMap["isError"].(bool)
		structured, _ := resMap["structuredContent"].(map[string]any)
		return structured, isErr
	}

	// 1. Initialize + Resources (including new mcp-security spec)
	initResp := rpcCall("/api/v2/mcp", adminBearer, "initialize", map[string]any{"protocolVersion": "2025-06-18"})
	initRes := initResp["result"].(map[string]any)
	srvInfo := initRes["serverInfo"].(map[string]any)
	if srvInfo["name"] != "lightisle-mcp" {
		t.Fatalf("unexpected serverInfo: %+v", srvInfo)
	}

	resList := rpcCall("/api/v2/mcp", adminBearer, "resources/list", map[string]any{})
	resSlice := resList["result"].(map[string]any)["resources"].([]any)
	if len(resSlice) < 4 {
		t.Fatalf("expected >=4 spec resources, got %d", len(resSlice))
	}
	secSpec := rpcCall("/api/v2/mcp", adminBearer, "resources/read", map[string]any{"uri": "lightisle://specs/mcp-security"})
	if !strings.Contains(mustJSON(secSpec), "Non-Negotiable High-Risk Exclusions") {
		t.Fatalf("expected mcp-security spec text, got %s", mustJSON(secSpec))
	}

	// 2. Verify High-Risk Exclusions & Role/Write Tool Filtering
	adminToolsResp := rpcCall("/api/v2/mcp", adminBearer, "tools/list", map[string]any{})
	adminToolItems := adminToolsResp["result"].(map[string]any)["tools"].([]any)
	if len(adminToolItems) < 60 {
		t.Fatalf("expected comprehensive admin tool catalog (>=60), got %d", len(adminToolItems))
	}
	forbiddenSubstrings := []string{"format", "purge", "delete_root", "unregister_root", "shell", "exec", "keychain"}
	adminToolSet := map[string]bool{}
	for _, raw := range adminToolItems {
		m := raw.(map[string]any)
		name := m["name"].(string)
		if adminToolSet[name] {
			t.Fatalf("duplicate tool definition: %s", name)
		}
		adminToolSet[name] = true
		for _, banned := range forbiddenSubstrings {
			if strings.Contains(name, banned) {
				t.Fatalf("high-risk tool %q must NEVER be exposed via MCP", name)
			}
		}
	}

	memberROToolsResp := rpcCall("/api/v2/mcp", memberROBearer, "tools/list", map[string]any{})
	for _, raw := range memberROToolsResp["result"].(map[string]any)["tools"].([]any) {
		name := raw.(map[string]any)["name"].(string)
		if name == "lightisle_get_system" || name == "lightisle_list_members" || name == "lightisle_create_folder" || name == "lightisle_move_to_trash" || name == "lightisle_scaffold_app" {
			t.Fatalf("read-only member must not see admin or write tool %q", name)
		}
	}

	// Read-only member calling admin tool or write tool is denied and audited.
	if out, isErr := callTool(memberROBearer, "lightisle_get_system", map[string]any{}); !isErr || out["error"] != "mcp_tool_forbidden" {
		t.Fatalf("expected mcp_tool_forbidden for member calling get_system, got %+v (err=%v)", out, isErr)
	}
	if out, isErr := callTool(memberROBearer, "lightisle_create_folder", map[string]any{"rootId": f.rootA.ID, "generation": f.rootA.Generation, "path": "shared/nope"}); !isErr || out["error"] != "mcp_tool_forbidden" {
		t.Fatalf("expected mcp_tool_forbidden for read-only member calling create_folder, got %+v (err=%v)", out, isErr)
	}

	// 3. Read-write member safe file lifecycle: create_folder -> read_file_text -> move_to_trash -> list_trash -> restore_trashed_file
	if out, isErr := callTool(memberRWBearer, "lightisle_create_folder", map[string]any{
		"rootId":     f.rootA.ID,
		"generation": f.rootA.Generation,
		"path":       "shared/from-agent",
	}); isErr || out["created"] != true {
		t.Fatalf("member RW create_folder failed: %+v", out)
	}
	if out, isErr := callTool(memberRWBearer, "lightisle_read_file_text", map[string]any{
		"rootId": f.rootA.ID,
		"path":   "shared/notes.txt",
	}); isErr || out["text"] != "hello from lightisle nas" {
		t.Fatalf("member RW read_file_text failed: %+v", out)
	}
	if out, isErr := callTool(memberRWBearer, "lightisle_move_to_trash", map[string]any{
		"rootId":     f.rootA.ID,
		"generation": f.rootA.Generation,
		"path":       "shared/notes.txt",
	}); isErr || out["trashed"] != true {
		t.Fatalf("member RW move_to_trash failed: %+v", out)
	}
	trashOut, isErr := callTool(memberRWBearer, "lightisle_list_trash", map[string]any{"rootId": f.rootA.ID})
	if isErr {
		t.Fatalf("list_trash failed: %+v", trashOut)
	}
	trashItems, _ := trashOut["entries"].([]any)
	if len(trashItems) != 1 {
		t.Fatalf("expected 1 trashed entry, got %+v", trashOut)
	}
	entryID := trashItems[0].(map[string]any)["id"].(string)
	if out, isErr := callTool(memberRWBearer, "lightisle_restore_trashed_file", map[string]any{
		"rootId":     f.rootA.ID,
		"generation": f.rootA.Generation,
		"entryId":    entryID,
	}); isErr {
		t.Fatalf("restore_trashed_file failed: %+v", out)
	}
	if rawRestored, err := os.ReadFile(sharedFile); err != nil || string(rawRestored) != "hello from lightisle nas" {
		t.Fatalf("expected restored file content, got err=%v body=%q", err, string(rawRestored))
	}

	// 4. Admin Member Management + Admin Account Self-Protection + Secret Redaction
	const secretPass = "SuperSecretPass-987654"
	createdMember, isErr := callTool(adminBearer, "lightisle_create_member", map[string]any{
		"username": "charlie",
		"password": secretPass,
		"role":     "member",
	})
	if isErr {
		t.Fatalf("create_member failed: %+v", createdMember)
	}
	charlieID := int64(createdMember["id"].(float64))
	if out, isErr := callTool(adminBearer, "lightisle_update_member", map[string]any{"userId": charlieID, "enabled": false}); isErr || out["updated"] != true {
		t.Fatalf("update_member failed: %+v", out)
	}
	// Attempting to disable or reset password of Admin user ID 1 MUST be blocked!
	if out, isErr := callTool(adminBearer, "lightisle_update_member", map[string]any{"userId": 1, "enabled": false}); !isErr || out["error"] != "protected_account" {
		t.Fatalf("admin account disable must be blocked with protected_account, got %+v", out)
	}
	if out, isErr := callTool(adminBearer, "lightisle_set_member_password", map[string]any{"userId": 1, "password": "AnotherPassword-12345"}); !isErr || out["error"] != "protected_account" {
		t.Fatalf("admin password reset must be blocked with protected_account, got %+v", out)
	}

	// Verify mcp-debug-log.json NEVER stores plaintext password!
	rawDebugLog, err := os.ReadFile(filepath.Join(f.dataDir, "mcp-debug-log.json"))
	if err != nil {
		t.Fatalf("expected mcp-debug-log.json to be written: %v", err)
	}
	if strings.Contains(string(rawDebugLog), secretPass) || strings.Contains(string(rawDebugLog), "AnotherPassword-12345") {
		t.Fatalf("plaintext password leaked into mcp-debug-log.json: %s", string(rawDebugLog))
	}

	// 5. Automation Schedule (preserving email template) & Trigger Execution
	autoTasks, isErr := callTool(adminBearer, "lightisle_list_automation_tasks", map[string]any{})
	if isErr {
		t.Fatalf("list_automation_tasks failed: %+v", autoTasks)
	}
	tasksSlice := autoTasks["tasks"].([]any)
	rev := tasksSlice[0].(map[string]any)["revision"].(string)
	if out, isErr := callTool(adminBearer, "lightisle_set_automation_schedule", map[string]any{
		"taskId":   "daily-check",
		"revision": rev,
		"enabled":  true,
		"cron":     "15 9 * * *",
		"timezone": "Asia/Shanghai",
		"events":   []string{"failure", "success"},
		"channels": []string{},
	}); isErr {
		t.Fatalf("set_automation_schedule failed: %+v", out)
	}
	savedTaskJSON, err := os.ReadFile(filepath.Join(scriptDir, "task.json"))
	if err != nil || !strings.Contains(string(savedTaskJSON), `"mail.html"`) || !strings.Contains(string(savedTaskJSON), `"巡检报告"`) {
		t.Fatalf("automation email template was not preserved: %s", string(savedTaskJSON))
	}
	if out, isErr := callTool(adminBearer, "lightisle_trigger_automation_task", map[string]any{"taskId": "daily-check"}); isErr || out["triggered"] != true {
		t.Fatalf("trigger_automation_task failed: %+v", out)
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(markerPath); err == nil {
			break
		}
		time.Sleep(30 * time.Millisecond)
	}
	if _, err := os.Stat(markerPath); err != nil {
		t.Fatalf("triggered automation script did not run: %v", err)
	}

	// 6. Managed Apps must NOT leak mcpToken, and approve/activate must be rejected by control_managed_app
	appsPayload, isErr := callTool(adminBearer, "lightisle_list_managed_apps", map[string]any{})
	if isErr {
		t.Fatalf("list_managed_apps failed: %+v", appsPayload)
	}
	if strings.Contains(mustJSON(appsPayload), appsMgr.ReadMCPToken()) || appsPayload["mcpToken"] != nil {
		t.Fatalf("list_managed_apps leaked mcpToken: %+v", appsPayload)
	}
	if out, isErr := callTool(adminBearer, "lightisle_control_managed_app", map[string]any{
		"appId":  "demo",
		"action": "approve",
	}); !isErr || out["error"] != "mcp_invalid_arguments" {
		t.Fatalf("approve action must be rejected by control_managed_app, got %+v", out)
	}

	// 7. SQLite Audit Log Verification & Internal Connection Hiding
	auditOut, isErr := callTool(adminBearer, "lightisle_get_audit_history", map[string]any{"limit": 50})
	if isErr {
		t.Fatalf("get_audit_history failed: %+v", auditOut)
	}
	events, _ := auditOut["events"].([]any)
	if len(events) < 8 {
		t.Fatalf("expected SQLite audit_events for MCP calls, got %d: %+v", len(events), auditOut)
	}

	// Also invoke via system reload token and verify internal "__system_mcp__" is hidden from user connection list.
	reloadTok := appsMgr.ReadMCPToken()
	if out, isErr := callTool(reloadTok, "lightisle_get_health", map[string]any{}); isErr || out["status"] != "ok" {
		t.Fatalf("system reload token call failed: %+v", out)
	}
	conns, err := f.accounts.ListMCPConnections(f.admin)
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range conns {
		if strings.HasPrefix(c.Label, "__") {
			t.Fatalf("internal system MCP connection leaked into user list: %+v", c)
		}
	}
}

func TestMCPStdioLoopbackBridgeAndSSERoundtrip(t *testing.T) {
	f := newRootRoutingFixture(t, RootServerOptions{EnableDiscovery: true})

	appsMgr := apps.NewManager(f.dataDir, "lightisled", nil)
	defer appsMgr.Close()
	if err := appsMgr.Reload(); err != nil {
		t.Fatal(err)
	}
	if err := appsMgr.SetMCPEnabled(true); err != nil {
		t.Fatal(err)
	}

	handler := WithApps(f.server, f.dataDir, f.accounts, appsMgr)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	appsMgr.SetEndpointProvider(func() (string, string) {
		return srv.URL, srv.URL
	})
	t.Setenv("LIGHTISLE_CORE_URL", srv.URL)

	// 1. Run `lightisled mcp` stdio bridge against the live HTTP daemon
	stdioIn := strings.Join([]string{
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}`,
		`{"jsonrpc":"2.0","method":"notifications/initialized"}`,
		`{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}`,
		`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"lightisle_create_folder","arguments":{"rootId":"` + f.rootA.ID + `","generation":` + strconv.FormatUint(f.rootA.Generation, 10) + `,"path":"stdio-created"}}}`,
	}, "\n") + "\n"

	var stdioOut bytes.Buffer
	if err := apps.RunMCP(context.Background(), f.dataDir, "lightisled", strings.NewReader(stdioIn), &stdioOut); err != nil {
		t.Fatalf("RunMCP stdio bridge failed: %v", err)
	}
	lines := strings.Split(strings.TrimSpace(stdioOut.String()), "\n")
	if len(lines) != 3 {
		t.Fatalf("expected 3 JSON-RPC responses (notification produces none), got %d:\n%s", len(lines), stdioOut.String())
	}
	if !strings.Contains(lines[1], "lightisle_list_roots") || !strings.Contains(lines[1], "lightisle_move_to_trash") {
		t.Fatalf("stdio tools/list did not return full NAS management tools: %s", lines[1])
	}
	if info, err := os.Stat(filepath.Join(f.pathA, "stdio-created")); err != nil || !info.IsDir() {
		t.Fatalf("stdio tools/call did not create folder on live root: %v (resp=%s)", err, lines[2])
	}

	// 2. Reverse-proxy header must be rejected with 403 mcp_lan_only
	proxyReq, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/v2/mcp", strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"ping"}`))
	proxyReq.Header.Set("Authorization", "Bearer "+appsMgr.ReadMCPToken())
	proxyReq.Header.Set("Content-Type", "application/json")
	proxyReq.Header.Set("X-Forwarded-For", "203.0.113.9")
	proxyResp, err := http.DefaultClient.Do(proxyReq)
	if err != nil {
		t.Fatal(err)
	}
	proxyResp.Body.Close()
	if proxyResp.StatusCode != http.StatusForbidden {
		t.Fatalf("expected 403 when X-Forwarded-For is set, got %d", proxyResp.StatusCode)
	}

	// 3. SSE transport roundtrip using an Agent Connection Bearer token
	_, agentBearer, err := f.accounts.CreateMCPConnection(f.admin, "sse-agent", true)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	sseReq, _ := http.NewRequestWithContext(ctx, http.MethodGet, srv.URL+"/api/v2/mcp/sse", nil)
	sseReq.Header.Set("Authorization", "Bearer "+agentBearer)
	sseResp, err := http.DefaultClient.Do(sseReq)
	if err != nil {
		t.Fatal(err)
	}
	defer sseResp.Body.Close()
	if sseResp.StatusCode != http.StatusOK {
		t.Fatalf("SSE open failed: %d", sseResp.StatusCode)
	}

	reader := bufio.NewReader(sseResp.Body)
	var msgEndpoint string
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			t.Fatalf("reading SSE endpoint event: %v", err)
		}
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "data: ") {
			msgEndpoint = strings.TrimPrefix(line, "data: ")
			break
		}
	}
	postReq, _ := http.NewRequestWithContext(ctx, http.MethodPost, srv.URL+msgEndpoint, strings.NewReader(`{"jsonrpc":"2.0","id":99,"method":"tools/call","params":{"name":"lightisle_list_roots","arguments":{}}}`))
	postReq.Header.Set("Authorization", "Bearer "+agentBearer)
	postReq.Header.Set("Content-Type", "application/json")
	postResp, err := http.DefaultClient.Do(postReq)
	if err != nil {
		t.Fatal(err)
	}
	postResp.Body.Close()
	if postResp.StatusCode != http.StatusAccepted {
		t.Fatalf("SSE message POST = %d", postResp.StatusCode)
	}

	var sseMessage string
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			t.Fatalf("reading SSE message event: %v", err)
		}
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "data: ") {
			sseMessage = strings.TrimPrefix(line, "data: ")
			break
		}
	}
	if !strings.Contains(sseMessage, f.rootA.ID) || !strings.Contains(sseMessage, `"id":99`) {
		t.Fatalf("SSE response did not contain list_roots payload: %s", sseMessage)
	}
}

func mustJSON(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}
