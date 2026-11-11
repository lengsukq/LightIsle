<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { apiRequest } from "./apiClient.ts";
import { describeUserFacingError } from "./userFacingError.ts";

interface Connection {
  id: string;
  label: string;
  canWrite: boolean;
  expiresAt: number;
}
interface ConnectionState {
  connections: Connection[];
  enabled: boolean;
  lanEnabled: boolean;
  localUrl: string;
  lanUrl: string;
}

const endpoint = "/api/v2/auth/mcp-connections";
const state = ref<ConnectionState>();
const label = ref("");
const canWrite = ref(false);
const token = ref("");
const busy = ref(false);
const error = ref("");
const status = ref("");
const setupText = ref<HTMLTextAreaElement>();
const config = computed(() => {
  if (!token.value || !state.value) return "";
  const url = state.value.lanEnabled && state.value.lanUrl ? state.value.lanUrl : state.value.localUrl;
  return JSON.stringify({
    mcpServers: {
      "lightisle-management": { type: "http", url, headers: { Authorization: "Bearer " + token.value } },
    },
  }, null, 2);
});

async function load() {
  state.value = await apiRequest<ConnectionState>(endpoint);
}

async function run(action: () => Promise<void>) {
  if (busy.value) return;
  busy.value = true;
  error.value = "";
  status.value = "";
  try {
    await action();
  } catch (e) {
    error.value = describeUserFacingError(e);
  } finally {
    busy.value = false;
  }
}

async function create() {
  await run(async () => {
    const result = await apiRequest<{ connection: Connection; token: string }>(endpoint, {
      method: "POST", json: { label: label.value, canWrite: canWrite.value },
    });
    token.value = result.token;
    if (state.value) state.value.connections.unshift(result.connection);
    label.value = "";
    canWrite.value = false;
  });
}

async function revoke(connection: Connection) {
  await run(async () => {
    await apiRequest(endpoint + "/" + encodeURIComponent(connection.id), { method: "DELETE" });
    token.value = "";
    if (state.value) state.value.connections = state.value.connections.filter(item => item.id !== connection.id);
    status.value = "连接已撤销";
  });
}

async function copyConfig() {
  try {
    if (!navigator.clipboard || !window.isSecureContext) throw new Error("clipboard_unavailable");
    await navigator.clipboard.writeText(config.value);
    status.value = "接入配置已复制";
  } catch {
    setupText.value?.focus();
    setupText.value?.select();
    status.value = "配置已选中，可手动复制";
  }
}

onMounted(() => void run(load));
</script>

<template>
  <section class="account-panel agent-connections" aria-label="Agent 接入">
    <div class="account-heading">
      <h3>Agent 接入</h3>
      <button type="button" class="refresh" :disabled="busy" @click="run(load)">刷新</button>
    </div>
    <p>每个连接继承当前账号的目录授权与角色权限（管理员可管理系统配置与成员配额，全部调用实时写入操作审计；磁盘格式化、删除存储根与物理粉碎文件已隔离禁止）。令牌有效期 30 天，可随时撤销。</p>
    <p v-if="state && !state.enabled" class="footnote">请让管理员在应用中心开启 MCP 服务。</p>
    <p v-else-if="state && !state.lanEnabled" class="footnote">当前只允许在运行轻屿的 Mac 上连接。其他设备需要管理员开启局域网 MCP。</p>
    <form v-if="state?.enabled" class="agent-form" @submit.prevent="create">
      <label>
        <span>连接名称</span>
        <input v-model.trim="label" type="text" placeholder="例如 Codex" maxlength="60" required :disabled="busy || !!token" />
      </label>
      <label class="agent-write">
        <input v-model="canWrite" type="checkbox" :disabled="busy || !!token" />
        <span>允许修改配置和执行操作</span>
      </label>
      <button type="submit" class="account-action" :disabled="busy || !!token || !label">创建连接</button>
    </form>
    <div v-if="config" class="agent-config">
      <label for="agent-connection-config">接入配置仅显示这一次。请将它保存到 Agent 的 MCP 配置中。</label>
      <textarea id="agent-connection-config" ref="setupText" :value="config" rows="6" readonly spellcheck="false" />
      <div class="agent-actions">
        <button type="button" class="account-action" @click="copyConfig">复制接入配置</button>
        <button type="button" class="refresh" @click="token = ''">完成</button>
      </div>
    </div>
    <div v-for="connection in state?.connections" :key="connection.id" class="account-row">
      <div>
        <strong>{{ connection.label }}</strong>
        <small>{{ connection.canWrite ? "允许操作" : "只读" }} · {{ new Date(connection.expiresAt * 1000).toLocaleDateString() }}到期</small>
        <small>连接 ID {{ connection.id.slice(0, 12) }}</small>
      </div>
      <button type="button" class="account-action" :disabled="busy" @click="revoke(connection)">撤销</button>
    </div>
    <p v-if="error" role="alert" class="form-error">{{ error }}</p>
    <p v-if="status" role="status" class="footnote">{{ status }}</p>
  </section>
</template>

<style scoped>
.agent-connections { margin-bottom: 20px; }
.agent-form, .agent-config { display: grid; gap: 10px; margin: 12px 0; }
.agent-form > label:first-child { display: grid; gap: 4px; }
.agent-form > button { justify-self: start; }
.agent-write, .agent-actions { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.agent-config textarea { width: 100%; resize: vertical; font-family: ui-monospace, monospace; }
</style>
