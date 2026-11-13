package apps

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

const (
	maxMCPDebugLogEntries = 50
	maxPluginRWBytes      = 2 << 20 // 2 MiB
)

var mcpLogMu sync.Mutex

type MCPCallLogEntry struct {
	ID              string `json:"id"`
	Timestamp       string `json:"timestamp"`
	Transport       string `json:"transport"`
	RemoteAddr      string `json:"remoteAddr,omitempty"`
	Method          string `json:"method"`
	Target          string `json:"target,omitempty"`
	DurationMs      int64  `json:"durationMs"`
	IsError         bool   `json:"isError"`
	RequestSummary  string `json:"requestSummary,omitempty"`
	ResponsePreview string `json:"responsePreview,omitempty"`
}

func debugToolDefinitions() []map[string]any {
	return []map[string]any{
		{
			"name":        "lightisle_read_plugin_file",
			"description": "安全读取 plugins/<id>/ 目录下的代码或配置文件（用于局域网远程开发或排查问题；env.json 仅返回键名不回显密钥）",
			"inputSchema": map[string]any{
				"type":     "object",
				"required": []string{"id", "path"},
				"properties": map[string]any{
					"id":   map[string]any{"type": "string", "description": "插件唯一标识"},
					"path": map[string]any{"type": "string", "description": "插件目录内的相对文件路径（如 plugin.json、run-web.sh、ui/index.html）"},
				},
			},
		},
		{
			"name":        "lightisle_write_plugin_file",
			"description": "在 plugins/<id>/ 目录下安全创建或更新代码与配置文件（支持局域网 MCP 远程编写插件代码，自动设置脚本 0700 / 普通文件 0600 权限）",
			"inputSchema": map[string]any{
				"type":     "object",
				"required": []string{"id", "path", "content"},
				"properties": map[string]any{
					"id":         map[string]any{"type": "string", "description": "插件唯一标识"},
					"path":       map[string]any{"type": "string", "description": "插件目录内的相对文件路径（如 plugin.json、run-web.sh、server.py、ui/index.html）"},
					"content":    map[string]any{"type": "string", "description": "完整的 UTF-8 文件内容"},
					"executable": map[string]any{"type": "boolean", "description": "是否赋予 0700 可执行权限（.sh 脚本默认自动设为 true）"},
				},
			},
		},
		{
			"name":        "lightisle_app_action",
			"description": "控制轻应用插件运行状态以供开发调试（支持 start / wake / stop / restart / run_cron / reload）",
			"inputSchema": map[string]any{
				"type":     "object",
				"required": []string{"id", "action"},
				"properties": map[string]any{
					"id":     map[string]any{"type": "string", "description": "插件唯一标识"},
					"action": map[string]any{"type": "string", "description": "操作类型：start | wake | stop | restart | run_cron | reload"},
				},
			},
		},
		{
			"name":        "lightisle_get_app_logs",
			"description": "获取轻应用插件的实时进程状态、内存占用、动态端口、最近 stdout/stderr 控制台输出与 Cron 定时执行记录",
			"inputSchema": map[string]any{
				"type":     "object",
				"required": []string{"id"},
				"properties": map[string]any{
					"id":    map[string]any{"type": "string", "description": "插件唯一标识"},
					"limit": map[string]any{"type": "integer", "description": "返回的最近 Cron 运行记录条数（默认 10）"},
				},
			},
		},
		{
			"name":        "lightisle_probe_app",
			"description": "向插件网关发送一次合成 HTTP 探针请求（自动唤醒按需实例并注入 X-LightIsle-Proxy-Secret 与测试身份头），返回状态码、耗时、响应头、响应体预览与最新进程日志",
			"inputSchema": map[string]any{
				"type":     "object",
				"required": []string{"id"},
				"properties": map[string]any{
					"id":     map[string]any{"type": "string", "description": "插件唯一标识"},
					"method": map[string]any{"type": "string", "description": "HTTP 方法：GET | POST | HEAD（默认 GET）"},
					"path":   map[string]any{"type": "string", "description": "测试子路径（如 / 或 /api/health，默认 /）"},
					"body":   map[string]any{"type": "string", "description": "可选请求体内容"},
					"role":   map[string]any{"type": "string", "description": "模拟访问角色：admin | member（默认 admin）"},
				},
			},
		},
	}
}

func sanitizeRelativePluginFilePath(rel string) (string, error) {
	rel = strings.TrimSpace(rel)
	if rel == "" || strings.HasPrefix(rel, "/") || strings.Contains(rel, "\\") || strings.ContainsRune(rel, 0) {
		return "", fmt.Errorf("文件路径不合法: %q", rel)
	}
	cleaned := filepath.Clean(rel)
	if cleaned == "." || cleaned == ".." || strings.HasPrefix(cleaned, "../") {
		return "", fmt.Errorf("禁止访问插件目录之外的路径: %q", rel)
	}
	parts := strings.Split(cleaned, "/")
	for _, p := range parts {
		if p == "" || p == "." || p == ".." {
			return "", fmt.Errorf("文件路径包含非法段: %q", rel)
		}
	}
	return cleaned, nil
}

func ensureSafeSubdirsInRoot(root *os.Root, dirRel string) error {
	if dirRel == "" || dirRel == "." {
		return nil
	}
	parts := strings.Split(dirRel, "/")
	curr := ""
	for _, part := range parts {
		if curr == "" {
			curr = part
		} else {
			curr = curr + "/" + part
		}
		st, err := root.Lstat(curr)
		if err != nil {
			if os.IsNotExist(err) {
				if mkErr := root.Mkdir(curr, 0700); mkErr != nil {
					return mkErr
				}
				continue
			}
			return err
		}
		if st.Mode()&os.ModeSymlink != 0 || !st.IsDir() {
			return fmt.Errorf("路径 %q 不是普通目录或包含符号链接", curr)
		}
	}
	return nil
}

func toolReadPluginFile(dataDir string, mgr *Manager, rawArgs json.RawMessage) mcpToolResult {
	var args struct {
		ID   string `json:"id"`
		Path string `json:"path"`
	}
	if err := json.Unmarshal(rawArgs, &args); err != nil {
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: "参数解析失败: " + err.Error()}}}
	}
	id := strings.TrimSpace(args.ID)
	if !ValidPluginID(id) {
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: "非法插件 ID: " + id}}}
	}
	rel, err := sanitizeRelativePluginFilePath(args.Path)
	if err != nil {
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: err.Error()}}}
	}
	pluginDir, _, _, found := findPluginAcrossScanRoots(dataDir, mgr, id)
	if !found {
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: fmt.Sprintf("未找到插件 %s 目录（或所属外置盘当前离线）", id)}}}
	}
	root, err := os.OpenRoot(pluginDir)
	if err != nil {
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: fmt.Sprintf("无法打开插件 %s 目录: %v", id, err)}}}
	}
	defer root.Close()

	if rel == "env.json" {
		envMap, envErr := ReadEnvFile(root, "env.json")
		if envErr != nil {
			return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: envErr.Error()}}}
		}
		keys := make([]string, 0, len(envMap))
		for k := range envMap {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		out, _ := json.MarshalIndent(map[string]any{
			"id":       id,
			"path":     rel,
			"redacted": true,
			"keys":     keys,
			"note":     "出于安全保护，env.json 仅返回已配置键名列表，不回显密钥明文。",
		}, "", "  ")
		return mcpToolResult{Content: []mcpToolContent{{Type: "text", Text: string(out)}}}
	}

	st, err := root.Lstat(rel)
	if err != nil {
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: fmt.Sprintf("读取文件 %s 失败: %v", rel, err)}}}
	}
	if !st.Mode().IsRegular() {
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: fmt.Sprintf("路径 %s 不是普通文件", rel)}}}
	}
	if st.Size() > maxPluginRWBytes {
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: fmt.Sprintf("文件 %s 超过 2 MiB 读取上限", rel)}}}
	}
	f, err := root.Open(rel)
	if err != nil {
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: err.Error()}}}
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, maxPluginRWBytes+1))
	if err != nil || len(data) > maxPluginRWBytes {
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: "读取文件内容失败或超限"}}}
	}
	out, _ := json.MarshalIndent(map[string]any{
		"id":      id,
		"path":    rel,
		"size":    len(data),
		"mode":    fmt.Sprintf("%04o", st.Mode().Perm()),
		"content": string(data),
	}, "", "  ")
	return mcpToolResult{Content: []mcpToolContent{{Type: "text", Text: string(out)}}}
}

func toolWritePluginFile(dataDir string, mgr *Manager, rawArgs json.RawMessage) mcpToolResult {
	var args struct {
		ID         string `json:"id"`
		Path       string `json:"path"`
		Content    string `json:"content"`
		Executable *bool  `json:"executable"`
	}
	if err := json.Unmarshal(rawArgs, &args); err != nil {
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: "参数解析失败: " + err.Error()}}}
	}
	id := strings.TrimSpace(args.ID)
	if !ValidPluginID(id) {
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: "非法插件 ID: " + id}}}
	}
	rel, err := sanitizeRelativePluginFilePath(args.Path)
	if err != nil {
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: err.Error()}}}
	}
	if len(args.Content) > maxPluginRWBytes {
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: "文件内容超过 2 MiB 限制"}}}
	}
	if err := persistPendingForMCP(dataDir, mgr, id); err != nil {
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: err.Error()}}}
	}
	pluginDir, _, _, found := findPluginAcrossScanRoots(dataDir, mgr, id)
	if !found {
		return mcpToolResult{
			IsError: true,
			Content: []mcpToolContent{{Type: "text", Text: fmt.Sprintf("插件目录 plugins/%s 不存在（或所属外置盘离线），请先调用 lightisle_scaffold_app 创建脚手架", id)}},
		}
	}
	if st, statErr := os.Lstat(pluginDir); statErr != nil || !st.IsDir() {
		return mcpToolResult{
			IsError: true,
			Content: []mcpToolContent{{Type: "text", Text: fmt.Sprintf("插件目录 plugins/%s 不可访问", id)}},
		}
	}
	root, err := os.OpenRoot(pluginDir)
	if err != nil {
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: err.Error()}}}
	}
	defer root.Close()

	dirRel := filepath.Dir(rel)
	if err := ensureSafeSubdirsInRoot(root, dirRel); err != nil {
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: err.Error()}}}
	}
	if existing, lerr := root.Lstat(rel); lerr == nil && existing.Mode()&os.ModeSymlink != 0 {
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: "拒绝覆写符号链接: " + rel}}}
	}

	isExec := strings.HasSuffix(rel, ".sh") || rel == "run-web.sh" || rel == "run-cron.sh"
	if args.Executable != nil {
		isExec = *args.Executable
	}
	perm := os.FileMode(0600)
	if isExec {
		perm = 0700
	}

	tmpRel := fmt.Sprintf("%s.%d.tmp", rel, time.Now().UnixNano())
	f, err := root.OpenFile(tmpRel, os.O_CREATE|os.O_EXCL|os.O_WRONLY, perm)
	if err != nil {
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: "创建临时文件失败: " + err.Error()}}}
	}
	_, writeErr := f.WriteString(args.Content)
	if writeErr == nil {
		writeErr = f.Chmod(perm)
	}
	if writeErr == nil {
		writeErr = f.Sync()
	}
	closeErr := f.Close()
	if writeErr != nil || closeErr != nil {
		_ = root.Remove(tmpRel)
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: "写入文件失败"}}}
	}
	if err := root.Rename(tmpRel, rel); err != nil {
		_ = root.Remove(tmpRel)
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: "原子替换文件失败: " + err.Error()}}}
	}
	out, _ := json.MarshalIndent(map[string]any{
		"written": true,
		"id":      id,
		"path":    rel,
		"bytes":   len(args.Content),
		"mode":    fmt.Sprintf("%04o", perm),
	}, "", "  ")
	return mcpToolResult{Content: []mcpToolContent{{Type: "text", Text: string(out)}}}
}

func toolAppAction(ctx context.Context, dataDir string, mgr *Manager, rawArgs json.RawMessage) mcpToolResult {
	var args struct {
		ID     string `json:"id"`
		Action string `json:"action"`
	}
	if err := json.Unmarshal(rawArgs, &args); err != nil {
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: "参数解析失败: " + err.Error()}}}
	}
	id := strings.TrimSpace(args.ID)
	action := strings.ToLower(strings.TrimSpace(args.Action))
	if !ValidPluginID(id) {
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: "非法插件 ID: " + id}}}
	}
	if action == "approve" || action == "activate" {
		return mcpToolResult{
			IsError: true,
			Content: []mcpToolContent{{Type: "text", Text: "该操作仅限管理员在应用中心手动批准激活"}},
		}
	}
	if mgr != nil {
		var (
			app PublicApp
			err error
		)
		if action == "reload" {
			err = mgr.ReloadFromMCP()
			if err == nil {
				app, err = mgr.GetForUser(id, 0, "admin")
			}
		} else {
			app, err = mgr.ExecuteAction(ctx, id, action)
		}
		if err != nil {
			return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: fmt.Sprintf("执行 %s 失败: %v", action, err)}}}
		}
		raw, _ := json.MarshalIndent(map[string]any{"ok": true, "action": action, "app": app}, "", "  ")
		return mcpToolResult{Content: []mcpToolContent{{Type: "text", Text: string(raw)}}}
	}
	respBytes, err := callLocalCoreMCPHelper(ctx, dataDir, "/api/v2/apps/local-mcp-action", map[string]any{
		"id":     id,
		"action": action,
	})
	if err != nil {
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: err.Error()}}}
	}
	return mcpToolResult{Content: []mcpToolContent{{Type: "text", Text: string(respBytes)}}}
}

func toolGetAppLogs(ctx context.Context, dataDir string, mgr *Manager, rawArgs json.RawMessage) mcpToolResult {
	var args struct {
		ID    string `json:"id"`
		Limit int    `json:"limit"`
	}
	if err := json.Unmarshal(rawArgs, &args); err != nil {
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: "参数解析失败: " + err.Error()}}}
	}
	id := strings.TrimSpace(args.ID)
	if !ValidPluginID(id) {
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: "非法插件 ID: " + id}}}
	}
	limit := args.Limit
	if limit <= 0 || limit > 30 {
		limit = 10
	}
	if mgr != nil {
		app, err := mgr.GetForUser(id, 0, "admin")
		if err != nil {
			return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: fmt.Sprintf("未找到插件 %s: %v", id, err)}}}
		}
		logs, _ := mgr.GetWebLogs(id)
		runs, _ := mgr.GetCronRuns(id, limit)
		raw, _ := json.MarshalIndent(map[string]any{
			"id":        id,
			"web":       app.Web,
			"cron":      app.Cron,
			"webOutput": logs,
			"cronRuns":  runs,
		}, "", "  ")
		return mcpToolResult{Content: []mcpToolContent{{Type: "text", Text: string(raw)}}}
	}
	respBytes, err := callLocalCoreMCPHelper(ctx, dataDir, "/api/v2/apps/local-mcp-logs", map[string]any{
		"id":    id,
		"limit": limit,
	})
	if err != nil {
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: err.Error()}}}
	}
	return mcpToolResult{Content: []mcpToolContent{{Type: "text", Text: string(respBytes)}}}
}

func toolProbeApp(ctx context.Context, dataDir string, mgr *Manager, rawArgs json.RawMessage) mcpToolResult {
	var args struct {
		ID     string `json:"id"`
		Method string `json:"method"`
		Path   string `json:"path"`
		Body   string `json:"body"`
		Role   string `json:"role"`
	}
	if err := json.Unmarshal(rawArgs, &args); err != nil {
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: "参数解析失败: " + err.Error()}}}
	}
	id := strings.TrimSpace(args.ID)
	if !ValidPluginID(id) {
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: "非法插件 ID: " + id}}}
	}
	probeReq := AppProbeRequest{
		Method: args.Method,
		Path:   args.Path,
		Body:   args.Body,
		Role:   args.Role,
	}
	if mgr != nil {
		res, err := mgr.ProbeApp(ctx, id, probeReq)
		if err != nil {
			return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: fmt.Sprintf("探针请求失败: %v", err)}}}
		}
		raw, _ := json.MarshalIndent(res, "", "  ")
		return mcpToolResult{Content: []mcpToolContent{{Type: "text", Text: string(raw)}}}
	}
	respBytes, err := callLocalCoreMCPHelper(ctx, dataDir, "/api/v2/apps/local-mcp-probe", map[string]any{
		"id":     id,
		"method": args.Method,
		"path":   args.Path,
		"body":   args.Body,
		"role":   args.Role,
	})
	if err != nil {
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: err.Error()}}}
	}
	return mcpToolResult{Content: []mcpToolContent{{Type: "text", Text: string(respBytes)}}}
}

func callLocalCoreMCPHelper(ctx context.Context, dataDir, endpointPath string, payload map[string]any) ([]byte, error) {
	tokenBytes, err := os.ReadFile(filepath.Join(dataDir, ".mcp-reload-token"))
	if err != nil {
		return nil, fmt.Errorf("无法读取本机 MCP 令牌（请确认 LightIsle 正在运行且已开启 MCP）: %w", err)
	}
	token := strings.TrimSpace(string(tokenBytes))
	if token == "" {
		return nil, fmt.Errorf("本机 MCP 令牌为空")
	}
	baseURL := strings.TrimRight(os.Getenv("LIGHTISLE_CORE_URL"), "/")
	if baseURL == "" {
		baseURL = "http://127.0.0.1:16666"
	}
	body, _ := json.Marshal(payload)
	reqCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(reqCtx, http.MethodPost, baseURL+endpointPath, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-LightIsle-Request", "1")
	req.Header.Set("X-LightIsle-MCP-Token", token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("连接本机 LightIsle Core (%s) 失败: %w", baseURL, err)
	}
	defer resp.Body.Close()
	respRaw, _ := io.ReadAll(io.LimitReader(resp.Body, 256<<10))
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("LightIsle Core 返回 HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(respRaw)))
	}
	var pretty bytes.Buffer
	if json.Indent(&pretty, respRaw, "", "  ") == nil {
		return pretty.Bytes(), nil
	}
	return respRaw, nil
}

func sanitizeMCPRequestSummary(target, raw string) string {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" || !strings.HasPrefix(trimmed, "{") {
		return raw
	}
	var doc map[string]any
	if err := json.Unmarshal([]byte(trimmed), &doc); err != nil || doc == nil {
		return raw
	}
	pathVal, _ := doc["path"].(string)
	cleanPath := strings.TrimSpace(pathVal)
	isEnvJSON := cleanPath == "env.json" || strings.HasSuffix(cleanPath, "/env.json")
	_, hasContent := doc["content"]

	changed := false
	for k, v := range doc {
		lowerKey := strings.ToLower(strings.TrimSpace(k))
		if strings.Contains(lowerKey, "password") || strings.Contains(lowerKey, "secret") || lowerKey == "token" {
			doc[k] = "<redacted>"
			changed = true
			continue
		}
		if lowerKey == "url" {
			if sv, ok := v.(string); ok {
				if strings.HasPrefix(strings.ToLower(sv), "magnet:") {
					doc[k] = "magnet:?<redacted>"
					changed = true
				} else if idx := strings.IndexAny(sv, "?#@"); idx >= 0 {
					doc[k] = "<redacted-url>"
					changed = true
				}
			}
		}
	}
	if hasContent {
		switch cv := doc["content"].(type) {
		case string:
			doc["content"] = fmt.Sprintf("<redacted %d bytes>", len(cv))
		default:
			encoded, _ := json.Marshal(cv)
			doc["content"] = fmt.Sprintf("<redacted %d bytes>", len(encoded))
		}
		changed = true
	}
	if isEnvJSON {
		for k, v := range doc {
			switch k {
			case "id", "path", "content", "executable":
				continue
			}
			if sv, ok := v.(string); ok {
				doc[k] = fmt.Sprintf("<redacted %d bytes>", len(sv))
			} else {
				encoded, _ := json.Marshal(v)
				doc[k] = fmt.Sprintf("<redacted %d bytes>", len(encoded))
			}
			changed = true
		}
	}
	if !changed && target != "lightisle_write_plugin_file" {
		return raw
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(doc); err != nil {
		return raw
	}
	return strings.TrimRight(buf.String(), "\n")
}

func truncateUTF8Preview(s string, maxBytes int) string {
	s = strings.ToValidUTF8(s, "")
	if maxBytes <= 0 {
		return ""
	}
	if len(s) <= maxBytes {
		return s
	}
	cut := 0
	for cut < len(s) {
		_, width := utf8.DecodeRuneInString(s[cut:])
		if width <= 0 || cut+width > maxBytes {
			break
		}
		cut += width
	}
	return s[:cut] + "…"
}

func RecordMCPCall(dataDir string, entry MCPCallLogEntry) {
	if dataDir == "" {
		return
	}
	mcpLogMu.Lock()
	defer mcpLogMu.Unlock()

	if entry.ID == "" {
		entry.ID = fmt.Sprintf("mcp-%d", time.Now().UnixNano())
	}
	if entry.Timestamp == "" {
		entry.Timestamp = time.Now().UTC().Format(time.RFC3339)
	}
	entry.RequestSummary = truncateUTF8Preview(sanitizeMCPRequestSummary(entry.Target, entry.RequestSummary), 300)
	entry.ResponsePreview = truncateUTF8Preview(entry.ResponsePreview, 500)

	logPath := filepath.Join(dataDir, "mcp-debug-log.json")
	existing := readMCPCallLogsLocked(logPath)
	updated := make([]MCPCallLogEntry, 0, min(len(existing)+1, maxMCPDebugLogEntries))
	updated = append(updated, entry)
	for _, item := range existing {
		if len(updated) >= maxMCPDebugLogEntries {
			break
		}
		updated = append(updated, item)
	}
	raw, err := json.MarshalIndent(updated, "", "  ")
	if err != nil {
		return
	}
	tmp := fmt.Sprintf("%s.%d.tmp", logPath, time.Now().UnixNano())
	if err := os.WriteFile(tmp, raw, 0600); err == nil {
		if err := os.Rename(tmp, logPath); err != nil {
			_ = os.Remove(tmp)
		}
	}
}

func ReadMCPCallLogs(dataDir string) []MCPCallLogEntry {
	if dataDir == "" {
		return []MCPCallLogEntry{}
	}
	mcpLogMu.Lock()
	defer mcpLogMu.Unlock()
	return readMCPCallLogsLocked(filepath.Join(dataDir, "mcp-debug-log.json"))
}

func ClearMCPCallLogs(dataDir string) error {
	if dataDir == "" {
		return nil
	}
	mcpLogMu.Lock()
	defer mcpLogMu.Unlock()
	logPath := filepath.Join(dataDir, "mcp-debug-log.json")
	_ = os.Remove(logPath)
	return nil
}

func readMCPCallLogsLocked(logPath string) []MCPCallLogEntry {
	raw, err := os.ReadFile(logPath)
	if err != nil || len(raw) == 0 {
		return []MCPCallLogEntry{}
	}
	var entries []MCPCallLogEntry
	if err := json.Unmarshal(raw, &entries); err != nil {
		return []MCPCallLogEntry{}
	}
	return entries
}

func (m *Manager) GetMCPCallLogs() []MCPCallLogEntry {
	return ReadMCPCallLogs(m.dataDir)
}

func (m *Manager) ClearMCPCallLogs() error {
	return ClearMCPCallLogs(m.dataDir)
}
