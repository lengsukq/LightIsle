package apps

// SpecResources returns the built-in MCP documentation resources exposed by LightIsle.
func SpecResources() []map[string]any {
	return []map[string]any{
		{
			"uri":         "lightisle://specs/mcp-security",
			"name":        "LightIsle Management MCP & Security Guardrails",
			"description": "LightIsle 全功能管理与控制 MCP 使用约定、generation/revision 乐观并发校验、SQLite 审计与高危能力禁令",
			"mimeType":    "text/markdown",
		},
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
	}
}

// ReadSpecResource resolves a built-in LightIsle specification resource by URI.
func ReadSpecResource(uri string) (string, bool) {
	return readSpecResource(uri)
}

func readSpecResource(uri string) (string, bool) {
	switch uri {
	case "lightisle://specs/mcp-security":
		return mcpSecuritySpecMarkdown, true
	case "lightisle://specs/plugin-v2":
		return pluginV2SpecMarkdown, true
	case "lightisle://specs/automation-v1":
		return automationV1SpecMarkdown, true
	case "lightisle://specs/ui-theme":
		return uiThemeSpecMarkdown, true
	default:
		return "", false
	}
}

const mcpSecuritySpecMarkdown = `# LightIsle Management & System MCP Specification

## Overview
LightIsle exposes a unified Model Context Protocol (MCP) server over both local ` + "`stdio`" + ` (` + "`lightisled mcp`" + `) and LAN HTTP/SSE (` + "`/api/v2/mcp`" + `, ` + "`/api/v2/mcp/sse`" + `).

## Preconditions & Concurrency Safety
1. **Storage Root Generation (` + "`generation`" + `)**: Before executing any write tool on a storage root (creating folders, organizing files, moving to trash, restoring trash, scanning photos/cinema), call ` + "`lightisle_list_roots`" + ` to obtain the root's online state and current ` + "`generation`" + `.
2. **Optimistic Revision (` + "`revision`" + `)**: Before modifying automation task schedules (` + "`lightisle_set_automation_schedule`" + `) or app runtime settings (` + "`lightisle_set_app_runtime_settings`" + `), read the current task/app configuration first and pass its ` + "`revision`" + `.

## Auditing & Role Isolation
- Every MCP tool invocation is durably recorded in SQLite ` + "`audit_events`" + ` (` + "`BeginMCPAudit`" + ` -> ` + "`FinishMCPAudit`" + `) and in the live call trace (` + "`mcp-debug-log.json`" + `) with sensitive fields redacted.
- Connections inherit the bound account's role (` + "`admin`" + ` vs ` + "`member`" + `) and write flag (` + "`canWrite`" + `).

## Non-Negotiable High-Risk Exclusions
The following destructive or secret-exfiltrating capabilities are **never** exposed to MCP:
- Disk formatting, partitioning, or erasing.
- Unregistering or detaching storage roots (` + "`DELETE /roots/{id}`" + `).
- Permanent trash purging (` + "`DELETE /files/trash`" + `); file deletions always use ` + "`lightisle_move_to_trash`" + ` so users can recover items via ` + "`lightisle_restore_trashed_file`" + `.
- Arbitrary shell command execution (automation only triggers existing scripts under ` + "`automation/scripts/`" + `).
- Reading plaintext passwords, password hashes, session cookies, or macOS Keychain credentials (SMTP, Bark, WeCom, DingTalk, Cloudflare, FRP).
- Disabling or resetting the password of administrator accounts via MCP.
`

const pluginV2SpecMarkdown = `# LightIsle Plugin v2 Specification (schemaVersion: 2)

## Directory Layout
- Code & Assets: ` + "`<dataDir>/plugins/<id>/`" + ` (0700)
- Persistent State & SQLite: ` + "`<dataDir>/plugin-data/<id>/`" + ` (0700)
- Manifest: ` + "`plugins/<id>/plugin.json`" + ` (0600)
- Secrets/Env: ` + "`plugins/<id>/env.json`" + ` (0600, string key-value JSON object)

## Web Modes
- ` + "`static`" + `: Zero-RSS static asset hosting from ` + "`staticDir`" + ` (e.g. ` + "`ui`" + `).
- ` + "`on-demand`" + `: Starts ` + "`run-web.sh`" + ` on HTTP request to ` + "`/apps/<id>`" + `, binds ` + "`127.0.0.1:$PORT`" + `, sleeps after ` + "`idleTimeoutSeconds`" + `.
- ` + "`persistent`" + `: Starts automatically after administrator approval and supervises restarts up to ` + "`restartLimit`" + `.

## Injected Environment Variables
- ` + "`PORT`" + `, ` + "`HOST=127.0.0.1`" + `, ` + "`BASE_PATH=/apps/<id>`" + `
- ` + "`LIGHTISLE_PLUGIN_DIR`" + `, ` + "`LIGHTISLE_PLUGIN_DATA_DIR`" + `
- ` + "`LIGHTISLE_PROXY_SECRET`" + ` (verified against ` + "`X-LightIsle-Proxy-Secret`" + ` header)

## Built-in Local & LAN MCP Developer Tools
- ` + "`lightisle_get_environment`" + ` / ` + "`lightisle_list_apps`" + `
- ` + "`lightisle_scaffold_app`" + ` / ` + "`lightisle_validate_and_reload`" + `
- ` + "`lightisle_read_plugin_file`" + ` / ` + "`lightisle_write_plugin_file`" + ` (remote/LAN code authoring inside ` + "`plugins/<id>/`" + `)
- ` + "`lightisle_app_action`" + ` / ` + "`lightisle_get_app_logs`" + ` / ` + "`lightisle_probe_app`" + ` (live gateway probe & log debugging)
`

const automationV1SpecMarkdown = `# LightIsle Automation Script v1 Specification (schemaVersion: 1)

## Directory Layout
- Standalone scripts live in ` + "`<dataDir>/automation/scripts/<id>/`" + `
- Manifest: ` + "`task.json`" + ` with ` + "`schemaVersion: 1`" + `, ` + "`entry`" + `, ` + "`schedule.cron`" + ` (5-field), ` + "`schedule.timezone`" + `, and ` + "`notification`" + `.
- Email modes: ` + "`builtin`" + `, ` + "`content`" + `, ` + "`custom`" + `.
`

const uiThemeSpecMarkdown = `# LightIsle UI Theme & Restrained Liquid Glass Specification

## Design Tokens & Adaptive Light/Dark CSS Variables

Mini-apps hosted under ` + "`/apps/<id>/`" + ` should define ` + "`color-scheme: light dark`" + ` and adopt LightIsle's standard CSS custom properties so they blend seamlessly with Web, macOS, and Flutter views:

` + "```css" + `
:root {
  color-scheme: light dark;
  --bg: #f5f5f7;
  --surface: rgba(255, 255, 255, 0.86);
  --surface-solid: #ffffff;
  --text: #1d1d1f;
  --muted: #6e6e73;
  --accent: #0a84ff;
  --border: rgba(0, 0, 0, 0.08);
  --radius-card: 16px;
  --radius-control: 10px;
  --font-sans: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Helvetica Neue", sans-serif;
}

@media (prefers-color-scheme: dark) {
  :root {
    --bg: #121214;
    --surface: rgba(28, 28, 30, 0.82);
    --surface-solid: #1c1c1e;
    --text: #f5f5f7;
    --muted: #98989d;
    --accent: #0a84ff;
    --border: rgba(255, 255, 255, 0.10);
  }
}
` + "```" + `

## Typography & Layout Conventions
- **System Font Stack**: Use ` + "`var(--font-sans)`" + ` with ` + "`font-variant-numeric: tabular-nums`" + ` on counters, latency metrics, and timestamps.
- **Card Radius & Spacing**: Primary cards use ` + "`border-radius: 16px`" + `, ` + "`border: 1px solid var(--border)`" + `, and ` + "`padding: 18px 20px`" + `; compact controls/buttons use ` + "`border-radius: 10px`" + `.
- **Restrained Liquid Glass**: Reserve ` + "`backdrop-filter: saturate(180%) blur(20px)`" + ` strictly for compact navigation headers or floating action bars. Data tables, logs, and dense grids must use opaque ` + "`var(--surface-solid)`" + ` to avoid GPU overdraw.
- **Reduced Transparency Fallback**: Respect ` + "`@media (prefers-reduced-transparency: reduce)`" + ` by disabling ` + "`backdrop-filter`" + ` and falling back to ` + "`var(--surface-solid)`" + `.
`
