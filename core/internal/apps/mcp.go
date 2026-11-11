package apps

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"path/filepath"
	"strings"
	"time"
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
		if len(req.ID) == 0 || string(req.ID) == "null" || strings.HasPrefix(req.Method, "notifications/") {
			continue
		}
		resp := handleMCPRequestWithTrace(ctx, dataDir, execPath, "stdio", "local-stdio", nil, req)
		writeRPC(out, resp)
	}
	return scanner.Err()
}

// ExecuteMCPJSONRPC handles a single JSON-RPC 2.0 request (or notification) over HTTP/SSE/IPC
// and records a call trace entry in mcp-debug-log.json.
func ExecuteMCPJSONRPC(ctx context.Context, dataDir, execPath, transport, remoteAddr string, mgr *Manager, raw []byte) ([]byte, bool) {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 {
		return nil, false
	}
	var req jsonRPCRequest
	if err := json.Unmarshal(trimmed, &req); err != nil {
		resp, _ := json.Marshal(jsonRPCResponse{
			JSONRPC: "2.0",
			ID:      json.RawMessage("null"),
			Error:   &jsonRPCError{Code: -32700, Message: "Parse error"},
		})
		return resp, true
	}
	if len(req.ID) == 0 || string(req.ID) == "null" || strings.HasPrefix(req.Method, "notifications/") {
		return nil, false
	}
	resp := handleMCPRequestWithTrace(ctx, dataDir, execPath, transport, remoteAddr, mgr, req)
	out, err := json.Marshal(resp)
	if err != nil {
		return nil, false
	}
	return out, true
}

func handleMCPRequestWithTrace(ctx context.Context, dataDir, execPath, transport, remoteAddr string, mgr *Manager, req jsonRPCRequest) jsonRPCResponse {
	started := time.Now()
	resp := handleMCPRequest(ctx, dataDir, execPath, mgr, req)
	durationMs := time.Since(started).Milliseconds()

	var target, reqSummary, respPreview string
	isErr := resp.Error != nil
	switch req.Method {
	case "tools/call":
		var p struct {
			Name      string          `json:"name"`
			Arguments json.RawMessage `json:"arguments"`
		}
		if json.Unmarshal(req.Params, &p) == nil {
			target = p.Name
			reqSummary = string(p.Arguments)
		}
	case "resources/read":
		var p struct {
			URI string `json:"uri"`
		}
		if json.Unmarshal(req.Params, &p) == nil {
			target = p.URI
			reqSummary = p.URI
		}
	default:
		target = req.Method
		reqSummary = string(req.Params)
	}
	if resp.Error != nil {
		respPreview = fmt.Sprintf("[%d] %s", resp.Error.Code, resp.Error.Message)
	} else if tr, ok := resp.Result.(mcpToolResult); ok {
		if tr.IsError {
			isErr = true
		}
		if len(tr.Content) > 0 {
			respPreview = tr.Content[0].Text
		}
	} else if rawRes, err := json.Marshal(resp.Result); err == nil {
		respPreview = string(rawRes)
	}
	if req.Method != "ping" {
		RecordMCPCall(dataDir, MCPCallLogEntry{
			Timestamp:       started.UTC().Format(time.RFC3339),
			Transport:       transport,
			RemoteAddr:      remoteAddr,
			Method:          req.Method,
			Target:          target,
			DurationMs:      durationMs,
			IsError:         isErr,
			RequestSummary:  reqSummary,
			ResponsePreview: respPreview,
		})
	}
	return resp
}

func writeRPC(out io.Writer, resp jsonRPCResponse) {
	raw, err := json.Marshal(resp)
	if err != nil {
		return
	}
	_, _ = out.Write(append(raw, '\n'))
}

func isMCPEnabledOnDisk(dataDir string) bool {
	cfg, err := readSystemConfigFile(filepath.Join(dataDir, "apps-config.json"))
	if err != nil {
		return false
	}
	return cfg.MCPEnabled
}

func handleMCPRequest(ctx context.Context, dataDir, execPath string, mgr *Manager, req jsonRPCRequest) jsonRPCResponse {
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
					{
						"uri":         "lightisle://specs/ui-theme",
						"name":        "LightIsle UI Theme & Liquid Glass Specification",
						"description": "LightIsle 轻应用浅深色自适应 CSS 变量、Liquid Glass 材质约束、系统字体栈与卡片圆角规范",
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
		result := executeMCPTool(ctx, dataDir, execPath, mgr, params.Name, params.Arguments)
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
	base := []map[string]any{
		{
			"name":        "lightisle_get_environment",
			"description": "获取本机 LightIsle 插件目录、数据目录、局域网 MCP 状态与已安装语言运行时路径（Python/uv/Node/Go/Swift/Bash）",
			"inputSchema": map[string]any{
				"type":       "object",
				"properties": map[string]any{},
			},
		},
		{
			"name":        "lightisle_list_apps",
			"description": "列出当前已安装的 LightIsle 轻应用与插件清单、实时运行状态及静态校验结果",
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
	return append(base, debugToolDefinitions()...)
}

func executeMCPTool(ctx context.Context, dataDir, execPath string, mgr *Manager, name string, rawArgs json.RawMessage) mcpToolResult {
	switch name {
	case "lightisle_get_environment":
		return toolGetEnvironment(dataDir, execPath, mgr)
	case "lightisle_list_apps":
		return toolListApps(dataDir, mgr)
	case "lightisle_scaffold_app":
		return toolScaffoldApp(dataDir, mgr, rawArgs)
	case "lightisle_validate_and_reload":
		return toolValidateAndReload(ctx, dataDir, mgr, rawArgs)
	case "lightisle_read_plugin_file":
		return toolReadPluginFile(dataDir, rawArgs)
	case "lightisle_write_plugin_file":
		return toolWritePluginFile(dataDir, mgr, rawArgs)
	case "lightisle_app_action":
		return toolAppAction(ctx, dataDir, mgr, rawArgs)
	case "lightisle_get_app_logs":
		return toolGetAppLogs(ctx, dataDir, mgr, rawArgs)
	case "lightisle_probe_app":
		return toolProbeApp(ctx, dataDir, mgr, rawArgs)
	default:
		return mcpToolResult{
			IsError: true,
			Content: []mcpToolContent{{Type: "text", Text: "未知工具: " + name}},
		}
	}
}
