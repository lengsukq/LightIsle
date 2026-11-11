package apps

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"time"
	"unicode/utf8"
)

const maxProbePreviewBytes = 16 << 10

type MCPConfigSnapshot struct {
	MCPEnabled       bool             `json:"mcpEnabled"`
	MCPLanEnabled    bool             `json:"mcpLanEnabled"`
	Token            string           `json:"mcpToken,omitempty"`
	Command          string           `json:"command"`
	LocalHTTPURL     string           `json:"localHttpUrl"`
	LanHTTPURL       string           `json:"lanHttpUrl,omitempty"`
	LanSSEURL        string           `json:"lanSseUrl,omitempty"`
	Prompt           string           `json:"mcpPrompt"`
	LanPrompt        string           `json:"lanMcpPrompt"`
	ClientConfigJSON string           `json:"mcpConfigJson"`
	PluginsDir       string           `json:"pluginsDir"`
	PluginDataDir    string           `json:"pluginDataDir"`
	UpdatedAt        string           `json:"updatedAt"`
	Config           AppsSystemConfig `json:"config"`
}

type AppProbeRequest struct {
	Method      string `json:"method,omitempty"`
	Path        string `json:"path,omitempty"`
	Body        string `json:"body,omitempty"`
	ContentType string `json:"contentType,omitempty"`
	UserID      int64  `json:"userId,omitempty"`
	Username    string `json:"username,omitempty"`
	Role        string `json:"role,omitempty"`
}

type AppProbeResult struct {
	AppID       string            `json:"appId"`
	Mode        string            `json:"mode"`
	Status      string            `json:"status"`
	Method      string            `json:"method"`
	TargetPath  string            `json:"targetPath"`
	StatusCode  int               `json:"statusCode"`
	DurationMs  int64             `json:"durationMs"`
	Headers     map[string]string `json:"headers"`
	BodyPreview string            `json:"bodyPreview"`
	Truncated   bool              `json:"truncated,omitempty"`
	WebLogs     string            `json:"webLogs,omitempty"`
	Error       string            `json:"error,omitempty"`
}

type limitedProbeRecorder struct {
	header      http.Header
	code        int
	wroteHeader bool
	buf         bytes.Buffer
	totalBytes  int64
}

func newLimitedProbeRecorder() *limitedProbeRecorder {
	return &limitedProbeRecorder{
		header: make(http.Header),
		code:   http.StatusOK,
	}
}

func (r *limitedProbeRecorder) Header() http.Header {
	return r.header
}

func (r *limitedProbeRecorder) WriteHeader(statusCode int) {
	if r.wroteHeader {
		return
	}
	r.code = statusCode
	r.wroteHeader = true
}

func (r *limitedProbeRecorder) Write(p []byte) (int, error) {
	if !r.wroteHeader {
		r.WriteHeader(http.StatusOK)
	}
	r.totalBytes += int64(len(p))
	const capLimit = maxProbePreviewBytes + 1
	if rem := capLimit - r.buf.Len(); rem > 0 {
		if len(p) > rem {
			_, _ = r.buf.Write(p[:rem])
		} else {
			_, _ = r.buf.Write(p)
		}
	}
	return len(p), nil
}

func (r *limitedProbeRecorder) Flush() {
	if !r.wroteHeader {
		r.WriteHeader(http.StatusOK)
	}
}

func (m *Manager) SetEndpointProvider(fn func() (localURL, lanURL string)) {
	m.mu.Lock()
	m.endpointFn = fn
	m.mu.Unlock()
}

func (m *Manager) Endpoints() (localURL, lanURL string) {
	m.mu.RLock()
	fn := m.endpointFn
	m.mu.RUnlock()
	if fn != nil {
		localURL, lanURL = fn()
	}
	localURL = strings.TrimRight(strings.TrimSpace(localURL), "/")
	lanURL = strings.TrimRight(strings.TrimSpace(lanURL), "/")
	if localURL == "" {
		localURL = strings.TrimRight(strings.TrimSpace(os.Getenv("LIGHTISLE_CORE_URL")), "/")
		if localURL == "" {
			localURL = "http://127.0.0.1:16666"
		}
	}
	if lanURL == "" {
		if ip := detectPrivateLANIPv4(); ip != "" {
			port := extractPortOrDefault(localURL, "16666")
			lanURL = "http://" + net.JoinHostPort(ip, port)
		}
	}
	return localURL, lanURL
}

func extractPortOrDefault(rawURL, fallback string) string {
	trimmed := strings.TrimPrefix(strings.TrimPrefix(rawURL, "http://"), "https://")
	if idx := strings.IndexByte(trimmed, '/'); idx >= 0 {
		trimmed = trimmed[:idx]
	}
	if _, port, err := net.SplitHostPort(trimmed); err == nil && port != "" {
		return port
	}
	return fallback
}

func detectPrivateLANIPv4() string {
	faces, err := net.Interfaces()
	if err != nil {
		return ""
	}
	var fallback string
	for _, face := range faces {
		if face.Flags&net.FlagUp == 0 || face.Flags&net.FlagLoopback != 0 {
			continue
		}
		if strings.HasPrefix(face.Name, "utun") || strings.HasPrefix(face.Name, "bridge") ||
			strings.HasPrefix(face.Name, "vnic") || strings.HasPrefix(face.Name, "awdl") {
			continue
		}
		addrs, _ := face.Addrs()
		for _, addr := range addrs {
			var ip net.IP
			switch a := addr.(type) {
			case *net.IPNet:
				ip = a.IP
			case *net.IPAddr:
				ip = a.IP
			}
			ip = ip.To4()
			if ip == nil {
				continue
			}
			if ip[0] == 10 || (ip[0] == 172 && ip[1] >= 16 && ip[1] <= 31) || (ip[0] == 192 && ip[1] == 168) {
				if face.Name == "en0" || face.Name == "en1" {
					return ip.String()
				}
				if fallback == "" {
					fallback = ip.String()
				}
			}
		}
	}
	return fallback
}

// GetSystemConfig reads apps-config.json without mutating files on disk.
func (m *Manager) GetSystemConfig() AppsSystemConfig {
	cfg, err := readSystemConfigFile(m.configPath)
	if err != nil {
		return AppsSystemConfig{MCPEnabled: false}
	}
	if !cfg.MCPEnabled && cfg.MCPLanEnabled {
		cfg.MCPLanEnabled = false
	}
	return cfg
}

func (m *Manager) MCPEnabled() bool    { return m.GetSystemConfig().MCPEnabled }
func (m *Manager) MCPLanEnabled() bool { return m.GetSystemConfig().MCPLanEnabled }

func (m *Manager) SetMCPEnabled(enabled bool) error {
	_, err := m.SetMCPConfig(&enabled, nil)
	return err
}

func (m *Manager) SetMCPConfig(mcpEnabled, mcpLanEnabled *bool) (AppsSystemConfig, error) {
	m.mutation.Lock()
	defer m.mutation.Unlock()
	cfg, err := readSystemConfigFile(m.configPath)
	if err != nil {
		return AppsSystemConfig{}, err
	}
	if mcpEnabled != nil {
		cfg.MCPEnabled = *mcpEnabled
		if !cfg.MCPEnabled {
			cfg.MCPLanEnabled = false
		}
	}
	if mcpLanEnabled != nil {
		cfg.MCPLanEnabled = *mcpLanEnabled
		if cfg.MCPLanEnabled {
			cfg.MCPEnabled = true
		}
	}
	cfg.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
	if err := writeSystemConfigFile(m.configPath, cfg); err != nil {
		return cfg, err
	}
	if cfg.MCPEnabled {
		if err := ensureReloadTokenFile(m.reloadTokenPath); err != nil {
			return cfg, err
		}
	} else {
		_ = os.Remove(m.reloadTokenPath)
	}
	return cfg, nil
}

func (m *Manager) ReadMCPToken() string {
	if !m.MCPEnabled() {
		return ""
	}
	raw, err := os.ReadFile(m.reloadTokenPath)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(raw))
}

func (m *Manager) RotateMCPToken() (string, error) {
	m.mutation.Lock()
	defer m.mutation.Unlock()
	cfg, err := readSystemConfigFile(m.configPath)
	if err != nil {
		return "", err
	}
	if !cfg.MCPEnabled {
		cfg.MCPEnabled = true
		cfg.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
		if err := writeSystemConfigFile(m.configPath, cfg); err != nil {
			return "", err
		}
	}
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	token := hex.EncodeToString(buf)
	if err := os.WriteFile(m.reloadTokenPath, []byte(token+"\n"), 0600); err != nil {
		return "", err
	}
	return token, nil
}

func (m *Manager) VerifyReloadToken(token string) bool {
	token = strings.TrimSpace(token)
	if token == "" || !m.MCPEnabled() {
		return false
	}
	raw, err := os.ReadFile(m.reloadTokenPath)
	if err != nil {
		return false
	}
	expected := strings.TrimSpace(string(raw))
	if expected == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(token), []byte(expected)) == 1
}

func (m *Manager) MCPCommand() string {
	bin := m.execPath
	if bin == "" {
		bin = "/Applications/LightIsle.app/Contents/Resources/core/lightisled"
	}
	return fmt.Sprintf("%s mcp --data-dir %q", bin, m.dataDir)
}

func (m *Manager) MCPBootstrapPrompt() string {
	bin := m.execPath
	if bin == "" {
		bin = "/Applications/LightIsle.app/Contents/Resources/core/lightisled"
	}
	return fmt.Sprintf("请帮我将当前 Mac 上的「LightIsle（轻屿）开发者 MCP Server」安装并注册到你的 MCP 配置文件中：\n\n- MCP 服务名称：lightisle-dev\n- 传输方式：stdio\n- 可执行命令：%s\n- 命令参数：[\"mcp\", \"--data-dir\", %q]\n\n操作要求：\n1. 请自动检测你当前所处的 Agent 环境（如 Claude Code、Codex、Cursor 或 Antigravity MCP 配置），写入上述 lightisle-dev MCP 配置；\n2. 配置完成后，请立即调用 lightisle_get_environment 工具和读取 lightisle://specs/plugin-v2 与 lightisle://specs/ui-theme 资源，验证连接是否成功；\n3. 今后当我让你为 LightIsle 开发或改造“应用 / 插件 / 定时脚本”时，请始终优先通过该 MCP 读取规范、创建脚手架、读写插件文件、使用 lightisle_probe_app / lightisle_get_app_logs 调试并触发热重载。", bin, m.dataDir)
}

func (m *Manager) MCPLanBootstrapPrompt(lanBaseURL string) string {
	_, defaultLan := m.Endpoints()
	base := strings.TrimRight(strings.TrimSpace(lanBaseURL), "/")
	if base == "" {
		base = defaultLan
	}
	if base == "" {
		base, _ = m.Endpoints()
	}
	token := m.ReadMCPToken()
	if token == "" {
		token = "<请先在 LightIsle 开启 MCP 并获取 Token>"
	}
	httpURL := base + "/api/v2/mcp"
	sseURL := base + "/api/v2/mcp/sse"
	return fmt.Sprintf("请帮我将局域网内的「LightIsle（轻屿）远程开发者 MCP Server」注册到你的 MCP 配置文件中：\n\n- MCP 服务名称：lightisle-lan\n- 传输方式：streamable-http（或 http / sse）\n- MCP HTTP 端点：%s\n- 备用 SSE 端点：%s\n- 鉴权请求头：Authorization: Bearer %s（或 X-LightIsle-MCP-Token: %s）\n\n操作要求：\n1. 请将上述局域网 MCP 服务写入你当前的 Agent 配置文件；\n2. 连接后立即读取 lightisle://specs/plugin-v2 与 lightisle://specs/ui-theme 规范并调用 lightisle_get_environment 与 lightisle_list_apps；\n3. 开发或调试插件时，直接使用 lightisle_scaffold_app 创建脚手架、lightisle_write_plugin_file 远程写入代码、lightisle_validate_and_reload 热重载，并通过 lightisle_probe_app 与 lightisle_get_app_logs 在线调试验证。", httpURL, sseURL, token, token)
}

func (m *Manager) MCPClientConfigJSON(lanBaseURL string) string {
	bin := m.execPath
	if bin == "" {
		bin = "/Applications/LightIsle.app/Contents/Resources/core/lightisled"
	}
	localBase, defaultLan := m.Endpoints()
	base := strings.TrimRight(strings.TrimSpace(lanBaseURL), "/")
	if base == "" {
		base = defaultLan
	}
	if base == "" {
		base = localBase
	}
	token := m.ReadMCPToken()
	if token == "" {
		token = "<YOUR_MCP_TOKEN>"
	}
	doc := map[string]any{
		"mcpServers": map[string]any{
			"lightisle-local": map[string]any{
				"command": bin,
				"args":    []string{"mcp", "--data-dir", m.dataDir},
			},
			"lightisle-lan": map[string]any{
				"type": "streamable-http",
				"url":  base + "/api/v2/mcp",
				"headers": map[string]string{
					"Authorization":         "Bearer " + token,
					"X-LightIsle-MCP-Token": token,
				},
			},
		},
	}
	raw, _ := json.MarshalIndent(doc, "", "  ")
	return string(raw)
}

func (m *Manager) BuildMCPConfigSnapshot(overrideLanBaseURL string) MCPConfigSnapshot {
	cfg := m.GetSystemConfig()
	localBase, lanBase := m.Endpoints()
	if strings.TrimSpace(overrideLanBaseURL) != "" {
		lanBase = strings.TrimRight(strings.TrimSpace(overrideLanBaseURL), "/")
	}
	var lanHTTP, lanSSE string
	if lanBase != "" {
		lanHTTP = lanBase + "/api/v2/mcp"
		lanSSE = lanBase + "/api/v2/mcp/sse"
	}
	return MCPConfigSnapshot{
		MCPEnabled:       cfg.MCPEnabled,
		MCPLanEnabled:    cfg.MCPLanEnabled,
		Token:            m.ReadMCPToken(),
		Command:          m.MCPCommand(),
		LocalHTTPURL:     localBase + "/api/v2/mcp",
		LanHTTPURL:       lanHTTP,
		LanSSEURL:        lanSSE,
		Prompt:           m.MCPBootstrapPrompt(),
		LanPrompt:        m.MCPLanBootstrapPrompt(lanBase),
		ClientConfigJSON: m.MCPClientConfigJSON(lanBase),
		PluginsDir:       m.pluginsDir,
		PluginDataDir:    m.pluginDataRoot,
		UpdatedAt:        cfg.UpdatedAt,
		Config:           cfg,
	}
}

// ProbeApp sends a synthetic diagnostic HTTP request through the plugin gateway
// (waking on-demand instances and injecting X-LightIsle-Proxy-Secret + user identity)
// so developers and AI Agents can inspect HTTP status, headers, body, and stderr logs.
func (m *Manager) ProbeApp(ctx context.Context, appID string, req AppProbeRequest) (AppProbeResult, error) {
	appID = strings.TrimSpace(appID)
	if !ValidPluginID(appID) {
		return AppProbeResult{}, ErrInvalid
	}
	snap, ok := m.snapshotApp(appID)
	if !ok {
		return AppProbeResult{}, ErrNotFound
	}
	if !snap.valid {
		return AppProbeResult{
			AppID:  appID,
			Status: StatusDisabled,
			Error:  snap.validationError,
		}, ErrInvalid
	}
	if snap.pendingActivation {
		return AppProbeResult{
			AppID:  appID,
			Status: StatusStopped,
			Error:  "该轻应用尚未经管理员首次激活确认",
		}, ErrPendingActivation
	}
	if snap.manifest.Web == nil || !snap.manifest.Web.Enabled {
		return AppProbeResult{
			AppID:  appID,
			Mode:   "none",
			Status: StatusDisabled,
			Error:  "该插件未启用 Web 界面",
		}, ErrDisabled
	}

	method := strings.ToUpper(strings.TrimSpace(req.Method))
	if method == "" {
		method = http.MethodGet
	}
	switch method {
	case http.MethodGet, http.MethodPost, http.MethodHead, http.MethodPut, http.MethodDelete:
	default:
		return AppProbeResult{}, ErrInvalid
	}

	subPath := strings.TrimSpace(req.Path)
	if subPath == "" {
		subPath = "/"
	}
	targetPath := subPath
	prefix := "/apps/" + appID
	if !strings.HasPrefix(targetPath, prefix) {
		if !strings.HasPrefix(targetPath, "/") {
			targetPath = "/" + targetPath
		}
		targetPath = prefix + targetPath
	}
	rest := strings.TrimPrefix(targetPath, prefix)
	if rest == "" {
		rest = "/"
	}

	user := UserIdentity{
		ID:       req.UserID,
		Username: strings.TrimSpace(req.Username),
		Role:     strings.TrimSpace(req.Role),
	}
	if user.ID <= 0 {
		user.ID = 1
	}
	if user.Username == "" {
		user.Username = "admin"
	}
	if user.Role == "" {
		user.Role = "admin"
	}

	probeCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()

	var bodyReader io.Reader
	if req.Body != "" {
		bodyReader = bytes.NewBufferString(req.Body)
	}
	httpReq, err := http.NewRequestWithContext(probeCtx, method, "http://127.0.0.1"+targetPath, bodyReader)
	if err != nil {
		return AppProbeResult{}, err
	}
	if req.ContentType != "" {
		httpReq.Header.Set("Content-Type", req.ContentType)
	}

	recorder := newLimitedProbeRecorder()
	started := time.Now()
	if snap.manifest.Web.Mode == WebModeStatic {
		m.serveStaticApp(recorder, httpReq, &snap, rest)
	} else {
		m.serveDynamicApp(recorder, httpReq, &snap, user, rest)
	}
	durationMs := time.Since(started).Milliseconds()

	headers := make(map[string]string, len(recorder.header))
	for k, vals := range recorder.header {
		if len(vals) > 0 {
			headers[k] = strings.Join(vals, ", ")
		}
	}
	rawBody := recorder.buf.Bytes()
	truncated := recorder.totalBytes > maxProbePreviewBytes || len(rawBody) > maxProbePreviewBytes
	if len(rawBody) > maxProbePreviewBytes {
		rawBody = rawBody[:maxProbePreviewBytes]
	}
	for len(rawBody) > 0 && !utf8.Valid(rawBody) {
		rawBody = rawBody[:len(rawBody)-1]
	}

	var webLogs string
	status := StatusStatic
	if snap.instance != nil {
		instSnap := snap.instance.Snapshot()
		status = instSnap.Status
		webLogs = snap.instance.Logs()
	}

	return AppProbeResult{
		AppID:       appID,
		Mode:        snap.manifest.Web.Mode,
		Status:      status,
		Method:      method,
		TargetPath:  targetPath,
		StatusCode:  recorder.code,
		DurationMs:  durationMs,
		Headers:     headers,
		BodyPreview: string(rawBody),
		Truncated:   truncated,
		WebLogs:     webLogs,
	}, nil
}

type MCPDebugExecRequest struct {
	Method string          `json:"method"`
	URI    string          `json:"uri,omitempty"`
	Tool   string          `json:"tool,omitempty"`
	Args   json.RawMessage `json:"args,omitempty"`
	RawRPC string          `json:"rawRpc,omitempty"`
}

type MCPDebugExecResult struct {
	RequestJSON  string            `json:"requestJson"`
	ResponseJSON string            `json:"responseJson"`
	DurationMs   int64             `json:"durationMs"`
	IsError      bool              `json:"isError"`
	Logs         []MCPCallLogEntry `json:"logs,omitempty"`
}

func isJSONRPCErrorResponse(respBytes []byte) bool {
	trimmed := bytes.TrimSpace(respBytes)
	if len(trimmed) == 0 {
		return false
	}
	var env struct {
		Error  json.RawMessage `json:"error"`
		Result struct {
			IsError bool `json:"isError"`
		} `json:"result"`
	}
	if err := json.Unmarshal(trimmed, &env); err != nil {
		return true
	}
	errField := bytes.TrimSpace(env.Error)
	if len(errField) > 0 && !bytes.Equal(errField, []byte("null")) {
		return true
	}
	return env.Result.IsError
}

// ExecuteDebugMCP runs a structured or raw JSON-RPC 2.0 request against the built-in
// MCP engine from the macOS / Web / Flutter MCP Inspector UI.
func (m *Manager) ExecuteDebugMCP(ctx context.Context, req MCPDebugExecRequest, remoteAddr string) MCPDebugExecResult {
	var rpcBytes []byte
	if strings.TrimSpace(req.RawRPC) != "" {
		rpcBytes = []byte(strings.TrimSpace(req.RawRPC))
	} else {
		method := strings.TrimSpace(req.Method)
		if method == "" {
			if req.Tool != "" {
				method = "tools/call"
			} else if req.URI != "" {
				method = "resources/read"
			} else {
				method = "tools/list"
			}
		}
		var params any
		switch method {
		case "tools/call":
			var argsObj any = map[string]any{}
			if len(req.Args) > 0 {
				_ = json.Unmarshal(req.Args, &argsObj)
			}
			params = map[string]any{
				"name":      strings.TrimSpace(req.Tool),
				"arguments": argsObj,
			}
		case "resources/read":
			params = map[string]any{
				"uri": strings.TrimSpace(req.URI),
			}
		default:
			params = map[string]any{}
		}
		envelope := map[string]any{
			"jsonrpc": "2.0",
			"id":      1,
			"method":  method,
			"params":  params,
		}
		rpcBytes, _ = json.MarshalIndent(envelope, "", "  ")
	}

	var prettyReq bytes.Buffer
	if json.Indent(&prettyReq, rpcBytes, "", "  ") == nil {
		rpcBytes = prettyReq.Bytes()
	}

	started := time.Now()
	if remoteAddr == "" {
		remoteAddr = "127.0.0.1"
	}
	respBytes, _ := ExecuteMCPJSONRPC(ctx, m.dataDir, m.execPath, "debug-ui", remoteAddr, m, rpcBytes)
	durationMs := time.Since(started).Milliseconds()

	var prettyResp bytes.Buffer
	respStr := string(respBytes)
	if len(respBytes) > 0 && json.Indent(&prettyResp, respBytes, "", "  ") == nil {
		respStr = prettyResp.String()
	}
	return MCPDebugExecResult{
		RequestJSON:  string(rpcBytes),
		ResponseJSON: respStr,
		DurationMs:   durationMs,
		IsError:      isJSONRPCErrorResponse(respBytes),
		Logs:         m.GetMCPCallLogs(),
	}
}

// ScaffoldApp creates a new plugin scaffold from UI or IPC and reloads the manager.
func (m *Manager) ScaffoldApp(rawArgs json.RawMessage, activate bool) (PublicApp, error) {
	res := toolScaffoldApp(m.dataDir, m, rawArgs)
	if res.IsError {
		msg := "创建插件脚手架失败"
		if len(res.Content) > 0 && res.Content[0].Text != "" {
			msg = res.Content[0].Text
		}
		return PublicApp{}, fmt.Errorf("%w: %s", ErrInvalid, msg)
	}
	var parsed struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(rawArgs, &parsed)
	id := strings.TrimSpace(parsed.ID)
	if err := m.Reload(); err != nil {
		return PublicApp{}, err
	}
	if activate && ValidPluginID(id) {
		return m.ApproveApp(id)
	}
	return m.GetForUser(id, 0, "admin")
}
