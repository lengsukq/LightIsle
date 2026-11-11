package server

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/apps"
	"github.com/lengsukq/lightisle/core/internal/auth"
)

func TestAppsRemediationMembersCSRFAndMCPSSE(t *testing.T) {
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
	if _, err := accounts.CreateUser(adminTok, "bob", "bob-password-12345", auth.RoleMember); err != nil {
		t.Fatal(err)
	}

	appsMgr := apps.NewManager(dataDir, "lightisled", nil)
	defer appsMgr.Close()
	if err := appsMgr.Reload(); err != nil {
		t.Fatal(err)
	}

	handler := WithApps(New("", accounts, nil), dataDir, accounts, appsMgr)

	// 1. GET /api/v2/apps as admin returns non-empty enabled members (owner + bob)
	reqGet := httptest.NewRequest(http.MethodGet, "/api/v2/apps", nil)
	reqGet.AddCookie(&http.Cookie{Name: sessionCookie, Value: adminTok})
	recGet := httptest.NewRecorder()
	handler.ServeHTTP(recGet, reqGet)
	if recGet.Code != http.StatusOK {
		t.Fatalf("GET /api/v2/apps = %d %s", recGet.Code, recGet.Body.String())
	}
	var listResp struct {
		Members []struct {
			ID       int64  `json:"id"`
			Username string `json:"username"`
			Role     string `json:"role"`
		} `json:"members"`
	}
	if err := json.Unmarshal(recGet.Body.Bytes(), &listResp); err != nil {
		t.Fatal(err)
	}
	if len(listResp.Members) < 2 {
		t.Fatalf("expected at least 2 enabled members in GET /api/v2/apps, got %+v", listResp.Members)
	}

	// 2. POST and PUT /api/v2/apps* without X-LightIsle-Request: 1 return 403 request_header_required
	for _, tc := range []struct {
		method string
		path   string
		body   string
	}{
		{http.MethodPost, "/api/v2/apps/refresh", `{}`},
		{http.MethodPut, "/api/v2/apps/network-pulse", `{"access":{"policy":"all_members"}}`},
	} {
		req := httptest.NewRequest(tc.method, tc.path, strings.NewReader(tc.body))
		req.Header.Set("Content-Type", "application/json")
		req.AddCookie(&http.Cookie{Name: sessionCookie, Value: adminTok})
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		if rec.Code != http.StatusForbidden || !strings.Contains(rec.Body.String(), "request_header_required") {
			t.Fatalf("%s %s without X-LightIsle-Request expected 403 request_header_required, got %d %s",
				tc.method, tc.path, rec.Code, rec.Body.String())
		}
	}

	// 3. Enable LAN MCP and test real /api/v2/mcp/sse + /api/v2/mcp/message roundtrip
	lanTrue := true
	if _, err := appsMgr.SetMCPConfig(nil, &lanTrue); err != nil {
		t.Fatal(err)
	}
	mcpToken := appsMgr.ReadMCPToken()
	if mcpToken == "" {
		t.Fatal("expected non-empty MCP token")
	}

	// Cookie-fallback POST to /api/v2/mcp without X-LightIsle-Request must also be rejected with 403
	reqCookieMCP := httptest.NewRequest(http.MethodPost, "/api/v2/mcp", strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"ping"}`))
	reqCookieMCP.RemoteAddr = "127.0.0.1:54321"
	reqCookieMCP.Header.Set("Content-Type", "application/json")
	reqCookieMCP.AddCookie(&http.Cookie{Name: sessionCookie, Value: adminTok})
	recCookieMCP := httptest.NewRecorder()
	handler.ServeHTTP(recCookieMCP, reqCookieMCP)
	if recCookieMCP.Code != http.StatusForbidden || !strings.Contains(recCookieMCP.Body.String(), "request_header_required") {
		t.Fatalf("cookie-authenticated POST /api/v2/mcp without CSRF header: got %d %s", recCookieMCP.Code, recCookieMCP.Body.String())
	}

	ts := httptest.NewServer(handler)
	defer ts.Close()

	sseCtx, cancelSSE := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancelSSE()
	sseReq, err := http.NewRequestWithContext(sseCtx, http.MethodGet, ts.URL+"/api/v2/mcp/sse", nil)
	if err != nil {
		t.Fatal(err)
	}
	sseReq.Header.Set("Authorization", "Bearer "+mcpToken)
	sseResp, err := ts.Client().Do(sseReq)
	if err != nil {
		t.Fatal(err)
	}
	defer sseResp.Body.Close()
	if sseResp.StatusCode != http.StatusOK {
		t.Fatalf("GET /api/v2/mcp/sse = %d", sseResp.StatusCode)
	}

	reader := bufio.NewReader(sseResp.Body)
	readSSEEvent := func() (string, string) {
		t.Helper()
		var ev, data string
		for {
			line, err := reader.ReadString('\n')
			if err != nil {
				t.Fatalf("failed reading SSE stream: %v", err)
			}
			line = strings.TrimRight(line, "\r\n")
			if line == "" {
				if ev != "" || data != "" {
					return ev, data
				}
				continue
			}
			if strings.HasPrefix(line, ":") {
				continue
			}
			if after, ok := strings.CutPrefix(line, "event:"); ok {
				ev = strings.TrimSpace(after)
			} else if after, ok := strings.CutPrefix(line, "data:"); ok {
				data = strings.TrimSpace(after)
			}
		}
	}

	eventType, endpointPath := readSSEEvent()
	if eventType != "endpoint" || !strings.HasPrefix(endpointPath, "/api/v2/mcp/message?sessionId=") {
		t.Fatalf("unexpected initial SSE event: event=%q data=%q", eventType, endpointPath)
	}

	rpcBody := []byte(`{"jsonrpc":"2.0","id":42,"method":"resources/list"}`)
	msgReq, err := http.NewRequestWithContext(sseCtx, http.MethodPost, ts.URL+endpointPath, bytes.NewReader(rpcBody))
	if err != nil {
		t.Fatal(err)
	}
	msgReq.Header.Set("Authorization", "Bearer "+mcpToken)
	msgReq.Header.Set("Content-Type", "application/json")
	msgResp, err := ts.Client().Do(msgReq)
	if err != nil {
		t.Fatal(err)
	}
	_ = msgResp.Body.Close()
	if msgResp.StatusCode != http.StatusAccepted {
		t.Fatalf("POST %s = %d, want 202 Accepted", endpointPath, msgResp.StatusCode)
	}

	msgEvent, msgData := readSSEEvent()
	if msgEvent != "message" || !strings.Contains(msgData, "lightisle://specs/ui-theme") {
		t.Fatalf("unexpected SSE JSON-RPC message event: event=%q data=%q", msgEvent, msgData)
	}
}

func TestStreamingSubtitleDecodersAndConverters(t *testing.T) {
	// UTF-16LE with BOM (normalized to \n in single pass)
	utf16LE := []byte{0xFF, 0xFE, '1', 0, '\r', 0, '\n', 0, 'O', 0, 'K', 0}
	if got := decodeSubtitleText(utf16LE); got != "1\nOK" {
		t.Fatalf("decodeSubtitleText UTF-16LE = %q", got)
	}
	srt := "1\r\n00:00:01,250 --> 00:00:03,500\r\n你好世界\r\n\r\n"
	vtt := srtToVTT(srt)
	if !strings.HasPrefix(vtt, "WEBVTT\n\n") || !strings.Contains(vtt, "00:00:01.250 --> 00:00:03.500\n你好世界") {
		t.Fatalf("unexpected srtToVTT output: %q", vtt)
	}
	ass := "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:02.05,0:00:04.90,Default,,0,0,0,,{\\an8}第一行\\N第二行\n"
	assVTT := assToVTT(ass)
	if !strings.Contains(assVTT, "00:00:02.050 --> 00:00:04.900\n第一行\n第二行") {
		t.Fatalf("unexpected assToVTT output: %q", assVTT)
	}
}
