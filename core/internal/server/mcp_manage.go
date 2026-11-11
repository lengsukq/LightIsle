package server

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"mime"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/lengsukq/lightisle/core/internal/apps"
	"github.com/lengsukq/lightisle/core/internal/auth"
)

const (
	mcpManagementPath     = "/api/v2/mcp/manage"
	mcpServerName         = "lightisle-mcp"
	mcpServerVersion      = "2.0.0"
	mcpServerInstructions = "LightIsle 全功能管理与控制 MCP：1) 涉及存储根写操作前先调用 lightisle_list_roots 获取当前在线状态与 generation；2) 修改定时脚本或轻应用运行策略前先读取当前配置及 revision；3) 所有文件删除仅走 lightisle_move_to_trash 安全移入回收站，严禁格式化磁盘、注销存储根、清空回收站、执行任意 Shell 或读取密钥凭据；4) 全部工具调用均实时记入 SQLite 审计日志。"
)

type mcpSessionKey struct{}

func isMCPManagementRequest(r *http.Request) bool {
	_, ok := r.Context().Value(mcpSessionKey{}).(string)
	return ok
}

type mcpManagement struct {
	store  *auth.Store
	apps   *apps.Manager
	api    http.Handler
	tools  []mcpTool
	active chan struct{}
}

type mcpRPCRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params"`
}

func localMCPHost(host string) bool {
	if name, _, err := net.SplitHostPort(host); err == nil {
		host = name
	}
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(strings.Trim(host, "[]"))
	return ip != nil && (ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast())
}

func hasReverseProxyHeaders(r *http.Request) bool {
	return r.Header.Get("Forwarded") != "" ||
		r.Header.Get("X-Forwarded-For") != "" ||
		r.Header.Get("CF-Connecting-IP") != "" ||
		r.Header.Get("X-Real-IP") != ""
}

func (m *mcpManagement) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	loopback, local := isPrivateOrLoopbackAddr(r.RemoteAddr)
	if !local || !localMCPHost(r.Host) || hasReverseProxyHeaders(r) {
		jsonReply(w, 403, map[string]string{"error": "mcp_lan_only"})
		return
	}
	origins := r.Header.Values("Origin")
	if len(origins) > 1 || (len(origins) == 1 && !originMatchesHost(origins[0], r.Host)) {
		jsonReply(w, 403, map[string]string{"error": "cross_origin_request_rejected"})
		return
	}
	cfg := m.apps.GetSystemConfig()
	if !cfg.MCPEnabled {
		jsonReply(w, 403, map[string]string{"error": "mcp_disabled"})
		return
	}
	if !loopback && !cfg.MCPLanEnabled {
		jsonReply(w, 403, map[string]string{"error": "mcp_lan_disabled"})
		return
	}

	if m.store == nil {
		jsonReply(w, 503, map[string]string{"error": "database_not_ready"})
		return
	}
	tok := extractMCPTokenFromRequest(r)
	user, session, connection, ok := m.authenticateBearerOrSystem(tok)
	if !ok {
		w.Header().Set("WWW-Authenticate", `Bearer realm="LightIsle Management MCP"`)
		jsonReply(w, 401, map[string]string{"error": "mcp_connection_required"})
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	if version := r.Header.Get("MCP-Protocol-Version"); version != "" && !managementMCPVersion(version) {
		jsonReply(w, 400, map[string]string{"error": "mcp_unsupported_protocol_version"})
		return
	}
	if media, _, err := mime.ParseMediaType(r.Header.Get("Content-Type")); err != nil || media != "application/json" {
		jsonReply(w, 415, map[string]string{"error": "mcp_json_required"})
		return
	}

	select {
	case m.active <- struct{}{}:
		defer func() { <-m.active }()
	default:
		jsonReply(w, 429, map[string]string{"error": "mcp_busy"})
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 4<<20)
	defer r.Body.Close()
	rawBody, err := io.ReadAll(r.Body)
	if err != nil {
		mcpRPCError(w, nil, -32700, "Parse error")
		return
	}
	transport := "local-http"
	if !loopback {
		transport = "lan-http"
	}
	respBytes, hasResp := m.executeAuthorizedLocked(r.Context(), transport, r.RemoteAddr, user, session, connection, rawBody)
	if !hasResp {
		w.WriteHeader(http.StatusAccepted)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(respBytes)
}

func (m *mcpManagement) authenticateBearerOrSystem(tok string) (auth.User, string, auth.MCPConnection, bool) {
	tok = strings.TrimSpace(tok)
	if tok == "" || m.store == nil {
		return auth.User{}, "", auth.MCPConnection{}, false
	}
	if user, session, conn, ok := m.store.AuthenticateMCP(tok); ok {
		return user, session, conn, true
	}
	if m.apps != nil && m.apps.VerifyReloadToken(tok) {
		return m.store.EnsureSystemMCPSession(tok, "")
	}
	return auth.User{}, "", auth.MCPConnection{}, false
}

// ExecuteAuthorizedRPC executes a single JSON-RPC 2.0 MCP message under an already-verified
// LightIsle user/connection identity, recording both SQLite audit_events (for tools/call)
// and sanitized debug call logs (mcp-debug-log.json).
func (m *mcpManagement) ExecuteAuthorizedRPC(
	ctx context.Context,
	transport string,
	remoteAddr string,
	user auth.User,
	session string,
	connection auth.MCPConnection,
	raw []byte,
) ([]byte, bool) {
	select {
	case m.active <- struct{}{}:
		defer func() { <-m.active }()
	default:
		b, _ := json.Marshal(map[string]any{
			"jsonrpc": "2.0",
			"id":      nil,
			"error":   map[string]any{"code": -32000, "message": "MCP server busy"},
		})
		return b, true
	}
	return m.executeAuthorizedLocked(ctx, transport, remoteAddr, user, session, connection, raw)
}

func (m *mcpManagement) executeAuthorizedLocked(
	ctx context.Context,
	transport string,
	remoteAddr string,
	user auth.User,
	session string,
	connection auth.MCPConnection,
	raw []byte,
) ([]byte, bool) {
	started := time.Now()
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 {
		b, _ := json.Marshal(map[string]any{
			"jsonrpc": "2.0",
			"id":      nil,
			"error":   map[string]any{"code": -32700, "message": "Parse error"},
		})
		return b, true
	}

	var req mcpRPCRequest
	decoder := json.NewDecoder(bytes.NewReader(trimmed))
	if err := decoder.Decode(&req); err != nil || decoder.Decode(new(any)) != io.EOF {
		b, _ := json.Marshal(map[string]any{
			"jsonrpc": "2.0",
			"id":      nil,
			"error":   map[string]any{"code": -32700, "message": "Parse error"},
		})
		return b, true
	}
	if req.JSONRPC != "2.0" || req.Method == "" || !validMCPRequestID(req.ID) {
		b, _ := json.Marshal(map[string]any{
			"jsonrpc": "2.0",
			"id":      nil,
			"error":   map[string]any{"code": -32600, "message": "Invalid Request"},
		})
		return b, true
	}
	if len(req.ID) == 0 || strings.HasPrefix(req.Method, "notifications/") {
		return nil, false
	}

	var traceTarget, reqSummary string
	switch req.Method {
	case "tools/call":
		var p struct {
			Name      string          `json:"name"`
			Arguments json.RawMessage `json:"arguments"`
		}
		if json.Unmarshal(req.Params, &p) == nil {
			traceTarget = p.Name
			reqSummary = string(p.Arguments)
		}
	case "resources/read":
		var p struct {
			URI string `json:"uri"`
		}
		if json.Unmarshal(req.Params, &p) == nil {
			traceTarget = p.URI
			reqSummary = p.URI
		}
	default:
		traceTarget = req.Method
		reqSummary = string(req.Params)
	}

	respObj, isCallErr := m.dispatchRPC(ctx, req, user, session, connection)
	respBytes, err := json.Marshal(respObj)
	if err != nil {
		return nil, false
	}

	if req.Method != "ping" && m.apps != nil && m.apps.DataDir() != "" {
		respPreview := string(respBytes)
		if resVal, ok := respObj["result"].(mcpManagementResult); ok && len(resVal.Content) > 0 {
			respPreview = resVal.Content[0]["text"]
		} else if errMap, ok := respObj["error"].(map[string]any); ok {
			respPreview = fmt.Sprintf("[%v] %v", errMap["code"], errMap["message"])
		}
		apps.RecordMCPCall(m.apps.DataDir(), apps.MCPCallLogEntry{
			Timestamp:       started.UTC().Format(time.RFC3339),
			Transport:       transport,
			RemoteAddr:      remoteAddr,
			Method:          req.Method,
			Target:          traceTarget,
			DurationMs:      time.Since(started).Milliseconds(),
			IsError:         isCallErr,
			RequestSummary:  reqSummary,
			ResponsePreview: respPreview,
		})
	}
	return respBytes, true
}

func (m *mcpManagement) dispatchRPC(
	ctx context.Context,
	req mcpRPCRequest,
	user auth.User,
	session string,
	connection auth.MCPConnection,
) (map[string]any, bool) {
	rpcErr := func(code int, msg string) (map[string]any, bool) {
		return map[string]any{
			"jsonrpc": "2.0",
			"id":      req.ID,
			"error":   map[string]any{"code": code, "message": msg},
		}, true
	}
	rpcOK := func(res any, isErr bool) (map[string]any, bool) {
		return map[string]any{
			"jsonrpc": "2.0",
			"id":      req.ID,
			"result":  res,
		}, isErr
	}

	switch req.Method {
	case "initialize":
		var params struct {
			ProtocolVersion string `json:"protocolVersion"`
		}
		if len(req.Params) != 0 && json.Unmarshal(req.Params, &params) != nil {
			return rpcErr(-32602, "Invalid params")
		}
		if !managementMCPVersion(params.ProtocolVersion) {
			params.ProtocolVersion = "2025-06-18"
		}
		return rpcOK(map[string]any{
			"protocolVersion": params.ProtocolVersion,
			"capabilities": map[string]any{
				"resources": map[string]any{},
				"tools":     map[string]any{},
			},
			"serverInfo":   map[string]string{"name": mcpServerName, "version": mcpServerVersion},
			"instructions": mcpServerInstructions,
		}, false)

	case "ping":
		return rpcOK(map[string]any{}, false)

	case "resources/list":
		return rpcOK(map[string]any{
			"resources": apps.SpecResources(),
		}, false)

	case "resources/read":
		var params struct {
			URI string `json:"uri"`
		}
		if err := json.Unmarshal(req.Params, &params); err != nil || strings.TrimSpace(params.URI) == "" {
			return rpcErr(-32602, "Invalid params: uri required")
		}
		text, ok := apps.ReadSpecResource(params.URI)
		if !ok {
			return rpcErr(-32602, "Unknown resource URI: "+params.URI)
		}
		return rpcOK(map[string]any{
			"contents": []map[string]any{
				{
					"uri":      params.URI,
					"mimeType": "text/markdown",
					"text":     text,
				},
			},
		}, false)

	case "tools/list":
		definitions := make([]map[string]any, 0, len(m.tools))
		for _, tool := range m.tools {
			if mcpToolAllowed(tool, user, connection) {
				definitions = append(definitions, tool.definition())
			}
		}
		return rpcOK(map[string]any{"tools": definitions}, false)

	case "tools/call":
		result := m.call(ctx, req.Params, user, session, connection)
		return rpcOK(result, result.IsError)

	default:
		return rpcErr(-32601, "Method not found: "+req.Method)
	}
}

func managementMCPVersion(version string) bool {
	switch version {
	case "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25":
		return true
	default:
		return false
	}
}

func validMCPRequestID(id json.RawMessage) bool {
	if len(id) == 0 {
		return true
	}
	var text string
	var number int64
	return string(id) != "null" && (json.Unmarshal(id, &text) == nil || json.Unmarshal(id, &number) == nil)
}

func mcpRPCError(w http.ResponseWriter, id json.RawMessage, code int, message string) {
	jsonReply(w, 200, map[string]any{"jsonrpc": "2.0", "id": id, "error": map[string]any{"code": code, "message": message}})
}

type mcpManagementResult struct {
	Content           []map[string]string `json:"content"`
	StructuredContent any                 `json:"structuredContent,omitempty"`
	IsError           bool                `json:"isError,omitempty"`
}

func mcpResult(payload any, isError bool) mcpManagementResult {
	raw, _ := json.Marshal(payload)
	return mcpManagementResult{
		Content:           []map[string]string{{"type": "text", "text": string(raw)}},
		StructuredContent: payload,
		IsError:           isError,
	}
}

func mcpFailure(code string) mcpManagementResult {
	return mcpResult(map[string]string{"error": code}, true)
}

func mcpToolAllowed(tool mcpTool, user auth.User, connection auth.MCPConnection) bool {
	return (!tool.admin || user.Role == auth.RoleAdmin) && (!tool.isWrite() || connection.CanWrite)
}

func mcpAuditTarget(toolName, connID string) string {
	clean := func(s string) string {
		return strings.Map(func(r rune) rune {
			switch r {
			case '\r', '\n', 0, '?', '&', '#':
				return '_'
			default:
				return r
			}
		}, strings.TrimSpace(s))
	}
	t := clean(toolName)
	if t == "" {
		t = "unknown_tool"
	}
	c := clean(connID)
	combined := t
	if c != "" {
		combined = t + " " + c
	}
	if len(combined) > 120 {
		combined = combined[:120]
	}
	if len(combined) < 2 {
		combined = "mcp_call"
	}
	return combined
}

func (m *mcpManagement) call(ctx context.Context, raw json.RawMessage, user auth.User, session string, connection auth.MCPConnection) (result mcpManagementResult) {
	var params struct {
		Name      string          `json:"name"`
		Arguments json.RawMessage `json:"arguments"`
	}
	parsed := json.Unmarshal(raw, &params) == nil && params.Name != ""
	var argMap map[string]json.RawMessage
	rawArgs := params.Arguments
	if parsed {
		trimmedArgs := bytes.TrimSpace(rawArgs)
		if len(trimmedArgs) == 0 || string(trimmedArgs) == "null" {
			argMap = map[string]json.RawMessage{}
			rawArgs = []byte("{}")
		} else if json.Unmarshal(trimmedArgs, &argMap) != nil || argMap == nil {
			parsed = false
		}
	}

	var tool *mcpTool
	target := "unknown_tool"
	if parsed {
		target = params.Name
		for i := range m.tools {
			if m.tools[i].name == params.Name {
				tool = &m.tools[i]
				target = tool.name
				break
			}
		}
	}

	if m.store == nil {
		return mcpFailure("mcp_audit_unavailable")
	}
	// Persist before dispatch. A crash or loss of the final audit write leaves
	// the original attempt visible and its outcome unconfirmed.
	auditID, err := m.store.BeginMCPAudit(user.ID, mcpAuditTarget(target, connection.ID))
	if err != nil {
		slog.Warn("cannot start MCP audit", "error", err)
		return mcpFailure("mcp_audit_unavailable")
	}
	outcome := "denied"
	defer func() {
		if err := m.store.FinishMCPAudit(auditID, outcome); err != nil {
			slog.Warn("cannot finish MCP audit", "error", err)
			result = mcpFailure("mcp_audit_result_unavailable_check_current_state")
		}
	}()

	switch {
	case !parsed:
		return mcpFailure("mcp_invalid_arguments")
	case tool == nil:
		return mcpFailure("mcp_tool_unavailable")
	case !mcpToolAllowed(*tool, user, connection):
		return mcpFailure("mcp_tool_forbidden")
	}

	if tool.directPlugin {
		if m.apps == nil {
			outcome = "failed"
			return mcpFailure("mcp_apps_unavailable")
		}
		text, isErr, handled := apps.ExecutePluginMCPTool(ctx, m.apps.DataDir(), m.apps.ExecPath(), m.apps, tool.name, rawArgs)
		if !handled {
			return mcpFailure("mcp_tool_unavailable")
		}
		if isErr {
			outcome = "failed"
		} else {
			outcome = "success"
		}
		var structured any
		if json.Unmarshal([]byte(text), &structured) != nil {
			structured = nil
		}
		return mcpManagementResult{
			Content:           []map[string]string{{"type": "text", "text": text}},
			StructuredContent: structured,
			IsError:           isErr,
		}
	}

	req, ok := tool.request(ctx, session, argMap)
	if !ok {
		return mcpFailure("mcp_invalid_arguments")
	}
	outcome = "failed"
	writer := &mcpResponseWriter{header: http.Header{}, limit: 256 << 10}
	if tool.response == "text" {
		writer.limit = 64 << 10
	}
	m.api.ServeHTTP(writer, req)
	result = tool.result(writer)
	outcome = auditOutcome(writer.status)
	if result.IsError && outcome == "success" {
		outcome = "failed"
	}
	return result
}

var mcpPathSegment = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,64}$`)

func (tool mcpTool) request(ctx context.Context, session string, args map[string]json.RawMessage) (*http.Request, bool) {
	route := "/api/v2" + tool.route
	query := url.Values{}
	body := map[string]any{}
	generation := ""
	consumed := 0
	for _, p := range tool.params {
		raw, exists := args[p.name]
		if !exists {
			if p.required {
				return nil, false
			}
			continue
		}
		value, ok := decodeMCPArgument(raw, p)
		if !ok {
			return nil, false
		}
		consumed++
		switch p.destination {
		case mcpDestPath:
			segment := fmt.Sprint(value)
			if !mcpPathSegment.MatchString(segment) {
				return nil, false
			}
			route = strings.Replace(route, "{"+p.name+"}", segment, 1)
		case mcpDestQuery:
			query.Set(p.name, fmt.Sprint(value))
		case mcpDestGenerationHeader:
			if value == int64(0) {
				return nil, false
			}
			generation = fmt.Sprint(value)
		default:
			setMCPBodyField(body, p.destination, value)
		}
	}
	if consumed != len(args) || (tool.name == "lightisle_set_app_runtime_settings" && body["web"] == nil) {
		return nil, false
	}
	target := &url.URL{Path: route, RawQuery: query.Encode()}
	var bodyReader io.Reader = http.NoBody
	if len(body) > 0 || (tool.method != http.MethodGet && tool.method != http.MethodDelete && tool.method != http.MethodHead) {
		rawBody, _ := json.Marshal(body)
		bodyReader = bytes.NewReader(rawBody)
	}
	req, err := http.NewRequestWithContext(context.WithValue(ctx, mcpSessionKey{}, session), tool.method, target.String(), bodyReader)
	if err != nil {
		return nil, false
	}
	if bodyReader != http.NoBody {
		req.Header.Set("Content-Type", "application/json")
	}
	req.Header.Set("X-LightIsle-Request", "1")
	if generation != "" {
		req.Header.Set(rootGenerationHeader, generation)
	}
	return req, true
}

type mcpResponseWriter struct {
	header   http.Header
	body     bytes.Buffer
	limit    int
	status   int
	overflow bool
}

func (w *mcpResponseWriter) Header() http.Header { return w.header }
func (w *mcpResponseWriter) WriteHeader(status int) {
	if w.status == 0 {
		w.status = status
	}
}
func (w *mcpResponseWriter) Write(p []byte) (int, error) {
	w.WriteHeader(http.StatusOK)
	if len(p) > w.limit-w.body.Len() {
		w.overflow = true
		return 0, io.ErrShortWrite
	}
	return w.body.Write(p)
}

func (tool mcpTool) result(w *mcpResponseWriter) mcpManagementResult {
	if w.overflow {
		if tool.isWrite() {
			return mcpFailure("mcp_result_too_large_check_current_state")
		}
		return mcpFailure("mcp_response_too_large")
	}
	if w.status < 200 || w.status >= 300 {
		var payload struct {
			Error   string `json:"error"`
			Message string `json:"message"`
		}
		if json.Unmarshal(w.body.Bytes(), &payload) != nil || !mcpPathSegment.MatchString(payload.Error) {
			payload.Error = "mcp_operation_failed"
		}
		errObj := map[string]any{"error": payload.Error, "status": w.status}
		if payload.Message != "" && len(payload.Message) <= 512 {
			errObj["message"] = payload.Message
		}
		return mcpResult(errObj, true)
	}
	if tool.response == "text" {
		if !utf8.Valid(w.body.Bytes()) || bytes.ContainsRune(w.body.Bytes(), 0) {
			return mcpFailure("mcp_file_is_not_text")
		}
		return mcpResult(map[string]string{"text": w.body.String()}, false)
	}
	if strings.TrimSpace(w.body.String()) == "" {
		return mcpResult(map[string]any{"ok": true, "status": w.status}, false)
	}
	var payload any
	decoder := json.NewDecoder(&w.body)
	decoder.UseNumber()
	if decoder.Decode(&payload) != nil {
		return mcpFailure("mcp_invalid_api_response")
	}
	switch tool.response {
	case "download":
		removeMCPFields(payload, "url", "error")
	case "automation":
		removeMCPFields(payload, "output")
	case "apps":
		removeMCPFields(payload, "diagnostic", "lastError", "validationError", "mcpToken", "mcpPrompt", "lanMcpPrompt", "mcpConfigJson", "mcpConfig", "mcpLogs")
	}
	return mcpResult(payload, false)
}

func removeMCPFields(data any, fields ...string) {
	switch value := data.(type) {
	case map[string]any:
		for _, field := range fields {
			delete(value, field)
		}
		for _, child := range value {
			removeMCPFields(child, fields...)
		}
	case []any:
		for _, child := range value {
			removeMCPFields(child, fields...)
		}
	}
}
