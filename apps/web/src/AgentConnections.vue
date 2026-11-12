<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { Bot, Copy, Plus, RefreshCw, Trash2 } from "lucide-vue-next";
import { apiRequest } from "./apiClient.ts";
import { describeUserFacingError } from "./userFacingError.ts";
import IsleCard from "./IsleCard.vue";
import IsleButton from "./IsleButton.vue";
import IsleBadge from "./IsleBadge.vue";
import IsleBanner from "./IsleBanner.vue";
import IsleEmpty from "./IsleEmpty.vue";

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
  <IsleCard
    class="agent-connections"
    aria-label="Agent 接入"
    title="Agent 接入 (MCP)"
    subtitle="每个连接继承当前账号的目录授权与角色权限（全部调用实时写入操作审计；磁盘格式化、删除存储根与物理粉碎文件已隔离禁止）。令牌有效期 30 天，可随时撤销。"
  >
    <template #icon><Bot :size="18" /></template>
    <template #actions>
      <IsleButton variant="glass" size="sm" :loading="busy" @click="run(load)">
        <template #icon><RefreshCw :size="14" /></template>
        刷新
      </IsleButton>
    </template>

    <div class="agent-body">
      <IsleBanner
        v-if="state && !state.enabled"
        type="info"
        compact
        message="请先让管理员在「应用中心」开启 MCP 服务。"
      />
      <IsleBanner
        v-else-if="state && !state.lanEnabled"
        type="info"
        compact
        message="当前仅允许在运行轻屿的 Mac 本机连接；局域网其他设备需管理员开启局域网 MCP。"
      />

      <form v-if="state?.enabled" class="account-form agent-form" @submit.prevent="create">
        <div class="agent-form-grid">
          <label class="agent-name-field">
            <span>连接名称</span>
            <input
              v-model.trim="label"
              type="text"
              placeholder="例如：Claude Desktop / Cursor / Codex"
              maxlength="60"
              required
              :disabled="busy || !!token"
            />
          </label>
          <label class="agent-toggle-field">
            <span>允许修改配置和执行操作（关闭则为只读）</span>
            <input v-model="canWrite" type="checkbox" :disabled="busy || !!token" />
          </label>
        </div>
        <div class="agent-submit-row">
          <IsleButton type="submit" variant="primary" size="md" :loading="busy" :disabled="busy || !!token || !label">
            <template #icon><Plus :size="15" /></template>
            创建连接令牌
          </IsleButton>
        </div>
      </form>

      <div v-if="config" class="agent-config-card">
        <label class="agent-config-label" for="agent-connection-config">
          接入配置（仅显示这一次，请立即复制到 Agent 的 MCP 配置文件中）
        </label>
        <textarea
          id="agent-connection-config"
          ref="setupText"
          class="agent-config-textarea"
          :value="config"
          rows="6"
          readonly
          spellcheck="false"
        />
        <div class="agent-actions">
          <IsleButton variant="primary" size="sm" @click="copyConfig">
            <template #icon><Copy :size="14" /></template>
            复制接入配置
          </IsleButton>
          <IsleButton variant="glass" size="sm" @click="token = ''">我已保存，关闭</IsleButton>
        </div>
      </div>

      <IsleBanner v-if="error" type="error" compact role="alert" :message="error" />
      <IsleBanner v-if="status" type="success" compact role="status" :message="status" />

      <IsleEmpty
        v-if="state && !state.connections.length && !config"
        compact
        :icon="Bot"
        title="暂无已授权的 Agent 连接"
        description="创建连接令牌后，可在支持 MCP 协议的客户端中安全访问你的空间。"
      />

      <div v-if="state?.connections.length" class="agent-list">
        <div v-for="connection in state.connections" :key="connection.id" class="account-row">
          <div class="agent-conn-meta">
            <div class="agent-conn-title">
              <strong>{{ connection.label }}</strong>
              <IsleBadge :variant="connection.canWrite ? 'warning' : 'neutral'" size="sm">
                {{ connection.canWrite ? "允许操作" : "只读权限" }}
              </IsleBadge>
            </div>
            <small>
              到期日：{{ new Date(connection.expiresAt * 1000).toLocaleDateString() }} · 连接 ID：<code>{{ connection.id.slice(0, 12) }}</code>
            </small>
          </div>
          <IsleButton variant="danger" size="sm" :disabled="busy" @click="revoke(connection)">
            <template #icon><Trash2 :size="14" /></template>
            撤销
          </IsleButton>
        </div>
      </div>
    </div>
  </IsleCard>
</template>

<style scoped>
.agent-body {
  display: flex;
  flex-direction: column;
  gap: 14px;
}
.agent-form {
  padding: 16px;
  border-radius: 16px;
  background: var(--fluid-card-item-fill);
  border: 1px solid var(--fluid-card-border);
  display: flex;
  flex-direction: column;
  gap: 14px;
}
.agent-form-grid {
  display: grid;
  grid-template-columns: minmax(220px, 1.2fr) minmax(240px, 1fr);
  gap: 14px;
  align-items: end;
}
@media (max-width: 720px) {
  .agent-form-grid {
    grid-template-columns: 1fr;
  }
}
.agent-toggle-field {
  min-height: 44px;
  box-sizing: border-box;
}
.agent-submit-row {
  display: flex;
  justify-content: flex-start;
}
.agent-config-card {
  display: flex;
  flex-direction: column;
  gap: 10px;
  padding: 14px 16px;
  border-radius: 14px;
  border: 1px solid color-mix(in srgb, var(--accent-primary) 35%, transparent);
  background: color-mix(in srgb, var(--accent-primary) 7%, transparent);
}
.agent-config-label {
  font-size: 12.5px;
  font-weight: 600;
  color: var(--text-primary);
}
.agent-config-textarea {
  width: 100%;
  box-sizing: border-box;
  padding: 10px 12px;
  border-radius: 10px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-fill);
  color: var(--text-primary);
  resize: vertical;
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
  font-size: 12px;
  line-height: 1.5;
}
.agent-actions {
  display: flex;
  align-items: center;
  gap: 10px;
  flex-wrap: wrap;
}
.agent-list {
  display: flex;
  flex-direction: column;
  gap: 10px;
}
.agent-list .account-row {
  margin: 0;
}
.agent-conn-meta {
  display: flex;
  flex-direction: column;
  gap: 4px;
  min-width: 0;
}
.agent-conn-title {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}
</style>
