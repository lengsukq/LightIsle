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
  { id: "lightisle_get_environment", label: "lightisle_get_environment · 读取运行环境", sample: "{}" },
  { id: "lightisle_list_apps", label: "lightisle_list_apps · 列出已安装插件", sample: "{}" },
  { id: "lightisle_scaffold_app", label: "lightisle_scaffold_app · 创建插件脚手架", sample: '{\n  "id": "demo-app",\n  "name": "示例轻应用",\n  "mode": "static"\n}' },
  { id: "lightisle_validate_and_reload", label: "lightisle_validate_and_reload · 校验并热重载", sample: '{\n  "id": "network-pulse"\n}' },
  { id: "lightisle_read_plugin_file", label: "lightisle_read_plugin_file · 读取插件文件", sample: '{\n  "id": "network-pulse",\n  "path": "plugin.json"\n}' },
  { id: "lightisle_write_plugin_file", label: "lightisle_write_plugin_file · 写入插件文件", sample: '{\n  "id": "demo-app",\n  "path": "ui/index.html",\n  "content": "<!doctype html><html><body>Hello LAN MCP</body></html>"\n}' },
  { id: "lightisle_app_action", label: "lightisle_app_action · 启停/唤醒/执行Cron", sample: '{\n  "id": "network-pulse",\n  "action": "reload"\n}' },
  { id: "lightisle_get_app_logs", label: "lightisle_get_app_logs · 获取插件日志与状态", sample: '{\n  "id": "network-pulse",\n  "limit": 10\n}' },
  { id: "lightisle_probe_app", label: "lightisle_probe_app · 发送网关 HTTP 探针", sample: '{\n  "id": "network-pulse",\n  "method": "GET",\n  "path": "/"\n}' },
];

const toolOptions = toolCatalog.map(item => ({ value: item.id, label: item.label }));

const resourceUriOptions = [
  { value: "lightisle://specs/plugin-v2", label: "lightisle://specs/plugin-v2" },
  { value: "lightisle://specs/ui-theme", label: "lightisle://specs/ui-theme" },
  { value: "lightisle://specs/automation-v1", label: "lightisle://specs/automation-v1" },
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
