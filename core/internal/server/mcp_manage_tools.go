package server

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/lengsukq/lightisle/core/internal/apps"
)

type mcpTool struct {
	name, description string
	method, route     string
	admin             bool
	write             bool
	directPlugin      bool
	rawDef            map[string]any
	params            []mcpParam
	response          string
}

type mcpParam struct {
	name, kind, destination string
	required                bool
	options                 []string
}

const (
	mcpDestQuery            = "$query"
	mcpDestPath             = "$path"
	mcpDestGenerationHeader = "$generation_header"
)

func mcpQuery(name, kind string) mcpParam {
	return mcpParam{name: name, kind: kind, destination: mcpDestQuery}
}

func mcpPath(name, kind string, options ...string) mcpParam {
	return mcpParam{name: name, kind: kind, destination: mcpDestPath, required: true, options: options}
}

func mcpField(name, kind, field string, required bool, options ...string) mcpParam {
	return mcpParam{name: name, kind: kind, destination: field, required: required, options: options}
}

func mcpRead(name, description, route string, admin bool, params ...mcpParam) mcpTool {
	return mcpTool{name: "lightisle_" + name, description: description, method: http.MethodGet, route: route, admin: admin, params: params}
}

func mcpWrite(name, description, method, route string, admin bool, params ...mcpParam) mcpTool {
	return mcpTool{name: "lightisle_" + name, description: description, method: method, route: route, admin: admin, write: true, params: params}
}

func (tool mcpTool) isWrite() bool {
	if tool.directPlugin {
		return tool.write
	}
	return tool.method != http.MethodGet
}

func (tool mcpTool) definition() map[string]any {
	if tool.rawDef != nil {
		cloned := map[string]any{
			"name":        tool.name,
			"description": tool.description,
			"inputSchema": tool.rawDef["inputSchema"],
			"annotations": map[string]any{"readOnlyHint": !tool.isWrite(), "openWorldHint": false},
		}
		return cloned
	}
	properties := map[string]any{}
	required := []string{}
	for _, p := range tool.params {
		property := map[string]any{"type": p.kind}
		if p.kind == "string" {
			property["maxLength"] = 2048
		}
		if p.kind == "integer" {
			property["minimum"] = 0
		}
		if p.kind == "array" {
			property["items"] = map[string]any{"type": "string"}
			property["maxItems"] = 16
		}
		if len(p.options) > 0 {
			property["enum"] = p.options
		}
		properties[p.name] = property
		if p.required {
			required = append(required, p.name)
		}
	}
	return map[string]any{
		"name": tool.name, "description": tool.description,
		"inputSchema": map[string]any{"type": "object", "properties": properties, "required": required, "additionalProperties": false},
		"annotations": map[string]any{"readOnlyHint": !tool.isWrite(), "openWorldHint": false},
	}
}

func mcpPluginDeveloperTools() []mcpTool {
	readOnlySet := map[string]bool{
		"lightisle_get_environment":  true,
		"lightisle_list_apps":        true,
		"lightisle_read_plugin_file": true,
		"lightisle_get_app_logs":     true,
	}
	defs := apps.PluginMCPToolDefinitions()
	out := make([]mcpTool, 0, len(defs))
	for _, raw := range defs {
		name, _ := raw["name"].(string)
		desc, _ := raw["description"].(string)
		if name == "" {
			continue
		}
		out = append(out, mcpTool{
			name:         name,
			description:  desc,
			admin:        true,
			write:        !readOnlySet[name],
			directPlugin: true,
			rawDef:       raw,
		})
	}
	return out
}

func mcpManagementTools() []mcpTool {
	const root = "/roots/{rootId}"
	rootID := mcpPath("rootId", "string")
	generation := mcpParam{name: "generation", kind: "integer", destination: mcpDestGenerationHeader, required: true}
	id := mcpPath("id", "integer")
	userID := mcpPath("userId", "integer")
	appID := mcpPath("appId", "string")
	taskID := mcpPath("taskId", "string")
	taskKind := mcpPath("kind", "string", "gallery", "cinema")
	limit := mcpQuery("limit", "integer")
	cursor := mcpQuery("cursor", "string")
	before := mcpQuery("before", "integer")
	path := mcpQuery("path", "string")
	requiredPath := path
	requiredPath.required = true

	fileText := mcpRead("read_file_text", "读取有权限的 UTF-8 文本文件，最多 64 KiB", root+"/files/content", false, rootID, requiredPath)
	fileText.response = "text"

	downloads := mcpRead("list_downloads", "查看当前账号的下载任务与发布状态", "/downloads", false)
	downloads.response = "download"
	downloadCreate := mcpWrite("create_download", "创建新的 HTTP/HTTPS/FTP 或磁力下载任务（落盘至默认存储根有写权限的目录）", http.MethodPost, "/downloads", true,
		mcpField("url", "string", "url", true),
		mcpField("destination", "string", "destination", true),
		mcpField("maxBytes", "integer", "maxBytes", false))
	downloadCreate.response = "download"
	downloadControl := mcpWrite("control_download", "暂停或恢复当前账号已有的下载任务", http.MethodPost, "/downloads/{taskId}/actions", false,
		taskID, mcpField("action", "string", "action", true, "pause", "resume"))
	downloadControl.response = "download"
	downloadCancel := mcpWrite("cancel_download", "取消并移除当前账号指定的下载任务", http.MethodDelete, "/downloads/{taskId}", false, taskID)
	downloadCancel.response = "download"

	automationRuns := mcpRead("get_automation_runs", "查看本机脚本的执行状态和通知送达状态", "/automation/tasks/{taskId}/runs", true, taskID)
	automationRuns.response = "automation"

	appList := mcpRead("list_managed_apps", "查看当前账号可见的轻应用及其运行状态", "/apps", false)
	appDetail := mcpRead("get_managed_app", "查看有权限的轻应用配置、状态和 revision", "/apps/{appId}", false, appID)
	appControl := mcpWrite("control_managed_app", "控制已获批准轻应用的运行生命周期（start/wake/stop/restart；首次激活仅限管理界面手动批准）", http.MethodPost, "/apps/{appId}/action", true,
		appID, mcpField("action", "string", "action", true, "start", "wake", "stop", "restart"))
	appSettings := mcpWrite("set_app_runtime_settings", "修改已获批准轻应用的空闲超时或自动重启；先读取应用 revision", http.MethodPatch, "/apps/{appId}", true,
		appID, mcpField("revision", "string", "revision", true),
		mcpField("idleTimeoutSeconds", "integer", "web.idleTimeoutSeconds", false),
		mcpField("autoRestart", "boolean", "web.autoRestart", false))
	appList.response, appDetail.response, appControl.response, appSettings.response = "apps", "apps", "apps", "apps"

	tools := []mcpTool{
		// 1. System, Health & Cache
		mcpRead("get_health", "查看 LightIsle 服务状态、平台和版本", "/health", false),
		mcpRead("get_account", "查看当前 Agent 绑定的 LightIsle 账号及权限角色", "/auth/me", false),
		mcpRead("get_system", "查看 Mac 的实时 CPU、内存用量、系统负载与运行时间", "/system", true),
		mcpRead("get_system_history", "查看系统 CPU 与内存运行指标历史", "/system/history", true, limit),
		mcpRead("get_network_info", "查看 Mac 的本地网络接口和默认网关", "/system/diagnostics", true),
		mcpRead("get_smb_status", "查看 macOS 原生文件共享（SMB）和共享点状态", "/admin/smb", true),
		mcpRead("get_cache_status", "查看缩略图与地图瓦片缓存占用状态", "/cache/status", false),
		mcpWrite("clear_cache", "清理缩略图与地图瓦片临时缓存（可按 categories 指定 thumbnails / map_tiles / all）", http.MethodPost, "/admin/cache/clear", true,
			mcpField("categories", "array", "categories", false)),
		mcpRead("get_map_status", "检查地图服务是否配置", "/map/status", false),
		mcpRead("get_audit_history", "查看管理员操作审计和 MCP 调用历史记录", "/audit", true, limit, before),

		// 2. Disks & Storage Roots (High-risk format & root deletion strictly excluded)
		mcpRead("list_disks", "查看物理磁盘、挂载卷状态及健康摘要", "/admin/disks", true),
		mcpRead("get_disk_smart", "查看指定磁盘的详细 SMART 健康参数", "/admin/disks/{id}/smart", true, mcpPath("id", "string")),
		mcpRead("list_roots", "列出当前账号可见的硬盘根目录、在线状态和代际；根目录写操作需要当前 generation", "/roots", false),
		mcpRead("get_my_storage", "查看自己的存储目录分配、各盘配额和已计费用量", "/me/storage", false),
		mcpRead("get_member_storage", "查看指定家庭成员的存储配置与各盘配额", "/users/{userId}/storage", true, userID),
		mcpWrite("set_member_disk_quota", "修改成员在指定硬盘代际上的存储额度（字节）", http.MethodPut, "/users/{userId}/storage/roots/{rootId}/quota", true,
			userID, rootID, mcpField("generation", "integer", "generation", true), mcpField("quotaBytes", "integer", "quotaBytes", true)),

		// 3. Files & Safe Trash (Permanent trash purge strictly excluded)
		mcpRead("list_files", "按硬盘列出有权限的文件与目录；使用 nextCursor 分页", root+"/files", false, rootID, path, cursor, limit),
		mcpRead("search_files", "按名称关键字搜索指定硬盘上有权限的文件", root+"/files/search", false,
			rootID, mcpParam{name: "query", kind: "string", destination: mcpDestQuery, required: true}, path, limit),
		fileText,
		mcpWrite("create_folder", "在有写权限的硬盘目录中创建文件夹", http.MethodPost, root+"/files/folders", false,
			rootID, generation, mcpField("path", "string", "path", true)),
		mcpWrite("organize_file", "移动、重命名或复制有权限的文件；同名时可跳过（skip）或自动改名（rename）", http.MethodPost, root+"/files/operations", false,
			rootID, generation, mcpField("action", "string", "action", true, "move", "copy"),
			mcpField("from", "string", "from", true), mcpField("to", "string", "to", true),
			mcpField("conflict", "string", "conflict", true, "skip", "rename")),
		mcpWrite("move_to_trash", "安全删除：将指定路径的文件或目录移入 LightIsle 回收站（支持随时还原，不执行物理粉碎）", http.MethodDelete, root+"/files", false,
			rootID, generation, requiredPath),
		mcpRead("list_trash", "查看有权限的 LightIsle 回收站暂存条目", root+"/files/trash", false, rootID),
		mcpWrite("restore_trashed_file", "将 LightIsle 回收站中的条目完整还原至原位置", http.MethodPost, root+"/files/trash/{entryId}/restore", false,
			rootID, generation, mcpPath("entryId", "string")),
		mcpRead("get_trash_retention", "查看回收站保留天数策略", "/trash/retention", false),
		mcpRead("get_computer_files_status", "查看本机电脑文件入口是否可用及当前权限", "/computer-files/status", false),
		mcpRead("list_computer_files", "列出电脑文件入口下当前账号可访问的条目", "/computer-files", false, path),

		// 4. Photos & Cinema
		mcpRead("get_photo_status", "查看指定硬盘的照片索引扫描状态", root+"/photos/status", false, rootID),
		mcpRead("list_photos", "分页查看可见的照片元数据，可按目录或相册筛选", root+"/photos", false,
			rootID, cursor, limit, mcpQuery("directory", "string"), mcpQuery("album", "integer"), mcpQuery("privateAlbum", "integer")),
		mcpRead("list_albums", "查看指定硬盘的公共相册", root+"/photos/albums", false, rootID),
		mcpRead("list_private_albums", "查看当前账号的私人相册", root+"/photos/private-albums", false, rootID),
		mcpRead("list_folder_albums", "查看当前账号可见的文件夹相册", root+"/photos/folder-albums", false, rootID),
		mcpWrite("create_private_album", "创建自己的私人相册", http.MethodPost, root+"/photos/private-albums", false,
			rootID, generation, mcpField("name", "string", "name", true)),
		mcpWrite("rename_private_album", "重命名自己的私人相册", http.MethodPatch, root+"/photos/private-albums/{id}", false,
			rootID, generation, id, mcpField("name", "string", "name", true)),
		mcpWrite("scan_photos", "手动启动指定硬盘的照片目录增量索引扫描", http.MethodPost, root+"/photos/scan", true, rootID, generation),
		mcpRead("get_cinema_status", "查看指定硬盘的影视索引状态", root+"/cinema/status", false, rootID),
		mcpRead("list_cinema", "分页搜索当前账号可见的电影与视频条目", root+"/cinema", false, rootID,
			cursor, limit, mcpQuery("query", "string"), mcpQuery("kind", "string"), mcpQuery("dir", "string")),
		mcpRead("get_film", "查看可见影片的详细媒体信息", root+"/cinema/{id}", false, rootID, id),
		mcpRead("list_series", "查看可见剧集，可按名称搜索", root+"/series", false, rootID, cursor, limit, mcpQuery("query", "string")),
		mcpRead("get_series", "查看可见剧集的分季与单集信息", root+"/series/{id}", false, rootID, id),
		mcpWrite("rename_film", "编辑指定影片的显示标题", http.MethodPatch, root+"/cinema/{id}", true,
			rootID, generation, id, mcpField("title", "string", "title", true)),
		mcpWrite("scan_cinema", "手动启动指定硬盘的影视目录增量索引扫描", http.MethodPost, root+"/cinema/scan", true, rootID, generation),

		// 5. Download Center
		mcpRead("get_download_status", "查看 aria2 下载服务可用性与网络下载权限", "/downloads/status", false),
		downloads,
		downloadCreate,
		downloadControl,
		downloadCancel,

		// 6. Family Members & Grants (Admin account disable/password-reset blocked by core)
		mcpRead("list_members", "查看家庭成员的角色和启用状态", "/users", true),
		mcpWrite("create_member", "添加新的家庭成员账号（密码最少 12 位）", http.MethodPost, "/users", true,
			mcpField("username", "string", "username", true),
			mcpField("password", "string", "password", true),
			mcpField("role", "string", "role", false, "member", "admin")),
		mcpWrite("update_member", "启用或停用普通家庭成员账号（禁止停用管理员账号）", http.MethodPatch, "/users/{userId}", true,
			userID, mcpField("enabled", "boolean", "enabled", true)),
		mcpWrite("set_member_password", "为普通家庭成员重置登录密码并吊销旧会话（禁止重置管理员密码）", http.MethodPost, "/users/{userId}/password", true,
			userID, mcpField("password", "string", "password", true)),
		mcpRead("get_member_file_grants", "查看成员在指定硬盘上的共享目录授权", root+"/users/{userId}/file-grants", true, rootID, userID),
		mcpWrite("set_member_file_grant", "为成员授予或更新指定硬盘共享目录的读写权限", http.MethodPut, root+"/users/{userId}/file-grants", true,
			rootID, generation, userID,
			mcpField("path", "string", "path", true),
			mcpField("canWrite", "boolean", "canWrite", true)),
		mcpWrite("revoke_member_file_grant", "移除成员在指定硬盘共享目录上的访问授权", http.MethodDelete, root+"/users/{userId}/file-grants", true,
			rootID, generation, userID, requiredPath),
		mcpRead("get_computer_file_grants", "查看成员的本机电脑文件授权", "/computer-files/grants/{userId}", true, userID),

		// 7. Local Automation Scripts (Arbitrary shell execution & email template overwrite strictly excluded)
		mcpRead("list_automation_tasks", "查看已安装的本机脚本、启停、Cron、通知设置和 revision", "/automation/tasks", true),
		mcpRead("get_notification_channels", "查看已配置的通知渠道名称（不回显任何密钥凭据）", "/automation/channels", true),
		automationRuns,
		mcpWrite("set_automation_schedule", "更新已安装本机脚本的启停、Cron、时区和通知事件；先读取任务 revision 及现有设置", http.MethodPut, "/automation/tasks/{taskId}", true,
			taskID, mcpField("revision", "string", "revision", true), mcpField("enabled", "boolean", "enabled", true),
			mcpField("cron", "string", "schedule.cron", true), mcpField("timezone", "string", "schedule.timezone", true),
			mcpField("events", "array", "notification.events", true), mcpField("channels", "array", "notification.channels", true)),
		mcpWrite("trigger_automation_task", "立即在后台触发执行一次已安装的本机自动化脚本", http.MethodPost, "/automation/tasks/{taskId}/run", true, taskID),
		mcpWrite("refresh_automation_tasks", "重新扫描并加载本机 automation/scripts 目录下的脚本清单", http.MethodPost, "/automation/refresh", true),

		// 8. Light Apps & Plugin Lifecycle
		appList,
		appDetail,
		appControl,
		appSettings,
		mcpWrite("trigger_app_cron", "立即触发已获批准轻应用附带的定时脚本执行", http.MethodPost, "/apps/{appId}/cron/run", true, appID),

		// 9. Background Tasks, Alerts & Upload Retention
		mcpRead("list_tasks", "查看 Core 后台运行中任务和当前进度", "/tasks", true),
		mcpRead("get_task_history", "查看 Core 后台任务历史记录", "/tasks/history", true, limit, before, mcpQuery("kind", "string")),
		mcpWrite("retry_task", "重试指定存储根的媒体索引后台任务（gallery 或 cinema）", http.MethodPost, root+"/tasks/{kind}/retry", true,
			rootID, generation, taskKind),
		mcpWrite("cancel_task", "取消指定存储根正在运行的媒体索引后台任务（gallery 或 cinema）", http.MethodPost, root+"/tasks/{kind}/cancel", true,
			rootID, generation, taskKind),
		mcpRead("list_alerts", "查看活跃的管理员系统告警", "/alerts", true),
		mcpWrite("acknowledge_alert", "确认并消除指定的管理员告警", http.MethodPost, "/alerts/{code}/acknowledge", true, mcpPath("code", "string")),
		mcpRead("get_upload_retention", "查看未完成上传会话的保留清理天数", "/admin/cleanup-rules", true),
		mcpWrite("set_upload_retention", "修改未完成上传会话的保留清理天数", http.MethodPut, "/admin/cleanup-rules", true,
			mcpField("uploadRetentionDays", "integer", "uploadRetentionDays", true)),
	}
	return append(tools, mcpPluginDeveloperTools()...)
}

// Body fields are fixed by each tool. Dotted names describe one level of
// nesting in an existing API payload.
func setMCPBodyField(body map[string]any, field string, value any) {
	parent, key, nested := strings.Cut(field, ".")
	if !nested {
		body[field] = value
		return
	}
	fields, ok := body[parent].(map[string]any)
	if !ok {
		fields = map[string]any{}
		body[parent] = fields
	}
	fields[key] = value
}

func decodeMCPArgument(raw json.RawMessage, p mcpParam) (any, bool) {
	if string(raw) == "null" {
		return nil, false
	}
	switch p.kind {
	case "integer":
		var n int64
		return n, json.Unmarshal(raw, &n) == nil && n >= 0
	case "boolean":
		var b bool
		return b, json.Unmarshal(raw, &b) == nil
	case "array":
		var values []string
		err := json.Unmarshal(raw, &values)
		for _, item := range values {
			if item == "" || len(item) > 64 {
				return nil, false
			}
		}
		return values, err == nil && len(values) <= 16
	default:
		var s string
		if json.Unmarshal(raw, &s) != nil || len(s) > 2048 || (p.required && strings.TrimSpace(s) == "") {
			return nil, false
		}
		for _, allowed := range p.options {
			if s == allowed {
				return s, true
			}
		}
		return s, len(p.options) == 0
	}
}
