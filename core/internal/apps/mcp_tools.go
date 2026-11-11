package apps

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/lengsukq/lightisle/core/internal/automation"
)

func lookupExecutableInSearchPaths(name string, extraDirs ...string) (string, error) {
	if name == "" || strings.ContainsRune(name, '/') || strings.ContainsRune(name, 0) {
		return "", errors.New("invalid executable name")
	}
	dirs := filepath.SplitList(os.Getenv("PATH"))
	dirs = append(dirs, extraDirs...)
	seen := make(map[string]struct{}, len(dirs))
	for _, dir := range dirs {
		dir = strings.TrimSpace(dir)
		if dir == "" {
			continue
		}
		if _, dup := seen[dir]; dup {
			continue
		}
		seen[dir] = struct{}{}
		candidate := filepath.Join(dir, name)
		st, err := os.Stat(candidate)
		if err == nil && !st.IsDir() && st.Mode()&0111 != 0 {
			return candidate, nil
		}
	}
	return "", os.ErrNotExist
}

func persistPendingForMCP(dataDir string, mgr *Manager, appID string) error {
	if mgr != nil {
		return mgr.markAppPending(appID)
	}
	return markAppPendingInConfig(dataDir, appID)
}

func toolGetEnvironment(dataDir, execPath string, mgr *Manager) mcpToolResult {
	extraDirs := []string{"/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"}
	runtimes := map[string]string{}
	for _, bin := range []string{"python3", "uv", "node", "npm", "bun", "deno", "go", "swift", "bash", "sh"} {
		if p, err := lookupExecutableInSearchPaths(bin, extraDirs...); err == nil {
			runtimes[bin] = p
		}
	}
	cfg, _ := readSystemConfigFile(filepath.Join(dataDir, "apps-config.json"))
	if !cfg.MCPEnabled {
		cfg.MCPLanEnabled = false
	}
	payload := map[string]any{
		"dataDir":              dataDir,
		"pluginsDir":           filepath.Join(dataDir, "plugins"),
		"pluginDataDir":        filepath.Join(dataDir, "plugin-data"),
		"automationScriptsDir": filepath.Join(dataDir, "automation", "scripts"),
		"execPath":             execPath,
		"mcpEnabled":           cfg.MCPEnabled,
		"mcpLanEnabled":        cfg.MCPLanEnabled,
		"runtimes":             runtimes,
	}
	if mgr != nil {
		localURL, lanURL := mgr.Endpoints()
		payload["localMcpUrl"] = localURL + "/api/v2/mcp"
		if lanURL != "" {
			payload["lanMcpUrl"] = lanURL + "/api/v2/mcp"
		}
		payload["configuredChannels"] = mgr.ConfiguredChannels()
	}
	raw, _ := json.MarshalIndent(payload, "", "  ")
	return mcpToolResult{
		Content: []mcpToolContent{{Type: "text", Text: string(raw)}},
	}
}

func toolListApps(dataDir string, mgr *Manager) mcpToolResult {
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
		item := map[string]any{
			"id":        manifest.ID,
			"name":      manifest.Name,
			"version":   manifest.Version,
			"category":  manifest.Category,
			"valid":     true,
			"pluginDir": pluginDir,
			"dataDir":   filepath.Join(dataDir, "plugin-data", name),
			"manifest":  manifest,
		}
		if mgr != nil {
			if pub, err := mgr.GetForUser(manifest.ID, 0, "admin"); err == nil {
				item["status"] = pub.Web.Status
				item["pendingActivation"] = pub.PendingActivation
				item["web"] = pub.Web
				item["cron"] = pub.Cron
			}
		}
		items = append(items, item)
	}
	raw, _ := json.MarshalIndent(map[string]any{"apps": items}, "", "  ")
	return mcpToolResult{
		Content: []mcpToolContent{{Type: "text", Text: string(raw)}},
	}
}

func toolScaffoldApp(dataDir string, mgr *Manager, rawArgs json.RawMessage) mcpToolResult {
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
	if _, cfgErr := readSystemConfigFile(filepath.Join(dataDir, "apps-config.json")); cfgErr != nil {
		return mcpToolResult{
			IsError: true,
			Content: []mcpToolContent{{Type: "text", Text: cfgErr.Error()}},
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
	if err := persistPendingForMCP(dataDir, mgr, args.ID); err != nil {
		return mcpToolResult{IsError: true, Content: []mcpToolContent{{Type: "text", Text: err.Error()}}}
	}

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

func toolValidateAndReload(ctx context.Context, dataDir string, mgr *Manager, rawArgs json.RawMessage) mcpToolResult {
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
		if err := persistPendingForMCP(dataDir, mgr, id); err != nil {
			return mcpToolResult{
				IsError: true,
				Content: []mcpToolContent{{Type: "text", Text: err.Error()}},
			}
		}
		validated = append(validated, id)
	}

	var reloaded bool
	if mgr != nil {
		reloaded = mgr.ReloadFromMCP() == nil
	} else {
		reloaded = notifyLocalReload(ctx, dataDir)
	}
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
