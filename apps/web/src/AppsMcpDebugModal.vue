<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { RefreshCcw, Copy, KeyRound, Play, Trash2, Terminal, Globe } from "lucide-vue-next";
import { createAppsCenterClient } from "./appsCenterApi.ts";
import { describeUserFacingError } from "./userFacingError.ts";
import AppleSelect from "./AppleSelect.vue";
import IsleModal from "./IsleModal.vue";

const props = defineProps<{
  apps: Array<{ id: string; name: string }>;
  mcpEnabled: boolean;
  mcpLanEnabled: boolean;
  mcpToken: string;
  mcpPrompt: string;
  lanMcpPrompt: string;
  mcpConfigJson: string;
  lanHttpUrl: string;
  lanSseUrl: string;
  mcpLogs: Array<Record<string, any>>;
}>();

const emit = defineEmits<{
  (e: "close"): void;
  (e: "updated", payload: Record<string, any>): void;
  (e: "copy", text: string, msg: string): void;
}>();

const apiClient = createAppsCenterClient();
const busy = ref(false);
const errText = ref("");
const infoText = ref("");
const showToken = ref(false);

const debugMode = ref<"tools/call" | "resources/read" | "tools/list" | "resources/list" | "raw">("tools/call");
const selectedTool = ref("lightisle_get_environment");
const selectedUri = ref("lightisle://specs/plugin-v2");
const toolArgsText = ref("{}");
const rawRpcText = ref('{\n  "jsonrpc": "2.0",\n  "id": 1,\n  "method": "tools/list",\n  "params": {}\n}');
const debugResult = ref<{ requestJson: string; responseJson: string; durationMs: number; isError: boolean } | null>(null);

const probeAppId = ref(props.apps[0]?.id || "");
const probeMethod = ref("GET");
const probePath = ref("/");
const probeRole = ref("admin");
const probeResult = ref<Record<string, any> | null>(null);
const localLogs = ref<Array<Record<string, any>>>([...(props.mcpLogs || [])]);

watch(() => props.mcpLogs, list => {
  if (Array.isArray(list)) localLogs.value = [...list];
});
watch(() => props.apps, list => {
  if (!probeAppId.value && list.length > 0) probeAppId.value = list[0].id;
});

const debugModeOptions = [
  { value: "tools/call", label: "调用工具 (tools/call)" },
  { value: "resources/read", label: "读取资源 (resources/read)" },
  { value: "tools/list", label: "列出工具 (tools/list)" },
  { value: "resources/list", label: "列出资源 (resources/list)" },
  { value: "raw", label: "原始 JSON-RPC 2.0" },
];

const toolCatalog: Array<{ id: string; label: string; sample: string }> = [
  // 系统与监控
  { id: "lightisle_get_health", label: "[系统] lightisle_get_health · 服务健康与版本", sample: "{}" },
  { id: "lightisle_get_account", label: "[系统] lightisle_get_account · 当前绑定账号与角色", sample: "{}" },
  { id: "lightisle_get_system", label: "[系统] lightisle_get_system · Mac CPU/内存实时状态", sample: "{}" },
  { id: "lightisle_get_network_info", label: "[系统] lightisle_get_network_info · 本机网络与网关", sample: "{}" },
  { id: "lightisle_get_cache_status", label: "[系统] lightisle_get_cache_status · 缓存占用状态", sample: "{}" },
  { id: "lightisle_clear_cache", label: "[系统] lightisle_clear_cache · 清理缩略图与瓦片缓存", sample: '{\n  "categories": ["all"]\n}' },
  { id: "lightisle_get_audit_history", label: "[审计] lightisle_get_audit_history · 查询操作与 MCP 审计", sample: '{\n  "limit": 20\n}' },
  // 磁盘与存储根
  { id: "lightisle_list_disks", label: "[磁盘] lightisle_list_disks · 物理磁盘与挂载状态", sample: "{}" },
  { id: "lightisle_list_roots", label: "[存储] lightisle_list_roots · 存储根与当前 generation", sample: "{}" },
  { id: "lightisle_get_my_storage", label: "[存储] lightisle_get_my_storage · 当前账号存储与配额", sample: "{}" },
  { id: "lightisle_set_member_disk_quota", label: "[存储] lightisle_set_member_disk_quota · 设置成员配额", sample: '{\n  "userId": 2,\n  "rootId": "main",\n  "generation": 1,\n  "quotaBytes": 10737418240\n}' },
  // 文件与安全回收站
  { id: "lightisle_list_files", label: "[文件] lightisle_list_files · 分页列出目录条目", sample: '{\n  "rootId": "main",\n  "path": ".",\n  "limit": 50\n}' },
  { id: "lightisle_search_files", label: "[文件] lightisle_search_files · 按名称搜索文件", sample: '{\n  "rootId": "main",\n  "query": "report"\n}' },
  { id: "lightisle_create_folder", label: "[文件] lightisle_create_folder · 新建文件夹", sample: '{\n  "rootId": "main",\n  "generation": 1,\n  "path": "AgentWorkspace"\n}' },
  { id: "lightisle_move_to_trash", label: "[文件] lightisle_move_to_trash · 安全移入回收站", sample: '{\n  "rootId": "main",\n  "generation": 1,\n  "path": "AgentWorkspace/old.txt"\n}' },
  { id: "lightisle_list_trash", label: "[文件] lightisle_list_trash · 查看回收站条目", sample: '{\n  "rootId": "main"\n}' },
  { id: "lightisle_restore_trashed_file", label: "[文件] lightisle_restore_trashed_file · 还原回收站条目", sample: '{\n  "rootId": "main",\n  "generation": 1,\n  "entryId": "trash-id"\n}' },
  // 相册与影视
  { id: "lightisle_get_photo_status", label: "[相册] lightisle_get_photo_status · 照片索引状态", sample: '{\n  "rootId": "main"\n}' },
  { id: "lightisle_scan_photos", label: "[相册] lightisle_scan_photos · 触发照片增量扫描", sample: '{\n  "rootId": "main",\n  "generation": 1\n}' },
  { id: "lightisle_get_cinema_status", label: "[影视] lightisle_get_cinema_status · 影视索引状态", sample: '{\n  "rootId": "main"\n}' },
  { id: "lightisle_scan_cinema", label: "[影视] lightisle_scan_cinema · 触发影视增量扫描", sample: '{\n  "rootId": "main",\n  "generation": 1\n}' },
  // 下载中心
  { id: "lightisle_get_download_status", label: "[下载] lightisle_get_download_status · 下载服务状态", sample: "{}" },
  { id: "lightisle_list_downloads", label: "[下载] lightisle_list_downloads · 下载任务列表", sample: "{}" },
  { id: "lightisle_create_download", label: "[下载] lightisle_create_download · 创建下载任务", sample: '{\n  "url": "https://example.com/archive.zip",\n  "destination": "Downloads"\n}' },
  // 家庭成员与权限
  { id: "lightisle_list_members", label: "[成员] lightisle_list_members · 家庭成员列表", sample: "{}" },
  { id: "lightisle_create_member", label: "[成员] lightisle_create_member · 新增家庭成员", sample: '{\n  "username": "family_member",\n  "password": "change-me-123456",\n  "role": "member"\n}' },
  // 本机定时脚本
  { id: "lightisle_list_automation_tasks", label: "[自动化] lightisle_list_automation_tasks · 本机脚本列表", sample: "{}" },
  { id: "lightisle_trigger_automation_task", label: "[自动化] lightisle_trigger_automation_task · 立即运行脚本", sample: '{\n  "taskId": "daily-report"\n}' },
  // 任务与告警
  { id: "lightisle_list_tasks", label: "[任务] lightisle_list_tasks · 后台任务进度", sample: "{}" },
  { id: "lightisle_list_alerts", label: "[告警] lightisle_list_alerts · 活跃系统告警", sample: "{}" },
  // 轻应用与插件开发
  { id: "lightisle_get_environment", label: "[插件] lightisle_get_environment · 读取运行环境", sample: "{}" },
  { id: "lightisle_list_managed_apps", label: "[应用] lightisle_list_managed_apps · 轻应用状态列表", sample: "{}" },
  { id: "lightisle_control_managed_app", label: "[应用] lightisle_control_managed_app · 启停/唤醒/重启", sample: '{\n  "appId": "network-pulse",\n  "action": "restart"\n}' },
  { id: "lightisle_list_apps", label: "[插件] lightisle_list_apps · 插件清单与静态校验", sample: "{}" },
  { id: "lightisle_scaffold_app", label: "[插件] lightisle_scaffold_app · 创建插件脚手架", sample: '{\n  "id": "demo-app",\n  "name": "示例轻应用",\n  "mode": "static"\n}' },
  { id: "lightisle_validate_and_reload", label: "[插件] lightisle_validate_and_reload · 校验并热重载", sample: '{\n  "id": "network-pulse"\n}' },
  { id: "lightisle_read_plugin_file", label: "[插件] lightisle_read_plugin_file · 读取插件文件", sample: '{\n  "id": "network-pulse",\n  "path": "plugin.json"\n}' },
  { id: "lightisle_write_plugin_file", label: "[插件] lightisle_write_plugin_file · 写入插件文件", sample: '{\n  "id": "demo-app",\n  "path": "ui/index.html",\n  "content": "<!doctype html><html><body>Hello LAN MCP</body></html>"\n}' },
  { id: "lightisle_app_action", label: "[插件] lightisle_app_action · 插件动作与执行Cron", sample: '{\n  "id": "network-pulse",\n  "action": "reload"\n}' },
  { id: "lightisle_get_app_logs", label: "[插件] lightisle_get_app_logs · 获取插件日志与状态", sample: '{\n  "id": "network-pulse",\n  "limit": 10\n}' },
  { id: "lightisle_probe_app", label: "[插件] lightisle_probe_app · 发送网关 HTTP 探针", sample: '{\n  "id": "network-pulse",\n  "method": "GET",\n  "path": "/"\n}' },
];

const toolOptions = toolCatalog.map(item => ({ value: item.id, label: item.label }));

const resourceUriOptions = [
  { value: "lightisle://specs/mcp-security", label: "lightisle://specs/mcp-security · 管理与安全审计边界" },
  { value: "lightisle://specs/plugin-v2", label: "lightisle://specs/plugin-v2 · 轻应用开发规范" },
  { value: "lightisle://specs/ui-theme", label: "lightisle://specs/ui-theme · 界面视觉规范" },
  { value: "lightisle://specs/automation-v1", label: "lightisle://specs/automation-v1 · 本机定时脚本规范" },
];

const probeAppOptions = computed(() =>
  props.apps.map(app => ({ value: app.id, label: `${app.name} (${app.id})` }))
);

const probeMethodOptions = [
  { value: "GET", label: "GET" },
  { value: "POST", label: "POST" },
  { value: "HEAD", label: "HEAD" },
];

const probeRoleOptions = [
  { value: "admin", label: "管理员 (admin)" },
  { value: "member", label: "普通成员 (member)" },
];

function onSelectToolChange(nextValue?: string) {
  const targetId = typeof nextValue === "string" ? nextValue : selectedTool.value;
  const found = toolCatalog.find(item => item.id === targetId);
  if (found) toolArgsText.value = found.sample;
}

async function toggleLanMcp() {
  if (busy.value) return;
  busy.value = true; errText.value = ""; infoText.value = "";
  try {
    const next = !props.mcpLanEnabled;
    const res = await apiClient.setMcpConfig({ mcpEnabled: next ? true : props.mcpEnabled, mcpLanEnabled: next });
    emit("updated", res);
    infoText.value = next ? "已开启局域网 MCP (HTTP/SSE) 远程接入。" : "已关闭局域网 MCP 远程接入。";
  } catch (e) { errText.value = "切换局域网 MCP 失败：" + describeUserFacingError(e); }
  finally { busy.value = false; }
}

async function rotateToken() {
  if (busy.value) return;
  busy.value = true; errText.value = ""; infoText.value = "";
  try {
    const res = await apiClient.rotateMcpToken();
    emit("updated", res);
    infoText.value = "已轮换 MCP Bearer Token，请同步更新局域网 Agent 配置。";
  } catch (e) { errText.value = "轮换 Token 失败：" + describeUserFacingError(e); }
  finally { busy.value = false; }
}

async function runDebug() {
  if (busy.value) return;
  busy.value = true; errText.value = "";
  try {
    let parsedArgs: unknown = {};
    if (debugMode.value === "tools/call") {
      try { parsedArgs = JSON.parse(toolArgsText.value || "{}"); }
      catch { errText.value = "工具参数 JSON 格式不合法"; busy.value = false; return; }
    }
    const res = await apiClient.debugMcp({
      method: debugMode.value === "raw" ? "" : debugMode.value,
      tool: debugMode.value === "tools/call" ? selectedTool.value : "",
      uri: debugMode.value === "resources/read" ? selectedUri.value : "",
      args: parsedArgs,
      rawRpc: debugMode.value === "raw" ? rawRpcText.value : "",
    });
    debugResult.value = res;
    if (Array.isArray(res.logs)) localLogs.value = res.logs;
  } catch (e) { errText.value = "MCP 调试请求失败：" + describeUserFacingError(e); }
  finally { busy.value = false; }
}

async function runProbe() {
  if (busy.value || !probeAppId.value) return;
  busy.value = true; errText.value = "";
  try {
    const res = await apiClient.probeApp(probeAppId.value, {
      method: probeMethod.value,
      path: probePath.value,
      role: probeRole.value,
    });
    probeResult.value = res.probe || res;
  } catch (e) { errText.value = "网关探针请求失败：" + describeUserFacingError(e); }
  finally { busy.value = false; }
}

async function refreshLogs() {
  if (busy.value) return;
  busy.value = true;
  try {
    const res = await apiClient.fetchMcpLogs();
    if (Array.isArray(res.logs)) localLogs.value = res.logs;
  } catch (e) { errText.value = "读取调用日志失败：" + describeUserFacingError(e); }
  finally { busy.value = false; }
}

async function clearLogs() {
  if (busy.value) return;
  busy.value = true;
  try {
    await apiClient.clearMcpLogs();
    localLogs.value = [];
  } catch (e) { errText.value = "清空调用日志失败：" + describeUserFacingError(e); }
  finally { busy.value = false; }
}
</script>

<template>
  <IsleModal
    title="MCP 局域网接入与在线调试"
    size="wide"
    @close="emit('close')"
  >
    <template #icon>
      <Terminal :size="18" />
    </template>

    <p v-if="errText" class="apps-error">{{ errText }}</p>
    <p v-if="infoText" class="apps-notice">{{ infoText }}</p>

      <div class="apps-form-section">
        <div class="apps-header">
          <strong><Globe :size="15" /> 局域网 MCP 与 Token 鉴权</strong>
          <div class="mcp-bar-actions">
            <button type="button" class="apps-btn" :class="{ primary: !mcpLanEnabled }" :disabled="busy" @click="toggleLanMcp">
              {{ mcpLanEnabled ? "关闭局域网 MCP" : "开启局域网 MCP" }}
            </button>
            <button type="button" class="apps-btn" @click="emit('copy', lanMcpPrompt, '已复制局域网 MCP 接入提示词')">
              <Copy :size="13" /> 复制局域网接入提示词
            </button>
            <button type="button" class="apps-btn" @click="emit('copy', mcpConfigJson, '已复制 mcpServers JSON 配置')">
              <Copy :size="13" /> 复制 mcpServers JSON
            </button>
          </div>
        </div>
        <small class="apps-hint">
          HTTP：<code>{{ lanHttpUrl || "/api/v2/mcp" }}</code> · SSE：<code>{{ lanSseUrl || "/api/v2/mcp/sse" }}</code>（仅限本机与局域网 IP）
        </small>
        <div v-if="mcpToken" class="mcp-bar-actions">
          <small>Bearer Token：<code>{{ showToken ? mcpToken : mcpToken.slice(0, 6) + "••••••••••••" + mcpToken.slice(-4) }}</code></small>
          <button type="button" class="apps-btn" @click="showToken = !showToken">{{ showToken ? "隐藏" : "显示" }}</button>
          <button type="button" class="apps-btn" @click="emit('copy', mcpToken, '已复制 MCP Bearer Token')"><Copy :size="13" /> 复制 Token</button>
          <button type="button" class="apps-btn" :disabled="busy" @click="rotateToken"><KeyRound :size="13" /> 轮换 Token</button>
        </div>
      </div>

      <div class="apps-form-section">
        <strong>MCP 交互式调试器</strong>
        <div class="apps-inputs">
          <label>请求方式
            <AppleSelect v-model="debugMode" block :options="debugModeOptions" />
          </label>
          <label v-if="debugMode === 'tools/call'">选择 MCP 工具
            <AppleSelect v-model="selectedTool" block :options="toolOptions" @change="onSelectToolChange" />
          </label>
          <label v-if="debugMode === 'resources/read'">选择资源 URI
            <AppleSelect v-model="selectedUri" block :options="resourceUriOptions" />
          </label>
        </div>
        <label v-if="debugMode === 'tools/call'" class="apps-hint">工具参数 JSON
          <textarea v-model="toolArgsText" rows="3" class="mcp-code-textarea" />
        </label>
        <label v-if="debugMode === 'raw'" class="apps-hint">原始 JSON-RPC 2.0 请求
          <textarea v-model="rawRpcText" rows="4" class="mcp-code-textarea" />
        </label>
        <div class="mcp-bar-actions">
          <button type="button" class="apps-btn primary" :disabled="busy" @click="runDebug">
            <Play :size="13" /> 发送 MCP 调试请求
          </button>
          <span v-if="debugResult" class="apps-badge" :class="debugResult.isError ? 'muted' : 'online'">
            {{ debugResult.isError ? "执行异常" : "执行成功" }} · {{ debugResult.durationMs }} ms
          </span>
        </div>
        <pre v-if="debugResult" class="apps-log-pre">{{ debugResult.responseJson }}</pre>
      </div>

      <div class="apps-form-section">
        <strong>轻应用网关 HTTP 探针</strong>
        <div class="apps-inputs">
          <label>目标应用
            <AppleSelect v-model="probeAppId" block :options="probeAppOptions" placeholder="暂无可用轻应用" />
          </label>
          <label>HTTP 方法
            <AppleSelect v-model="probeMethod" block :options="probeMethodOptions" />
          </label>
          <label>子路径<input v-model.trim="probePath" placeholder="/" /></label>
          <label>模拟身份
            <AppleSelect v-model="probeRole" block :options="probeRoleOptions" />
          </label>
        </div>
        <div class="mcp-bar-actions">
          <button type="button" class="apps-btn primary" :disabled="busy || !probeAppId" @click="runProbe">
            <Play :size="13" /> 发送网关探针
          </button>
          <span v-if="probeResult" class="apps-badge" :class="probeResult.statusCode < 400 ? 'online' : 'muted'">
            HTTP {{ probeResult.statusCode }} · {{ probeResult.durationMs }} ms · {{ probeResult.status }}
          </span>
        </div>
        <pre v-if="probeResult" class="apps-log-pre">{{ probeResult.bodyPreview || "（响应体为空）" }}</pre>
      </div>

      <div class="apps-form-section">
        <div class="apps-header">
          <strong>MCP 调用追踪日志（最近 {{ localLogs.length }} 条）</strong>
          <div class="mcp-bar-actions">
            <button type="button" class="apps-btn" :disabled="busy" @click="refreshLogs"><RefreshCcw :size="13" /> 刷新</button>
            <button type="button" class="apps-btn danger" :disabled="busy || localLogs.length === 0" @click="clearLogs"><Trash2 :size="13" /> 清空</button>
          </div>
        </div>
        <p v-if="localLogs.length === 0" class="apps-hint">暂无 MCP 调用记录。</p>
        <div v-else class="mcp-trace-list">
          <div v-for="entry in localLogs.slice(0, 15)" :key="entry.id" class="mcp-trace-row">
            <span><code>[{{ entry.transport }}]</code> <strong>{{ entry.method }}</strong> {{ entry.target || "" }}</span>
            <small>{{ entry.remoteAddr || "local" }} · {{ entry.durationMs }} ms · {{ entry.timestamp }}</small>
          </div>
        </div>
      </div>
  </IsleModal>
</template>

<style scoped>
.mcp-code-textarea { width: 100%; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; padding: 8px; border-radius: 9px; border: 1px solid var(--fluid-card-border, var(--stroke-subtle)); background: var(--fluid-card-fill, var(--surface-elevated)); color: inherit; }
.mcp-trace-list { display: grid; gap: 6px; max-height: 180px; overflow-y: auto; }
.mcp-trace-row { display: flex; justify-content: space-between; gap: 10px; flex-wrap: wrap; font-size: 12px; padding: 6px 10px; border-radius: 8px; background: rgba(15, 23, 42, 0.08); }
</style>
