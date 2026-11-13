package server

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/lengsukq/lightisle/core/internal/apps"
	"github.com/lengsukq/lightisle/core/internal/auth"
)

const (
	maxMCPSSESessions = 16
	mcpSSEIdleTimeout = 5 * time.Minute
	mcpSSEQueueSize   = 32
)

type mcpSSESession struct {
	id         string
	ownerKey   string
	msgCh      chan []byte
	done       chan struct{}
	lastActive atomic.Int64
	closeOnce  sync.Once
}

func (s *mcpSSESession) close() {
	s.closeOnce.Do(func() {
		close(s.done)
	})
}

func (s *mcpSSESession) touch() {
	s.lastActive.Store(time.Now().UnixNano())
}

type mcpSSEHub struct {
	mu       sync.Mutex
	sessions map[string]*mcpSSESession
}

func newMCPSSEHub() *mcpSSEHub {
	return &mcpSSEHub{
		sessions: make(map[string]*mcpSSESession, maxMCPSSESessions),
	}
}

func (h *mcpSSEHub) sessionHeaderForKey(ownerKey string) string {
	sum := sha256.Sum256([]byte("lightisle-mcp:" + ownerKey))
	return hex.EncodeToString(sum[:16])
}

func (h *mcpSSEHub) sweepExpiredLocked(now time.Time) {
	cutoff := now.Add(-mcpSSEIdleTimeout).UnixNano()
	for id, sess := range h.sessions {
		if sess.lastActive.Load() < cutoff {
			delete(h.sessions, id)
			sess.close()
		}
	}
}

func (h *mcpSSEHub) register(ownerKey string) (*mcpSSESession, bool) {
	now := time.Now()
	var buf [16]byte
	_, _ = rand.Read(buf[:])
	sess := &mcpSSESession{
		id:       hex.EncodeToString(buf[:]),
		ownerKey: ownerKey,
		msgCh:    make(chan []byte, mcpSSEQueueSize),
		done:     make(chan struct{}),
	}
	sess.lastActive.Store(now.UnixNano())

	h.mu.Lock()
	defer h.mu.Unlock()
	h.sweepExpiredLocked(now)
	if len(h.sessions) >= maxMCPSSESessions {
		return nil, false
	}
	h.sessions[sess.id] = sess
	return sess, true
}

func (h *mcpSSEHub) remove(id string) {
	h.mu.Lock()
	sess, ok := h.sessions[id]
	if ok {
		delete(h.sessions, id)
	}
	h.mu.Unlock()
	if ok {
		sess.close()
	}
}

func (h *mcpSSEHub) get(id string) *mcpSSESession {
	now := time.Now()
	h.mu.Lock()
	defer h.mu.Unlock()
	h.sweepExpiredLocked(now)
	sess, ok := h.sessions[id]
	if !ok {
		return nil
	}
	sess.lastActive.Store(now.UnixNano())
	return sess
}

func (h *mcpSSEHub) send(id string, payload []byte) (found bool, delivered bool) {
	sess := h.get(id)
	if sess == nil {
		return false, false
	}
	cloned := append([]byte(nil), bytes.TrimSpace(payload)...)
	select {
	case <-sess.done:
		return false, false
	case sess.msgCh <- cloned:
		sess.touch()
		return true, true
	default:
		return true, false
	}
}

func registerAppsMCPRoutes(
	mux *http.ServeMux,
	a *API,
	appsMgr *apps.Manager,
	store *auth.Store,
	resolveSession func(*http.Request) (apps.UserIdentity, bool),
) {
	_ = store
	replyMCPState := func(w http.ResponseWriter, r *http.Request) {
		snap := appsMgr.BuildMCPConfigSnapshot(inferRequestLanOrigin(r))
		jsonReply(w, http.StatusOK, map[string]any{
			"mcpEnabled":    snap.MCPEnabled,
			"mcpLanEnabled": snap.MCPLanEnabled,
			"mcpToken":      snap.Token,
			"mcpPrompt":     snap.Prompt,
			"lanMcpPrompt":  snap.LanPrompt,
			"mcpConfigJson": snap.ClientConfigJSON,
			"localHttpUrl":  snap.LocalHTTPURL,
			"lanHttpUrl":    snap.LanHTTPURL,
			"lanSseUrl":     snap.LanSSEURL,
			"updatedAt":     snap.UpdatedAt,
			"config":        snap.Config,
			"pluginsDir":    snap.PluginsDir,
			"pluginDataDir": snap.PluginDataDir,
			"command":       snap.Command,
			"mcpLogs":       appsMgr.GetMCPCallLogs(),
		})
	}

	handleGetMCP := a.requireAdmin(func(w http.ResponseWriter, r *http.Request) {
		replyMCPState(w, r)
	})
	mux.HandleFunc("GET /api/v2/apps/mcp", handleGetMCP)
	mux.HandleFunc("GET /api/v2/apps/config", handleGetMCP)

	handleSetMCP := a.requireAdmin(func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, 4<<10)
		defer r.Body.Close()
		var body struct {
			MCPEnabled    *bool `json:"mcpEnabled"`
			Enabled       *bool `json:"enabled"`
			MCPLanEnabled *bool `json:"mcpLanEnabled"`
			LanEnabled    *bool `json:"lanEnabled"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
			return
		}
		mcpEnabled := body.MCPEnabled
		if mcpEnabled == nil {
			mcpEnabled = body.Enabled
		}
		mcpLan := body.MCPLanEnabled
		if mcpLan == nil {
			mcpLan = body.LanEnabled
		}
		if mcpEnabled == nil && mcpLan == nil {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
			return
		}
		if _, err := appsMgr.SetMCPConfig(mcpEnabled, mcpLan); err != nil {
			appsErrorReply(w, err)
			return
		}
		replyMCPState(w, r)
	})
	mux.HandleFunc("PUT /api/v2/apps/mcp", handleSetMCP)
	mux.HandleFunc("POST /api/v2/apps/mcp", handleSetMCP)
	mux.HandleFunc("PUT /api/v2/apps/config", handleSetMCP)

	mux.HandleFunc("POST /api/v2/apps/mcp/token/rotate", a.requireAdmin(func(w http.ResponseWriter, r *http.Request) {
		if _, err := appsMgr.RotateMCPToken(); err != nil {
			appsErrorReply(w, err)
			return
		}
		replyMCPState(w, r)
	}))

	mux.HandleFunc("POST /api/v2/apps/mcp/debug", a.requireAdmin(func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, 512<<10)
		defer r.Body.Close()
		var req apps.MCPDebugExecRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil && !errors.Is(err, io.EOF) {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
			return
		}
		res := appsMgr.ExecuteDebugMCP(r.Context(), req, r.RemoteAddr)
		jsonReply(w, http.StatusOK, res)
	}))

	mux.HandleFunc("GET /api/v2/apps/mcp/logs", a.requireAdmin(func(w http.ResponseWriter, _ *http.Request) {
		jsonReply(w, http.StatusOK, map[string]any{
			"logs": appsMgr.GetMCPCallLogs(),
		})
	}))

	mux.HandleFunc("DELETE /api/v2/apps/mcp/logs", a.requireAdmin(func(w http.ResponseWriter, _ *http.Request) {
		_ = appsMgr.ClearMCPCallLogs()
		jsonReply(w, http.StatusOK, map[string]any{
			"cleared": true,
			"logs":    []apps.MCPCallLogEntry{},
		})
	}))

	mux.HandleFunc("POST /api/v2/apps/scaffold", a.requireAdmin(func(w http.ResponseWriter, r *http.Request) {
		user, _ := resolveSession(r)
		r.Body = http.MaxBytesReader(w, r.Body, 32<<10)
		defer r.Body.Close()
		raw, err := io.ReadAll(r.Body)
		if err != nil || len(raw) == 0 {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
			return
		}
		app, err := appsMgr.ScaffoldApp(raw, true)
		if err != nil {
			appsErrorReply(w, err)
			return
		}
		jsonReply(w, http.StatusOK, map[string]any{
			"app":  app,
			"apps": appsMgr.ListForUser(user.ID, user.Role),
		})
	}))

	mux.HandleFunc("POST /api/v2/apps/{id}/probe", a.requireAdmin(func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
		defer r.Body.Close()
		var req apps.AppProbeRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil && !errors.Is(err, io.EOF) {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
			return
		}
		res, err := appsMgr.ProbeApp(r.Context(), id, req)
		if err != nil {
			appsErrorReply(w, err)
			return
		}
		jsonReply(w, http.StatusOK, map[string]any{"probe": res})
	}))
}

func inferRequestLanOrigin(r *http.Request) string {
	if r == nil || r.Host == "" {
		return ""
	}
	host, _, err := net.SplitHostPort(r.Host)
	if err != nil {
		host = r.Host
	}
	ip := net.ParseIP(strings.Trim(host, "[]"))
	if ip == nil || ip.IsLoopback() {
		return ""
	}
	scheme := "http"
	if r.TLS != nil {
		scheme = "https"
	}
	return scheme + "://" + r.Host
}

func extractMCPTokenFromRequest(r *http.Request) string {
	token := strings.TrimSpace(r.Header.Get("X-LightIsle-MCP-Token"))
	if token == "" {
		if authHeader := r.Header.Get("Authorization"); strings.HasPrefix(authHeader, "Bearer ") {
			token = strings.TrimSpace(strings.TrimPrefix(authHeader, "Bearer "))
		}
	}
	return token
}

func isPrivateOrLoopbackAddr(remoteAddr string) (isLoopback bool, isPrivateLAN bool) {
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		host = remoteAddr
	}
	ip := net.ParseIP(strings.Trim(host, "[]"))
	if ip == nil {
		return false, false
	}
	if ip.IsLoopback() {
		return true, true
	}
	if ip.IsPrivate() || ip.IsLinkLocalUnicast() {
		return false, true
	}
	return false, false
}

func handleLocalLoopbackMCPHelpers(w http.ResponseWriter, r *http.Request, appsMgr *apps.Manager) bool {
	path := r.URL.Path
	if r.Method != http.MethodPost {
		return false
	}
	switch path {
	case "/api/v2/apps/local-reload",
		"/api/v2/apps/local-mcp-action",
		"/api/v2/apps/local-mcp-logs",
		"/api/v2/apps/local-mcp-probe":
	default:
		return false
	}
	if !isLocal(r.RemoteAddr) {
		jsonReply(w, http.StatusForbidden, map[string]string{"error": "loopback_only"})
		return true
	}
	token := extractMCPTokenFromRequest(r)
	if !appsMgr.VerifyReloadToken(token) {
		jsonReply(w, http.StatusForbidden, map[string]string{"error": "mcp_reload_forbidden"})
		return true
	}
	switch path {
	case "/api/v2/apps/local-reload":
		if err := appsMgr.ReloadFromMCP(); err != nil {
			appsErrorReply(w, err)
			return true
		}
		jsonReply(w, http.StatusOK, map[string]any{
			"reloaded": true,
			"apps":     appsMgr.ListForUser(0, auth.RoleAdmin),
		})
		return true

	case "/api/v2/apps/local-mcp-action":
		r.Body = http.MaxBytesReader(w, r.Body, 8<<10)
		defer r.Body.Close()
		var body struct {
			ID     string `json:"id"`
			Action string `json:"action"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
			return true
		}
		action := strings.ToLower(strings.TrimSpace(body.Action))
		if action == "approve" || action == "activate" {
			jsonReply(w, http.StatusForbidden, map[string]string{
				"error":   "mcp_approve_forbidden",
				"message": "该操作仅限管理员在应用中心手动批准激活",
			})
			return true
		}
		var (
			app apps.PublicApp
			err error
		)
		switch action {
		case "start", "wake", "stop", "restart", "trigger-cron", "run_cron":
			app, err = appsMgr.ExecuteAction(r.Context(), body.ID, action)
		case "reload":
			err = appsMgr.ReloadFromMCP()
			if err == nil {
				app, err = appsMgr.GetForUser(body.ID, 0, auth.RoleAdmin)
			}
		default:
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_action"})
			return true
		}
		if err != nil {
			appsErrorReply(w, err)
			return true
		}
		jsonReply(w, http.StatusOK, map[string]any{"ok": true, "action": body.Action, "app": app})
		return true

	case "/api/v2/apps/local-mcp-logs":
		r.Body = http.MaxBytesReader(w, r.Body, 8<<10)
		defer r.Body.Close()
		var body struct {
			ID    string `json:"id"`
			Limit int    `json:"limit"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
			return true
		}
		if body.Limit <= 0 || body.Limit > 30 {
			body.Limit = 10
		}
		app, err := appsMgr.GetForUser(body.ID, 0, auth.RoleAdmin)
		if err != nil {
			appsErrorReply(w, err)
			return true
		}
		logs, _ := appsMgr.GetWebLogs(body.ID)
		runs, _ := appsMgr.GetCronRuns(body.ID, body.Limit)
		jsonReply(w, http.StatusOK, map[string]any{
			"id":        body.ID,
			"web":       app.Web,
			"cron":      app.Cron,
			"webOutput": logs,
			"cronRuns":  runs,
		})
		return true

	case "/api/v2/apps/local-mcp-probe":
		r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
		defer r.Body.Close()
		var body struct {
			ID     string `json:"id"`
			Method string `json:"method"`
			Path   string `json:"path"`
			Body   string `json:"body"`
			Role   string `json:"role"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
			return true
		}
		res, err := appsMgr.ProbeApp(r.Context(), body.ID, apps.AppProbeRequest{
			Method: body.Method,
			Path:   body.Path,
			Body:   body.Body,
			Role:   body.Role,
		})
		if err != nil {
			appsErrorReply(w, err)
			return true
		}
		jsonReply(w, http.StatusOK, res)
		return true
	}
	return false
}

// handleHTTPMCPEndpoint serves the Streamable HTTP and SSE Model Context Protocol
// endpoints (/api/v2/mcp, /api/v2/mcp/sse, /api/v2/mcp/message) for local & LAN AI Agents.
func handleHTTPMCPEndpoint(
	w http.ResponseWriter,
	r *http.Request,
	appsMgr *apps.Manager,
	managementMCP *mcpManagement,
	resolveSession func(*http.Request) (apps.UserIdentity, bool),
	sseHub *mcpSSEHub,
) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")

	isLoop, isLAN := isPrivateOrLoopbackAddr(r.RemoteAddr)
	if (!isLoop && !isLAN) || !localMCPHost(r.Host) || hasReverseProxyHeaders(r) {
		jsonReply(w, http.StatusForbidden, map[string]string{
			"error":   "mcp_lan_only",
			"message": "LightIsle MCP 仅允许本机回环或局域网私有 IP 直连访问，拒绝公网、非本地 Host 或反向代理转发请求",
		})
		return
	}
	origins := r.Header.Values("Origin")
	if len(origins) > 1 || (len(origins) == 1 && origins[0] != "" && !originMatchesHost(origins[0], r.Host)) {
		jsonReply(w, http.StatusForbidden, map[string]string{"error": "cross_origin_request_rejected"})
		return
	}
	cfg := appsMgr.GetSystemConfig()
	if !cfg.MCPEnabled {
		jsonReply(w, http.StatusForbidden, map[string]string{
			"error":   "mcp_disabled",
			"message": apps.MCPDisabledMessage,
		})
		return
	}
	if !isLoop && !cfg.MCPLanEnabled {
		jsonReply(w, http.StatusForbidden, map[string]string{
			"error":   "mcp_lan_disabled",
			"message": "局域网 MCP 当前处于关闭状态，请先在 LightIsle 管理端开启「允许局域网 MCP 接入」开关",
		})
		return
	}

	mcpTok := extractMCPTokenFromRequest(r)
	var (
		authedUser auth.User
		authedSess string
		authedConn auth.MCPConnection
		tokenOK    bool
		cookieOK   bool
	)
	if managementMCP != nil && managementMCP.store != nil && mcpTok != "" {
		authedUser, authedSess, authedConn, tokenOK = managementMCP.authenticateBearerOrSystem(mcpTok)
	}
	reloadOnlyOK := !tokenOK && appsMgr.VerifyReloadToken(mcpTok)
	if !tokenOK && !reloadOnlyOK && resolveSession != nil {
		if u, ok := resolveSession(r); ok && u.Role == auth.RoleAdmin {
			cookieOK = true
			authedUser = auth.User{ID: u.ID, Username: u.Username, Role: u.Role, Enabled: true}
			authedSess = u.SessionToken
			authedConn = auth.MCPConnection{ID: "web-admin", Label: "web-admin", CanWrite: true}
		}
	}
	if !tokenOK && !reloadOnlyOK && !cookieOK {
		w.Header().Set("WWW-Authenticate", `Bearer realm="LightIsle MCP"`)
		jsonReply(w, http.StatusUnauthorized, map[string]string{
			"error":   "mcp_unauthorized",
			"message": "缺少有效的 LightIsle MCP 令牌（Authorization: Bearer <token> 或 X-LightIsle-MCP-Token）",
		})
		return
	}
	if cookieOK && r.Method != http.MethodGet && r.Method != http.MethodHead {
		if r.Header.Get("X-LightIsle-Request") != "1" {
			jsonReply(w, http.StatusForbidden, map[string]string{"error": "request_header_required"})
			return
		}
	}
	sseOwnerKey := fmt.Sprintf("u:%d|c:%s|r:%t", authedUser.ID, authedConn.ID, reloadOnlyOK)

	transport := "local-http"
	if !isLoop {
		transport = "lan-http"
	} else if strings.EqualFold(strings.TrimSpace(r.Header.Get("X-LightIsle-MCP-Transport")), "stdio") {
		transport = "stdio"
	}

	path := r.URL.Path
	if r.Method == http.MethodGet {
		accept := strings.ToLower(r.Header.Get("Accept"))
		if path == "/api/v2/mcp/sse" || strings.Contains(accept, "text/event-stream") {
			serveMCPSSEStream(w, r, sseHub, sseOwnerKey)
			return
		}
		jsonReply(w, http.StatusOK, map[string]any{
			"service":         mcpServerName,
			"version":         mcpServerVersion,
			"protocolVersion": "2025-06-18",
			"status":          "online",
			"mcpEnabled":      cfg.MCPEnabled,
			"mcpLanEnabled":   cfg.MCPLanEnabled,
		})
		return
	}

	if r.Method == http.MethodDelete {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "GET, POST, DELETE")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if version := strings.TrimSpace(r.Header.Get("MCP-Protocol-Version")); version != "" && !managementMCPVersion(version) {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "mcp_unsupported_protocol_version"})
		return
	}

	execRPC := func(tr string, rawBody []byte) ([]byte, bool) {
		if managementMCP != nil && (tokenOK || cookieOK) {
			return managementMCP.ExecuteAuthorizedRPC(r.Context(), tr, r.RemoteAddr, authedUser, authedSess, authedConn, rawBody)
		}
		return apps.ExecuteMCPJSONRPC(
			r.Context(),
			appsMgr.DataDir(),
			appsMgr.ExecPath(),
			tr,
			r.RemoteAddr,
			appsMgr,
			rawBody,
		)
	}

	if path == "/api/v2/mcp/message" {
		handleMCPSSESessionMessage(w, r, transport, sseHub, sseOwnerKey, execRPC)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 4<<20)
	defer r.Body.Close()
	rawBody, err := io.ReadAll(r.Body)
	if err != nil {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}

	respBytes, hasResp := execRPC(transport, rawBody)
	if sessionID := strings.TrimSpace(r.Header.Get("Mcp-Session-Id")); sessionID != "" {
		w.Header().Set("Mcp-Session-Id", sessionID)
	} else {
		w.Header().Set("Mcp-Session-Id", sseHub.sessionHeaderForKey(sseOwnerKey))
	}
	if !hasResp {
		w.WriteHeader(http.StatusAccepted)
		return
	}
	accept := strings.ToLower(r.Header.Get("Accept"))
	if strings.Contains(accept, "text/event-stream") && !strings.Contains(accept, "application/json") && !strings.Contains(accept, "*/*") {
		w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
		w.Header().Set("Cache-Control", "no-cache")
		w.WriteHeader(http.StatusOK)
		fmt.Fprintf(w, "event: message\ndata: %s\n\n", bytes.TrimSpace(respBytes))
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(respBytes)
}

func serveMCPSSEStream(w http.ResponseWriter, r *http.Request, sseHub *mcpSSEHub, ownerKey string) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}
	sess, registered := sseHub.register(ownerKey)
	if !registered {
		jsonReply(w, http.StatusTooManyRequests, map[string]string{
			"error":   "mcp_sse_limit_reached",
			"message": "活动 MCP SSE 会话已达上限 (16)",
		})
		return
	}
	defer sseHub.remove(sess.id)

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	msgEndpoint := "/api/v2/mcp/message?sessionId=" + url.QueryEscape(sess.id)
	fmt.Fprintf(w, "event: endpoint\ndata: %s\n\n", msgEndpoint)
	flusher.Flush()

	pingTicker := time.NewTicker(20 * time.Second)
	defer pingTicker.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-sess.done:
			return
		case msg := <-sess.msgCh:
			sess.touch()
			fmt.Fprintf(w, "event: message\ndata: %s\n\n", msg)
			flusher.Flush()
		case <-pingTicker.C:
			if time.Since(time.Unix(0, sess.lastActive.Load())) > mcpSSEIdleTimeout {
				return
			}
			fmt.Fprint(w, ": ping\n\n")
			flusher.Flush()
		}
	}
}

func handleMCPSSESessionMessage(
	w http.ResponseWriter,
	r *http.Request,
	transport string,
	sseHub *mcpSSEHub,
	callerOwnerKey string,
	execRPC func(string, []byte) ([]byte, bool),
) {
	sessionID := strings.TrimSpace(r.URL.Query().Get("sessionId"))
	if sessionID == "" {
		sessionID = strings.TrimSpace(r.URL.Query().Get("session_id"))
	}
	if sessionID == "" {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "missing_session_id"})
		return
	}
	sess := sseHub.get(sessionID)
	if sess == nil {
		jsonReply(w, http.StatusNotFound, map[string]string{"error": "mcp_session_not_found"})
		return
	}
	if sess.ownerKey != callerOwnerKey {
		jsonReply(w, http.StatusForbidden, map[string]string{"error": "mcp_session_forbidden"})
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 4<<20)
	defer r.Body.Close()
	rawBody, err := io.ReadAll(r.Body)
	if err != nil {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}

	respBytes, hasResp := execRPC(transport+"-sse", rawBody)
	if hasResp && len(respBytes) > 0 {
		found, delivered := sseHub.send(sessionID, respBytes)
		if !found {
			jsonReply(w, http.StatusNotFound, map[string]string{"error": "mcp_session_not_found"})
			return
		}
		if !delivered {
			jsonReply(w, http.StatusTooManyRequests, map[string]string{"error": "mcp_session_queue_full"})
			return
		}
	}
	jsonReply(w, http.StatusAccepted, map[string]bool{"accepted": true})
}
