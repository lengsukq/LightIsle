package apps

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/lengsukq/lightisle/core/internal/automation"
)

func TestSessionGrantsAndTicketsBoundedAndCleaned(t *testing.T) {
	dataDir := t.TempDir()
	mgr := NewManager(dataDir, "lightisled", nil)
	defer mgr.Close()

	// 1. Cap tickets at maxAppTickets (1024)
	for i := 0; i < maxAppTickets+50; i++ {
		mgr.IssueTicket("network-pulse", UserIdentity{
			ID:       int64(i + 1),
			Username: fmt.Sprintf("user-%d", i),
			Role:     "member",
		})
	}
	mgr.mu.RLock()
	ticketCount := len(mgr.tickets)
	mgr.mu.RUnlock()
	if ticketCount != maxAppTickets {
		t.Fatalf("expected ticket map capped at %d, got %d", maxAppTickets, ticketCount)
	}

	// 2. Cap sessionGrants at maxSessionGrants (1024)
	var lastCookie string
	for i := 0; i < maxSessionGrants+40; i++ {
		lastCookie = mgr.SignAppCookie("network-pulse", UserIdentity{
			ID:           1,
			Username:     "admin",
			Role:         "admin",
			SessionToken: fmt.Sprintf("session-token-%d", i),
		}, time.Hour)
	}
	mgr.mu.RLock()
	grantCount := len(mgr.sessionGrants)
	mgr.mu.RUnlock()
	if grantCount != maxSessionGrants {
		t.Fatalf("expected sessionGrants capped at %d, got %d", maxSessionGrants, grantCount)
	}

	// 3. Invalidated session in VerifyAppCookie deletes its grant immediately
	mgr.SetUserVerifier(func(u UserIdentity) (UserIdentity, bool) {
		return UserIdentity{}, false
	})
	if _, ok := mgr.VerifyAppCookie("network-pulse", lastCookie); ok {
		t.Fatalf("expected VerifyAppCookie to reject revoked session")
	}
	mgr.mu.RLock()
	afterRejectCount := len(mgr.sessionGrants)
	mgr.mu.RUnlock()
	if afterRejectCount != maxSessionGrants-1 {
		t.Fatalf("expected revoked grant to be deleted (%d -> %d), got %d", maxSessionGrants, maxSessionGrants-1, afterRejectCount)
	}

	// 4. reapOnce prunes expired tickets and sessionGrants
	mgr.reapOnce(time.Now().Add(2 * time.Hour))
	mgr.mu.RLock()
	remainingTickets := len(mgr.tickets)
	remainingGrants := len(mgr.sessionGrants)
	mgr.mu.RUnlock()
	if remainingTickets != 0 || remainingGrants != 0 {
		t.Fatalf("expected reapOnce to clear expired entries, got tickets=%d grants=%d", remainingTickets, remainingGrants)
	}
}

func TestPendingActivationBlocksActionsAndProbeUntilApproved(t *testing.T) {
	dataDir := t.TempDir()
	autoMgr, err := automation.New(dataDir, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer autoMgr.Close()

	mgr := NewManager(dataDir, "lightisled", autoMgr)
	defer mgr.Close()

	pluginDir := filepath.Join(dataDir, "plugins", "pending-guard")
	if err := os.MkdirAll(filepath.Join(pluginDir, "ui"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(pluginDir, "ui", "index.html"), []byte("<!doctype html><html><body>OK</body></html>"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(pluginDir, "run-cron.sh"), []byte("#!/bin/sh\necho cron-ran\n"), 0700); err != nil {
		t.Fatal(err)
	}
	manifest := `{
  "schemaVersion": 2,
  "id": "pending-guard",
  "name": "Pending Guard",
  "version": "1.0.0",
  "access": { "policy": "admin_only", "allowedUserIDs": [] },
  "web": { "enabled": true, "mode": "static", "staticDir": "ui" },
  "cron": {
    "enabled": true,
    "entry": "run-cron.sh",
    "schedule": { "cron": "0 * * * *", "timezone": "Asia/Shanghai" },
    "timeoutSeconds": 15,
    "notification": { "events": ["failure"], "channels": [] }
  }
}`
	if err := os.WriteFile(filepath.Join(pluginDir, "plugin.json"), []byte(manifest), 0600); err != nil {
		t.Fatal(err)
	}
	if err := markAppPendingInConfig(dataDir, "pending-guard"); err != nil {
		t.Fatal(err)
	}
	if err := mgr.Reload(); err != nil {
		t.Fatal(err)
	}

	ctx := context.Background()
	if _, err := mgr.RestartApp(ctx, "pending-guard"); !errors.Is(err, ErrPendingActivation) {
		t.Fatalf("RestartApp on pending app: got %v, want ErrPendingActivation", err)
	}
	if err := mgr.TriggerCron("pending-guard"); !errors.Is(err, ErrPendingActivation) {
		t.Fatalf("TriggerCron on pending app: got %v, want ErrPendingActivation", err)
	}
	if _, err := mgr.ProbeApp(ctx, "pending-guard", AppProbeRequest{Method: "GET", Path: "/"}); !errors.Is(err, ErrPendingActivation) {
		t.Fatalf("ProbeApp on pending app: got %v, want ErrPendingActivation", err)
	}

	// Explicit approval unlocks ProbeApp and TriggerCron.
	approved, err := mgr.ExecuteAction(ctx, "pending-guard", "approve")
	if err != nil {
		t.Fatalf("ExecuteAction(approve) failed: %v", err)
	}
	if approved.PendingActivation {
		t.Fatalf("expected PendingActivation=false after approve")
	}
	probeRes, err := mgr.ProbeApp(ctx, "pending-guard", AppProbeRequest{Method: "GET", Path: "/"})
	if err != nil || probeRes.StatusCode != 200 || !strings.Contains(probeRes.BodyPreview, "OK") {
		t.Fatalf("expected ProbeApp 200 OK after approve, got res=%+v err=%v", probeRes, err)
	}
	if err := mgr.TriggerCron("pending-guard"); err != nil {
		t.Fatalf("expected TriggerCron to succeed after approve, got %v", err)
	}
}

func TestProbeAppTruncatesOversizedBodySafely(t *testing.T) {
	dataDir := t.TempDir()
	mgr := NewManager(dataDir, "lightisled", nil)
	defer mgr.Close()
	if err := mgr.Reload(); err != nil {
		t.Fatal(err)
	}

	rawArgs, _ := json.Marshal(map[string]any{
		"id":          "big-static",
		"name":        "Big Static",
		"description": "Large static response probe test",
		"mode":        "static",
	})
	if _, err := mgr.ScaffoldApp(rawArgs, true); err != nil {
		t.Fatal(err)
	}
	largeBody := strings.Repeat("ABCD1234", 8192) // 64 KiB > 16 KiB limit
	indexPath := filepath.Join(dataDir, "plugins", "big-static", "ui", "index.html")
	if err := os.WriteFile(indexPath, []byte(largeBody), 0600); err != nil {
		t.Fatal(err)
	}

	res, err := mgr.ProbeApp(context.Background(), "big-static", AppProbeRequest{Method: "GET", Path: "/"})
	if err != nil {
		t.Fatalf("ProbeApp failed: %v", err)
	}
	if !res.Truncated {
		t.Fatalf("expected Truncated=true for 64 KiB response")
	}
	if len(res.BodyPreview) > maxProbePreviewBytes {
		t.Fatalf("expected BodyPreview <= %d bytes, got %d", maxProbePreviewBytes, len(res.BodyPreview))
	}
}

func TestCorruptedAppsConfigPreservedWithoutOverwrite(t *testing.T) {
	dataDir := t.TempDir()
	mgr := NewManager(dataDir, "lightisled", nil)
	defer mgr.Close()
	if err := mgr.Reload(); err != nil {
		t.Fatal(err)
	}

	configPath := filepath.Join(dataDir, "apps-config.json")
	corrupted := []byte("{corrupted-json: true, do-not-wipe")
	if err := os.WriteFile(configPath, corrupted, 0600); err != nil {
		t.Fatal(err)
	}

	enable := true
	if _, err := mgr.SetMCPConfig(&enable, nil); err == nil {
		t.Fatalf("expected SetMCPConfig to fail on corrupted apps-config.json")
	}
	if _, err := mgr.RotateMCPToken(); err == nil {
		t.Fatalf("expected RotateMCPToken to fail on corrupted apps-config.json")
	}
	if _, err := mgr.ApproveApp("network-pulse"); err == nil {
		t.Fatalf("expected ApproveApp to fail on corrupted apps-config.json")
	}
	if _, err := mgr.UpdateApp("network-pulse", AppUpdateRequest{
		Access: &AccessConfig{Policy: AccessAllMembers},
	}); err == nil {
		t.Fatalf("expected UpdateApp to fail on corrupted apps-config.json")
	}
	if err := mgr.DeleteApp("network-pulse", false); err == nil {
		t.Fatalf("expected DeleteApp to fail on corrupted apps-config.json")
	}

	got, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, corrupted) {
		t.Fatalf("corrupted apps-config.json was overwritten: got %q, want %q", string(got), string(corrupted))
	}
}

func TestRecordMCPCallUTF8TruncationAndContentRedaction(t *testing.T) {
	dataDir := t.TempDir()
	secretContent := "SUPER_SECRET_SMTP_KEY=sk-live-999888777"
	reqJSON, _ := json.Marshal(map[string]any{
		"id":      "demo-app",
		"path":    "env.json",
		"content": secretContent,
		"extra":   "EXTRA_SECRET_VALUE",
	})
	// Build a multi-byte UTF-8 response > 500 bytes so byte-offset 500 lands inside a 3-byte Chinese rune.
	multiByteResp := "前缀A" + strings.Repeat("轻应用调试日志", 40)

	RecordMCPCall(dataDir, MCPCallLogEntry{
		Transport:       "lan-http",
		RemoteAddr:      "192.168.1.20",
		Method:          "tools/call",
		Target:          "lightisle_write_plugin_file",
		DurationMs:      12,
		RequestSummary:  string(reqJSON),
		ResponsePreview: multiByteResp,
	})

	logs := ReadMCPCallLogs(dataDir)
	if len(logs) != 1 {
		t.Fatalf("expected 1 MCP log entry, got %d", len(logs))
	}
	entry := logs[0]
	if strings.Contains(entry.RequestSummary, secretContent) || strings.Contains(entry.RequestSummary, "EXTRA_SECRET_VALUE") {
		t.Fatalf("expected secret content to be redacted, got %s", entry.RequestSummary)
	}
	if !strings.Contains(entry.RequestSummary, fmt.Sprintf("<redacted %d bytes>", len(secretContent))) {
		t.Fatalf("expected <redacted %d bytes> marker in RequestSummary, got %s", len(secretContent), entry.RequestSummary)
	}
	if !utf8.ValidString(entry.RequestSummary) || !utf8.ValidString(entry.ResponsePreview) {
		t.Fatalf("expected valid UTF-8 strings after truncation")
	}
	if !strings.HasSuffix(entry.ResponsePreview, "…") {
		t.Fatalf("expected truncated ResponsePreview to end with ellipsis, got %q", entry.ResponsePreview)
	}
}

func TestMCPUIThemeResourceListedAndReadable(t *testing.T) {
	dataDir := t.TempDir()
	mgr := NewManager(dataDir, "lightisled", nil)
	defer mgr.Close()
	if err := mgr.Reload(); err != nil {
		t.Fatal(err)
	}
	enable := true
	if _, err := mgr.SetMCPConfig(&enable, nil); err != nil {
		t.Fatal(err)
	}

	ctx := context.Background()
	listRes := mgr.ExecuteDebugMCP(ctx, MCPDebugExecRequest{
		Method: "resources/list",
	}, "127.0.0.1")
	if listRes.IsError || !strings.Contains(listRes.ResponseJSON, "lightisle://specs/ui-theme") {
		t.Fatalf("expected lightisle://specs/ui-theme in resources/list, got %s", listRes.ResponseJSON)
	}

	readRes := mgr.ExecuteDebugMCP(ctx, MCPDebugExecRequest{
		Method: "resources/read",
		URI:    "lightisle://specs/ui-theme",
	}, "127.0.0.1")
	if readRes.IsError {
		t.Fatalf("resources/read lightisle://specs/ui-theme failed: %s", readRes.ResponseJSON)
	}
	for _, token := range []string{"--bg", "--surface", "--text", "--muted", "--accent", "--border", "prefers-color-scheme: dark"} {
		if !strings.Contains(readRes.ResponseJSON, token) {
			t.Fatalf("expected ui-theme spec to document %q, got %s", token, readRes.ResponseJSON)
		}
	}
}
