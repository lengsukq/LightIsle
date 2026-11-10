package apps

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/lengsukq/lightisle/core/internal/automation"
)

type jsonRPCRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type jsonRPCResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  any             `json:"result,omitempty"`
	Error   *jsonRPCError   `json:"error,omitempty"`
}

type jsonRPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type mcpToolContent struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

type mcpToolResult struct {
	Content []mcpToolContent `json:"content"`
	IsError bool             `json:"isError,omitempty"`
}

// RunMCP runs the built-in stdio Model Context Protocol (JSON-RPC 2.0) server.
// It never acquires the daemon database lock and checks apps-config.json on every call.
func RunMCP(ctx context.Context, dataDir, execPath string, in io.Reader, out io.Writer) error {
	scanner := bufio.NewScanner(in)
	scanner.Buffer(make([]byte, 64<<10), 2<<20)

	for scanner.Scan() {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 {
			continue
		}
		var req jsonRPCRequest
		if err := json.Unmarshal(line, &req); err != nil {
			writeRPC(out, jsonRPCResponse{
				JSONRPC: "2.0",
				ID:      json.RawMessage("null"),
				Error:   &jsonRPCError{Code: -32700, Message: "Parse error"},
			})
			continue
		}
		// Notifications have no ID and produce no response
		if len(req.ID) == 0 || string(req.ID) == "null" || strings.HasPrefix(req.Method, "notifications/") {
			continue
		}
		resp := handleMCPRequest(ctx, dataDir, execPath, req)
		writeRPC(out, resp)
	}
	return scanner.Err()
}

func writeRPC(out io.Writer, resp jsonRPCResponse) {
	raw, err := json.Marshal(resp)
	if err != nil {
		return
	}
	_, _ = out.Write(append(raw, '\n'))
}

func isMCPEnabledOnDisk(dataDir string) bool {
	cfg := readSystemConfigFile(filepath.Join(dataDir, "apps-config.json"))
	return cfg.MCPEnabled
}

func handleMCPRequest(ctx context.Context, dataDir, execPath string, req jsonRPCRequest) jsonRPCResponse {
	switch req.Method {
	case "initialize":
		return jsonRPCResponse{
			JSONRPC: "2.0",
			ID:      req.ID,
			Result: map[string]any{
				"protocolVersion": "2024-11-05",
				"capabilities": map[string]any{
					"resources": map[string]any{},
					"tools":     map[string]any{},
				},
				"serverInfo": map[string]any{
					"name":    "lightisle-mcp",
					"version": "2.0.0",
				},
			},
		}
	case "ping":
		return jsonRPCResponse{
			JSONRPC: "2.0",
			ID:      req.ID,
			Result:  map[string]any{},
		}
	case "resources/list":
		return jsonRPCResponse{
			JSONRPC: "2.0",
			ID:      req.ID,
			Result: map[string]any{
				"resources": []map[string]any{
					{
						"uri":         "lightisle://specs/plugin-v2",
						"name":        "LightIsle Plugin v2 Specification",
						"description": "LightIsle 轻应用与多语言插件 (plugins/<id>/plugin.json schemaVersion 2) 完整开发规范",
						"mimeType":    "text/markdown",
					},
					{
						"uri":         "lightisle://specs/automation-v1",
						"name":        "LightIsle Automation Script v1 Specification",
						"description": "LightIsle 自动化定时脚本 (automation/scripts/<id>/task.json schemaVersion 1) 与邮件模板规范",
						"mimeType":    "text/markdown",
					},
				},
			},
		}
	case "resources/read":
		if !isMCPEnabledOnDisk(dataDir) {
			return jsonRPCResponse{
				JSONRPC: "2.0",
				ID:      req.ID,
				Error:   &jsonRPCError{Code: -32003, Message: MCPDisabledMessage},
			}
		}
		var params struct {
			URI string `json:"uri"`
		}
		if err := json.Unmarshal(req.Params, &params); err != nil || params.URI == "" {
			return jsonRPCResponse{
				JSONRPC: "2.0",
				ID:      req.ID,
				Error:   &jsonRPCError{Code: -32602, Message: "Invalid params: uri required"},
			}
		}
		text, ok := readSpecResource(params.URI)
		if !ok {
			return jsonRPCResponse{
				JSONRPC: "2.0",
				ID:      req.ID,
				Error:   &jsonRPCError{Code: -32602, Message: "Unknown resource URI: " + params.URI},
			}
		}
		return jsonRPCResponse{
			JSONRPC: "2.0",
			ID:      req.ID,
			Result: map[string]any{
				"contents": []map[string]any{
					{
						"uri":      params.URI,
						"mimeType": "text/markdown",
						"text":     text,
					},
				},
			},
		}
	case "tools/list":
		return jsonRPCResponse{
			JSONRPC: "2.0",
			ID:      req.ID,
			Result: map[string]any{
				"tools": mcpToolDefinitions(),
			},
		}
	case "tools/call":
		if !isMCPEnabledOnDisk(dataDir) {
			return jsonRPCResponse{
				JSONRPC: "2.0",
				ID:      req.ID,
				Result: mcpToolResult{
					IsError: true,
					Content: []mcpToolContent{{Type: "text", Text: MCPDisabledMessage}},
				},
			}
		}
		var params struct {
			Name      string          `json:"name"`
			Arguments json.RawMessage `json:"arguments"`
		}
		if err := json.Unmarshal(req.Params, &params); err != nil || params.Name == "" {
			return jsonRPCResponse{
				JSONRPC: "2.0",
				ID:      req.ID,
				Error:   &jsonRPCError{Code: -32602, Message: "Invalid tool call params"},
			}
		}
		result := executeMCPTool(ctx, dataDir, execPath, params.Name, params.Arguments)
		return jsonRPCResponse{
			JSONRPC: "2.0",
			ID:      req.ID,
			Result:  result,
		}
	default:
		return jsonRPCResponse{
			JSONRPC: "2.0",
			ID:      req.ID,
			Error:   &jsonRPCError{Code: -32601, Message: "Method not found: " + req.Method},
		}
	}
}

func mcpToolDefinitions() []map[string]any {
	return []map[string]any{
		{
			"name":        "lightisle_get_environment",
			"description": "获取本机 LightIsle 插件目录、数据目录与已安装语言运行时路径（Python/uv/Node/Go/Swift/Bash）",
			"inputSchema": map[string]any{
				"type":       "object",
				"properties": map[string]any{},
			},
		},
		{
			"name":        "lightisle_list_apps",
			"description": "列出当前已安装的 LightIsle 轻应用与插件清单及静态校验状态",
			"inputSchema": map[string]any{
				"type":       "object",
				"properties": map[string]any{},
			},
		},
		{
			"name":        "lightisle_scaffold_app",
			"description": "在 plugins/<id>/ 下快速脚手架创建符合 Schema v2 规范的轻应用或插件目录（默认权限为 admin_only）",
			"inputSchema": map[string]any{
				"type":     "object",
				"required": []string{"id", "name"},
				"properties": map[string]any{
					"id":          map[string]any{"type": "string", "description": "插件唯一标识（匹配 ^[a-z][a-z0-9-]{0,40}$）"},
					"name":        map[string]any{"type": "string", "description": "应用显示名称"},
					"description": map[string]any{"type": "string", "description": "应用简介"},
					"category":    map[string]any{"type": "string", "description": "分类（network / media / system / utility / family）"},
					"mode":        map[string]any{"type": "string", "description": "Web 模式：static | on-demand | persistent | cron-only"},
					"runtime":     map[string]any{"type": "string", "description": "运行时：python | node | go | rust | java | shell | static"},
					"hasCron":     map[string]any{"type": "boolean", "description": "是否同时包含定时任务脚本"},
					"cron":        map[string]any{"type": "string", "description": "5 段标准 Cron 表达式（默认 0 * * * *）"},
				},
			},
		},
		{
			"name":        "lightisle_validate_and_reload",
			"description": "静态校验 plugins/<id>/plugin.json 与脚本权限，并通知正在运行的 LightIsle Core 热重载插件列表",
			"inputSchema": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"id": map[string]any{"type": "string", "description": "要校验的插件 ID（留空则校验全部）"},
				},
			},
		},
	}
}

func executeMCPTool(ctx context.Context, dataDir, execPath, name string, rawArgs json.RawMessage) mcpToolResult {
	switch name {
	case "lightisle_get_environment":
		return toolGetEnvironment(dataDir, execPath)
	case "lightisle_list_apps":
		return toolListApps(dataDir)
	case "lightisle_scaffold_app":
		return toolScaffoldApp(dataDir, rawArgs)
	case "lightisle_validate_and_reload":
		return toolValidateAndReload(ctx, dataDir, rawArgs)
	default:
		return mcpToolResult{
			IsError: true,
			Content: []mcpToolContent{{Type: "text", Text: "未知工具: " + name}},
		}
	}
}

func toolGetEnvironment(dataDir, execPath string) mcpToolResult {
	searchPaths := []string{"/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"}
	currentPath := os.Getenv("PATH")
	fullPath := strings.Join(append(searchPaths, currentPath), ":")
	_ = os.Setenv("PATH", fullPath)

	runtimes := map[string]string{}
	for _, bin := range []string{"python3", "uv", "node", "npm", "bun", "deno", "go", "swift", "bash", "sh"} {
		if p, err := exec.LookPath(bin); err == nil {
			runtimes[bin] = p
		}
	}
	payload := map[string]any{
		"dataDir":              dataDir,
		"pluginsDir":           filepath.Join(dataDir, "plugins"),
		"pluginDataDir":        filepath.Join(dataDir, "plugin-data"),
		"automationScriptsDir": filepath.Join(dataDir, "automation", "scripts"),
		"execPath":             execPath,
		"mcpEnabled":           true,
		"runtimes":             runtimes,
	}
	raw, _ := json.MarshalIndent(payload, "", "  ")
	return mcpToolResult{
		Content: []mcpToolContent{{Type: "text", Text: string(raw)}},
	}
}

func toolListApps(dataDir string) mcpToolResult {
	pluginsDir := filepath.Join(dataDir, "plugins")
	_ = os.MkdirAll(pluginsDir, 0700)
	entries, err := os.ReadDir(pluginsDir)
	if err != nil {
		return mcpToolResult{
			IsError: true,
			Content: []mcpToolContent{{Type: "text", Text: fmt.Sprintf("读取插件目录失败: %v", err)}},
		}
	}
	items := make([]map[string]any, 0, len(entries))
	for _, entry := range entries {
		name := entry.Name()
		if strings.HasPrefix(name, ".") || !entry.IsDir() || entry.Type()&os.ModeSymlink != 0 {
			continue
		}
		pluginDir := filepath.Join(pluginsDir, name)
		root, err := os.OpenRoot(pluginDir)
		if err != nil {
			items = append(items, map[string]any{"id": name, "valid": false, "error": err.Error()})
			continue
		}
		raw, _, readErr := readCheckedFile(root, "plugin.json", maxManifestBytes)
		if readErr != nil {
			root.Close()
			items = append(items, map[string]any{"id": name, "valid": false, "error": "无法读取 plugin.json"})
			continue
		}
		manifest, valErr := ValidateManifest(root, name, raw)
		root.Close()
		if valErr != nil {
			items = append(items, map[string]any{"id": name, "valid": false, "error": valErr.Error()})
			continue
		}
		items = append(items, map[string]any{
			"id":        manifest.ID,
			"name":      manifest.Name,
			"version":   manifest.Version,
			"category":  manifest.Category,
			"valid":     true,
			"pluginDir": pluginDir,
			"dataDir":   filepath.Join(dataDir, "plugin-data", name),
			"manifest":  manifest,
		})
	}
	raw, _ := json.MarshalIndent(map[string]any{"apps": items}, "", "  ")
	return mcpToolResult{
		Content: []mcpToolContent{{Type: "text", Text: string(raw)}},
	}
}

func toolScaffoldApp(dataDir string, rawArgs json.RawMessage) mcpToolResult {
	var args struct {
		ID          string `json:"id"`
		Name        string `json:"name"`
		Description string `json:"description"`
		Category    string `json:"category"`
		Mode        string `json:"mode"`
		Runtime     string `json:"runtime"`
		HasCron     bool   `json:"hasCron"`
		Cron        string `json:"cron"`
	}
	if err := json.Unmarshal(rawArgs, &args); err != nil {
		return mcpToolResult{
			IsError: true,
			Content: []mcpToolContent{{Type: "text", Text: "参数解析失败: " + err.Error()}},
		}
	}
	args.ID = strings.TrimSpace(args.ID)
	args.Name = strings.TrimSpace(args.Name)
	if !ValidPluginID(args.ID) {
		return mcpToolResult{
			IsError: true,
			Content: []mcpToolContent{{Type: "text", Text: "插件 ID 不合法，必须匹配 ^[a-z][a-z0-9-]{0,40}$"}},
		}
	}
	if args.Name == "" {
		return mcpToolResult{
			IsError: true,
			Content: []mcpToolContent{{Type: "text", Text: "插件名称 name 不能为空"}},
		}
	}
	if args.Category == "" {
		args.Category = "utility"
	}
	if args.Mode == "" {
		args.Mode = WebModeOnDemand
	}
	args.Runtime = strings.ToLower(strings.TrimSpace(args.Runtime))
	if args.Runtime == "" {
		if args.Mode == WebModeStatic {
			args.Runtime = "static"
		} else {
			args.Runtime = "python"
		}
	}
	switch args.Runtime {
	case "python", "node", "go", "rust", "java", "shell", "static":
	default:
		return mcpToolResult{
			IsError: true,
			Content: []mcpToolContent{{Type: "text", Text: "不支持的 runtime: " + args.Runtime + "（支持 python | node | go | rust | java | shell | static）"}},
		}
	}
	if (args.Mode == WebModeOnDemand || args.Mode == WebModePersistent) && args.Runtime == "static" {
		return mcpToolResult{
			IsError: true,
			Content: []mcpToolContent{{Type: "text", Text: "动态 Web 模式（on-demand / persistent）不能使用 static 运行时"}},
		}
	}
	if args.Cron == "" {
		args.Cron = "0 * * * *"
	}

	pluginsRoot := filepath.Join(dataDir, "plugins")
	if err := os.MkdirAll(pluginsRoot, 0700); err != nil {
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: err.Error()}}}
	}
	pluginDir := filepath.Join(pluginsRoot, args.ID)
	if _, err := os.Lstat(pluginDir); err == nil || !os.IsNotExist(err) {
		return mcpToolResult{
			IsError: true,
			Content: []mcpToolContent{{
				Type: "text",
				Text: fmt.Sprintf("app_already_exists: 插件 ID %q 已存在（%s），拒绝覆盖已有插件的 plugin.json、env.json 或启动脚本。如需升级或修改已有插件，请先对比文件差异并在保留用户配置与数据目录的前提下增量更新。", args.ID, pluginDir),
			}},
		}
	}
	pluginDataDir := filepath.Join(dataDir, "plugin-data", args.ID)
	if err := os.Mkdir(pluginDir, 0700); err != nil {
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: err.Error()}}}
	}
	if err := os.MkdirAll(pluginDataDir, 0700); err != nil {
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: err.Error()}}}
	}

	manifest := PluginManifest{
		SchemaVersion: 2,
		ID:            args.ID,
		Name:          args.Name,
		Version:       "0.1.0",
		Author:        "Local Developer",
		Description:   args.Description,
		Category:      args.Category,
		Icon:          "icon.svg",
		Access: AccessConfig{
			Policy:         AccessAdminOnly,
			AllowedUserIDs: []int64{},
		},
	}

	createdFiles := []string{"plugin.json", "icon.svg", "env.json"}
	_ = os.WriteFile(filepath.Join(pluginDir, "icon.svg"), []byte(builtInDemoIconSVG), 0600)
	_ = os.WriteFile(filepath.Join(pluginDir, "env.json"), []byte("{}\n"), 0600)

	switch args.Mode {
	case WebModeStatic:
		manifest.Web = &WebConfig{
			Enabled:   true,
			Mode:      WebModeStatic,
			Runtime:   "static",
			StaticDir: "ui",
			BasePath:  "/apps/" + args.ID,
		}
		uiDir := filepath.Join(pluginDir, "ui")
		_ = os.MkdirAll(uiDir, 0700)
		html := fmt.Sprintf("<!doctype html><html><head><meta charset=\"utf-8\"><title>%s</title></head><body><h1>%s</h1></body></html>\n", args.Name, args.Name)
		_ = os.WriteFile(filepath.Join(uiDir, "index.html"), []byte(html), 0600)
		createdFiles = append(createdFiles, "ui/index.html")
		if args.HasCron {
			cronFiles, err := writeCronScaffold(pluginDir, args.ID, args.Runtime)
			if err != nil {
				return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: err.Error()}}}
			}
			createdFiles = append(createdFiles, cronFiles...)
		}
	case WebModeOnDemand, WebModePersistent:
		manifest.Web = &WebConfig{
			Enabled:             true,
			Mode:                args.Mode,
			Runtime:             args.Runtime,
			Entry:               "run-web.sh",
			Port:                0,
			BasePath:            "/apps/" + args.ID,
			IdleTimeoutSeconds:  300,
			ReadyTimeoutSeconds: 15,
			AutoRestart:         args.Mode == WebModePersistent,
			RestartLimit:        5,
		}
		rtFiles, err := writeRuntimeScaffold(pluginDir, args.ID, args.Name, args.Runtime, args.HasCron)
		if err != nil {
			return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: err.Error()}}}
		}
		createdFiles = append(createdFiles, rtFiles...)
	case "cron-only":
		args.HasCron = true
		cronFiles, err := writeCronScaffold(pluginDir, args.ID, args.Runtime)
		if err != nil {
			return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: err.Error()}}}
		}
		createdFiles = append(createdFiles, cronFiles...)
	default:
		return mcpToolResult{
			IsError: true,
			Content: []mcpToolContent{{Type: "text", Text: "不支持的 mode: " + args.Mode}},
		}
	}

	if args.HasCron {
		// P1-3: Newly scaffolded Cron tasks default to Enabled: false so MCP hot-reload
		// never auto-executes background tasks before administrator confirmation/activation.
		manifest.Cron = &CronConfig{
			Enabled:        false,
			Entry:          "run-cron.sh",
			Schedule:       automation.Schedule{Cron: args.Cron, Timezone: "Asia/Shanghai"},
			TimeoutSeconds: 300,
			Notification: automation.Notification{
				Events:   []string{"failure", "timeout"},
				Channels: []string{},
			},
		}
	}

	rawManifest, _ := json.MarshalIndent(manifest, "", "  ")
	if err := os.WriteFile(filepath.Join(pluginDir, "plugin.json"), rawManifest, 0600); err != nil {
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: err.Error()}}}
	}
	_ = markAppPendingInConfig(dataDir, args.ID)

	out, _ := json.MarshalIndent(map[string]any{
		"scaffolded":    true,
		"id":            args.ID,
		"pluginDir":     pluginDir,
		"pluginDataDir": pluginDataDir,
		"createdFiles":  createdFiles,
		"manifest":      manifest,
	}, "", "  ")
	return mcpToolResult{
		Content: []mcpToolContent{{Type: "text", Text: string(out)}},
	}
}

func toolValidateAndReload(ctx context.Context, dataDir string, rawArgs json.RawMessage) mcpToolResult {
	var args struct {
		ID string `json:"id"`
	}
	if len(rawArgs) > 0 {
		_ = json.Unmarshal(rawArgs, &args)
	}
	pluginsDir := filepath.Join(dataDir, "plugins")
	targetID := strings.TrimSpace(args.ID)

	var ids []string
	if targetID != "" {
		if !ValidPluginID(targetID) {
			return mcpToolResult{
				IsError: true,
				Content: []mcpToolContent{{Type: "text", Text: "非法插件 ID: " + targetID}},
			}
		}
		ids = []string{targetID}
	} else {
		entries, err := os.ReadDir(pluginsDir)
		if err != nil {
			return mcpToolResult{
				IsError: true,
				Content: []mcpToolContent{{Type: "text", Text: "无法读取 plugins 目录: " + err.Error()}},
			}
		}
		for _, e := range entries {
			if e.IsDir() && !strings.HasPrefix(e.Name(), ".") {
				ids = append(ids, e.Name())
			}
		}
	}

	validated := make([]string, 0, len(ids))
	for _, id := range ids {
		pluginDir := filepath.Join(pluginsDir, id)
		// Normalize permissions on env.json and entry scripts if needed
		if envPath := filepath.Join(pluginDir, "env.json"); fileExistsRegular(envPath) {
			_ = os.Chmod(envPath, 0600)
		}
		root, err := os.OpenRoot(pluginDir)
		if err != nil {
			return mcpToolResult{
				IsError: true,
				Content: []mcpToolContent{{Type: "text", Text: fmt.Sprintf("插件 %s 目录无法打开: %v", id, err)}},
			}
		}
		raw, _, readErr := readCheckedFile(root, "plugin.json", maxManifestBytes)
		if readErr != nil {
			root.Close()
			return mcpToolResult{
				IsError: true,
				Content: []mcpToolContent{{Type: "text", Text: fmt.Sprintf("插件 %s 缺少有效的 plugin.json", id)}},
			}
		}
		_, valErr := ValidateManifest(root, id, raw)
		root.Close()
		if valErr != nil {
			return mcpToolResult{
				IsError: true,
				Content: []mcpToolContent{{Type: "text", Text: fmt.Sprintf("插件 %s 校验未通过: %v", id, valErr)}},
			}
		}
		_ = markAppPendingInConfig(dataDir, id)
		validated = append(validated, id)
	}

	reloaded := notifyLocalReload(ctx, dataDir)
	out, _ := json.MarshalIndent(map[string]any{
		"valid":     true,
		"validated": validated,
		"reloaded":  reloaded,
	}, "", "  ")
	return mcpToolResult{
		Content: []mcpToolContent{{Type: "text", Text: string(out)}},
	}
}

func fileExistsRegular(path string) bool {
	st, err := os.Lstat(path)
	return err == nil && st.Mode().IsRegular()
}

func notifyLocalReload(ctx context.Context, dataDir string) bool {
	tokenBytes, err := os.ReadFile(filepath.Join(dataDir, ".mcp-reload-token"))
	if err != nil {
		return false
	}
	token := strings.TrimSpace(string(tokenBytes))
	if token == "" {
		return false
	}
	baseURL := strings.TrimRight(os.Getenv("LIGHTISLE_CORE_URL"), "/")
	if baseURL == "" {
		baseURL = "http://127.0.0.1:16666"
	}
	reqCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(reqCtx, http.MethodPost, baseURL+"/api/v2/apps/local-reload", bytes.NewReader([]byte("{}")))
	if err != nil {
		return false
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-LightIsle-Request", "1")
	req.Header.Set("X-LightIsle-MCP-Token", token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}

func readSpecResource(uri string) (string, bool) {
	switch uri {
	case "lightisle://specs/plugin-v2":
		return pluginV2SpecMarkdown, true
	case "lightisle://specs/automation-v1":
		return automationV1SpecMarkdown, true
	default:
		return "", false
	}
}

const pluginV2SpecMarkdown = `# LightIsle Plugin v2 Specification (schemaVersion: 2)

## Directory Layout
- Code & Assets: ` + "`<dataDir>/plugins/<id>/`" + ` (0700)
- Persistent State & SQLite: ` + "`<dataDir>/plugin-data/<id>/`" + ` (0700)
- Manifest: ` + "`plugins/<id>/plugin.json`" + ` (0600)
- Secrets/Env: ` + "`plugins/<id>/env.json`" + ` (0600, string key-value JSON object)

## Web Modes
- ` + "`static`" + `: Zero-RSS static asset hosting from ` + "`staticDir`" + ` (e.g. ` + "`ui`" + `).
- ` + "`on-demand`" + `: Starts ` + "`run-web.sh`" + ` on HTTP request to ` + "`/apps/<id>`" + `, binds ` + "`127.0.0.1:$PORT`" + `, sleeps after ` + "`idleTimeoutSeconds`" + `.
- ` + "`persistent`" + `: Starts automatically with Core and supervises restarts up to ` + "`restartLimit`" + `.

## Injected Environment Variables
- ` + "`PORT`" + `, ` + "`HOST=127.0.0.1`" + `, ` + "`BASE_PATH=/apps/<id>`" + `
- ` + "`LIGHTISLE_PLUGIN_DIR`" + `, ` + "`LIGHTISLE_PLUGIN_DATA_DIR`" + `
- ` + "`LIGHTISLE_PROXY_SECRET`" + ` (verified against ` + "`X-LightIsle-Proxy-Secret`" + ` header)
`

const automationV1SpecMarkdown = `# LightIsle Automation Script v1 Specification (schemaVersion: 1)

## Directory Layout
- Standalone scripts live in ` + "`<dataDir>/automation/scripts/<id>/`" + `
- Manifest: ` + "`task.json`" + ` with ` + "`schemaVersion: 1`" + `, ` + "`entry`" + `, ` + "`schedule.cron`" + ` (5-field), ` + "`schedule.timezone`" + `, and ` + "`notification`" + `.
- Email modes: ` + "`builtin`" + `, ` + "`content`" + `, ` + "`custom`" + `.
`
