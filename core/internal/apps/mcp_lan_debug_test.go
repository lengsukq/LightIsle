package apps

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

func TestMCPLanConfigTokenRotationAndDebugTools(t *testing.T) {
	dataDir := t.TempDir()
	mgr := NewManager(dataDir, "lightisled", nil)
	defer mgr.Close()
	mgr.SetEndpointProvider(func() (string, string) {
		return "http://127.0.0.1:16666", "http://192.168.1.88:16666"
	})
	if err := mgr.Reload(); err != nil {
		t.Fatal(err)
	}

	// Enabling LAN MCP must automatically enable MCPEnabled and generate a token.
	lanTrue := true
	cfg, err := mgr.SetMCPConfig(nil, &lanTrue)
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.MCPEnabled || !cfg.MCPLanEnabled {
		t.Fatalf("expected both mcpEnabled and mcpLanEnabled to be true, got %+v", cfg)
	}
	token1 := mgr.ReadMCPToken()
	if len(token1) < 32 || !mgr.VerifyReloadToken(token1) {
		t.Fatalf("expected valid MCP token, got %q", token1)
	}

	snap := mgr.BuildMCPConfigSnapshot("")
	if snap.LanHTTPURL != "http://192.168.1.88:16666/api/v2/mcp" {
		t.Fatalf("unexpected LanHTTPURL: %s", snap.LanHTTPURL)
	}
	if !strings.Contains(snap.LanPrompt, token1) || !strings.Contains(snap.ClientConfigJSON, "lightisle-lan") {
		t.Fatalf("expected LanPrompt and ClientConfigJSON to include token and lightisle-lan")
	}

	// Token rotation invalidates old token and issues a new one.
	token2, err := mgr.RotateMCPToken()
	if err != nil {
		t.Fatal(err)
	}
	if token2 == token1 || !mgr.VerifyReloadToken(token2) || mgr.VerifyReloadToken(token1) {
		t.Fatalf("token rotation failed: old=%s new=%s", token1, token2)
	}

	// Scaffold a plugin and test remote read/write/probe/logs tools via ExecuteDebugMCP.
	scaffoldArgs, _ := json.Marshal(map[string]any{
		"id":          "hello-lan",
		"name":        "局域网调试示例",
		"description": "通过 MCP 远程读写与探针调试",
		"mode":        "static",
	})
	created, err := mgr.ScaffoldApp(scaffoldArgs, true)
	if err != nil {
		t.Fatal(err)
	}
	if created.ID != "hello-lan" || created.PendingActivation {
		t.Fatalf("unexpected scaffolded app: %+v", created)
	}

	ctx := context.Background()

	// Write a custom file via lightisle_write_plugin_file
	writeRes := mgr.ExecuteDebugMCP(ctx, MCPDebugExecRequest{
		Method: "tools/call",
		Tool:   "lightisle_write_plugin_file",
		Args:   json.RawMessage(`{"id":"hello-lan","path":"ui/index.html","content":"<!doctype html><html><body>LAN-MCP-UPDATED</body></html>"}`),
	}, "192.168.1.50")
	if writeRes.IsError || !strings.Contains(writeRes.ResponseJSON, `\"written\": true`) {
		t.Fatalf("lightisle_write_plugin_file failed: %s", writeRes.ResponseJSON)
	}

	// Read back via lightisle_read_plugin_file
	readRes := mgr.ExecuteDebugMCP(ctx, MCPDebugExecRequest{
		Method: "tools/call",
		Tool:   "lightisle_read_plugin_file",
		Args:   json.RawMessage(`{"id":"hello-lan","path":"ui/index.html"}`),
	}, "192.168.1.50")
	if readRes.IsError || !strings.Contains(readRes.ResponseJSON, "LAN-MCP-UPDATED") {
		t.Fatalf("lightisle_read_plugin_file failed: %s", readRes.ResponseJSON)
	}

	// Path traversal attempt must fail
	traversalRes := mgr.ExecuteDebugMCP(ctx, MCPDebugExecRequest{
		Method: "tools/call",
		Tool:   "lightisle_read_plugin_file",
		Args:   json.RawMessage(`{"id":"hello-lan","path":"../network-pulse/plugin.json"}`),
	}, "192.168.1.50")
	if !traversalRes.IsError {
		t.Fatalf("expected path traversal to be rejected, got: %s", traversalRes.ResponseJSON)
	}

	// Probe the static app via lightisle_probe_app
	probeRes := mgr.ExecuteDebugMCP(ctx, MCPDebugExecRequest{
		Method: "tools/call",
		Tool:   "lightisle_probe_app",
		Args:   json.RawMessage(`{"id":"hello-lan","method":"GET","path":"/"}`),
	}, "192.168.1.50")
	if probeRes.IsError || !strings.Contains(probeRes.ResponseJSON, "LAN-MCP-UPDATED") {
		t.Fatalf("lightisle_probe_app failed: %s", probeRes.ResponseJSON)
	}

	// Verify call logs recorded entries and can be cleared
	logs := mgr.GetMCPCallLogs()
	if len(logs) < 3 {
		t.Fatalf("expected at least 3 MCP call log entries, got %d", len(logs))
	}
	if err := mgr.ClearMCPCallLogs(); err != nil {
		t.Fatal(err)
	}
	if len(mgr.GetMCPCallLogs()) != 0 {
		t.Fatalf("expected empty logs after clear")
	}

	// Disabling MCPEnabled must also disable MCPLanEnabled
	mcpFalse := false
	cfgOff, err := mgr.SetMCPConfig(&mcpFalse, nil)
	if err != nil {
		t.Fatal(err)
	}
	if cfgOff.MCPEnabled || cfgOff.MCPLanEnabled {
		t.Fatalf("expected both flags false after disabling MCP, got %+v", cfgOff)
	}
}
