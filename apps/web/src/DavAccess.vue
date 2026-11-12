<script setup lang="ts">
import { onMounted, ref } from "vue";
import { FolderSync, Plus, Copy, Trash2, KeyRound, RefreshCw, HardDrive, ShieldCheck } from "lucide-vue-next";
import { requestConfirm } from "./useConfirmDialog.ts";
import { describeUserFacingError } from "./userFacingError.ts";
import { apiRequest } from "./apiClient.ts";
import IsleCard from "./IsleCard.vue";
import IsleButton from "./IsleButton.vue";
import IsleBadge from "./IsleBadge.vue";
import IsleBanner from "./IsleBanner.vue";
import IsleEmpty from "./IsleEmpty.vue";

defineProps<{ admin?: boolean }>();
type Credential = { id: number; label: string; createdAt: number; lastUsedAt: number };
type MountRoot = { rootID: string; generation: number; name: string; online: boolean };

const credentials = ref<Credential[]>([]);
const roots = ref<MountRoot[]>([]);
const mountError = ref("");
const loading = ref(false);
const busy = ref(false);
const error = ref("");
const label = ref("");
const freshPassword = ref("");
const freshCopied = ref(false);

function mountUrl(root: MountRoot) {
  return `${location.origin}/dav-roots/${encodeURIComponent(root.rootID)}/${root.generation}/`;
}

async function refreshMounts() {
  mountError.value = "";
  try {
    const result = await apiRequest<{ roots?: MountRoot[] }>("/api/v2/roots");
    roots.value = (result.roots ?? []).filter(
      (root) =>
        /^[a-f0-9]{32}$/.test(root.rootID) &&
        Number.isSafeInteger(root.generation) &&
        root.generation > 0,
    );
  } catch (cause) {
    mountError.value = describeUserFacingError(cause);
  }
}

async function refresh() {
  if (loading.value) return;
  loading.value = true;
  error.value = "";
  try {
    const mounts = refreshMounts();
    const value = await apiRequest<{ credentials?: Credential[] }>("/api/v2/dav/credentials");
    credentials.value = value.credentials ?? [];
    await mounts;
  } catch (e) {
    error.value = describeUserFacingError(e);
  } finally {
    loading.value = false;
  }
}

async function create() {
  if (busy.value) return;
  busy.value = true;
  error.value = "";
  freshPassword.value = "";
  freshCopied.value = false;
  try {
    const value = await apiRequest<{ credential?: Credential; password?: string }>(
      "/api/v2/dav/credentials",
      {
        method: "POST",
        json: { label: label.value.trim() || "未命名" },
      },
    );
    label.value = "";
    if (value.password) freshPassword.value = value.password;
    await refresh();
  } catch (e) {
    error.value = describeUserFacingError(e);
  } finally {
    busy.value = false;
  }
}

async function rotate(item: Credential) {
  if (busy.value) return;
  if (
    !(await requestConfirm({
      title: "重新生成 WebDAV 密码",
      message: `确认重新生成「${item.label}」的密码？旧密码会立即失效，已挂载的客户端需使用新密码重新连接。`,
      confirmText: "重新生成",
    }))
  )
    return;
  busy.value = true;
  error.value = "";
  freshPassword.value = "";
  freshCopied.value = false;
  try {
    const value = await apiRequest<{ password?: string }>(
      "/api/v2/dav/credentials/" + encodeURIComponent(String(item.id)) + "/rotate",
      { method: "POST" },
    );
    if (value.password) freshPassword.value = value.password;
    await refresh();
  } catch (e) {
    error.value = describeUserFacingError(e);
  } finally {
    busy.value = false;
  }
}

async function revoke(item: Credential) {
  if (busy.value) return;
  if (
    !(await requestConfirm({
      title: "撤销 WebDAV 密码",
      message: `确认撤销 WebDAV 密码「${item.label}」？后续请求将无法使用该密码，已开始的传输可能继续到结束。`,
      confirmText: "确认撤销",
      variant: "danger",
    }))
  )
    return;
  busy.value = true;
  error.value = "";
  try {
    await apiRequest("/api/v2/dav/credentials/" + encodeURIComponent(String(item.id)), {
      method: "DELETE",
    });
    await refresh();
  } catch (e) {
    error.value = describeUserFacingError(e);
  } finally {
    busy.value = false;
  }
}

function copy(text: string, what: string) {
  const showText = () => window.prompt("复制以下" + what + "：", text);
  if (!navigator.clipboard) {
    showText();
    return;
  }
  navigator.clipboard
    .writeText(text)
    .then(() => {
      if (what === "密码") freshCopied.value = true;
    })
    .catch(showText);
}

const formatDate = (unix: number) =>
  unix > 0 ? new Date(unix * 1000).toLocaleDateString() : "—";

onMounted(() => {
  void refresh();
});
</script>

<template>
  <IsleCard
    class="dav-panel"
    title="WebDAV 访问"
    subtitle="使用独立密码挂载至访达、Windows 或 Infuse，不复用网页登录态。"
  >
    <template #icon><FolderSync :size="18" /></template>
    <template #actions>
      <IsleButton variant="glass" size="sm" :loading="loading" :disabled="busy" @click="refresh">
        <template #icon><RefreshCw :size="14" /></template>
        {{ loading ? "加载中…" : "刷新" }}
      </IsleButton>
    </template>

    <div class="dav-body">
      <IsleBanner v-if="mountError" type="error" compact :message="mountError" />

      <div class="dav-section">
        <div class="dav-section-header">
          <strong>已授权挂载地址</strong>
          <small>每块已授权硬盘对应独立 WebDAV 挂载点</small>
        </div>
        <p v-if="!roots.length && !loading && !mountError" class="footnote">
          当前账号还没有可挂载的硬盘。
        </p>
        <div v-else class="dav-mounts-list">
          <div v-for="root in roots" :key="root.rootID" class="dav-url-row">
            <div class="dav-root-title">
              <HardDrive :size="15" class="dav-root-icon" />
              <strong>{{ root.name }}</strong>
              <IsleBadge :variant="root.online ? 'online' : 'offline'" dot size="sm">
                {{ root.online ? "在线" : "离线 · 请接回原盘" }}
              </IsleBadge>
            </div>
            <div v-if="root.online" class="dav-url-actions">
              <code class="dav-url">{{ mountUrl(root) }}</code>
              <IsleButton variant="tonal" size="sm" @click="copy(mountUrl(root), 'DAV 地址')">
                <template #icon><Copy :size="13" /></template>
                复制地址
              </IsleButton>
            </div>
          </div>
        </div>
      </div>

      <div class="dav-section">
        <div class="dav-section-header">
          <strong>独立连接密码</strong>
          <small>可按设备分别创建密码，随时单独旋转或撤销</small>
        </div>

        <div class="dav-create">
          <input
            v-model="label"
            class="isle-text-input"
            maxlength="64"
            placeholder="输入客户端标签（如：MacBook Finder / Apple TV Infuse）"
            @keyup.enter="create"
          />
          <IsleButton variant="primary" size="md" :loading="busy" @click="create">
            <template #icon><Plus :size="15" /></template>
            生成新密码
          </IsleButton>
        </div>

        <div v-if="freshPassword" class="dav-fresh" role="status">
          <p><KeyRound :size="14" /> 新密码（仅显示这一次，请立即保存）：</p>
          <div class="dav-fresh-row">
            <code>{{ freshPassword }}</code>
            <IsleButton variant="tonal" size="sm" @click="copy(freshPassword, '密码')">
              <template #icon><Copy :size="13" /></template>
              {{ freshCopied ? "已复制" : "复制密码" }}
            </IsleButton>
          </div>
          <IsleButton variant="primary" size="sm" class="dav-fresh-close" @click="freshPassword = ''">
            我已保存，关闭
          </IsleButton>
        </div>

        <IsleBanner v-if="error" type="error" compact :message="error" />

        <IsleEmpty
          v-if="!credentials.length && !loading"
          compact
          :icon="KeyRound"
          title="暂无 WebDAV 独立密码"
          description="生成一个后即可用「用户名 + 该密码」在访达或第三方客户端安全连接。"
        />

        <div v-if="credentials.length" class="dav-cred-list">
          <div v-for="item in credentials" :key="item.id" class="dav-item">
            <div>
              <strong>{{ item.label }}</strong>
              <small>
                创建于 {{ formatDate(item.createdAt) }} · 最近使用
                {{ item.lastUsedAt > 0 ? formatDate(item.lastUsedAt) : "从未" }}
              </small>
            </div>
            <div class="dav-item-actions">
              <IsleButton variant="glass" size="sm" :disabled="busy" @click="rotate(item)">
                <template #icon><RefreshCw :size="13" /></template>
                重新生成
              </IsleButton>
              <IsleButton variant="danger" size="sm" :disabled="busy" @click="revoke(item)">
                <template #icon><Trash2 :size="14" /></template>
                撤销
              </IsleButton>
            </div>
          </div>
        </div>
      </div>
    </div>

    <template #footer>
      <div class="dav-guide">
        <ShieldCheck :size="15" class="dav-guide-icon" />
        <div>
          <strong>连接说明：</strong>
          <span>
            macOS 访达按 ⌘K，或 Windows / Infuse 选择 WebDAV，输入上方挂载地址、当前用户名与生成的独立密码。硬盘重新绑定后请刷新并复制新地址。
          </span>
        </div>
      </div>
    </template>
  </IsleCard>
</template>

<style scoped>
.dav-body {
  display: flex;
  flex-direction: column;
  gap: 18px;
}
.dav-section {
  display: flex;
  flex-direction: column;
  gap: 10px;
}
.dav-section + .dav-section {
  padding-top: 16px;
  border-top: 1px solid color-mix(in srgb, var(--fluid-card-border) 65%, transparent);
}
.dav-section-header {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 8px;
  flex-wrap: wrap;
}
.dav-section-header strong {
  font-size: 13.5px;
  font-weight: 650;
  color: var(--text-primary);
}
.dav-section-header small {
  font-size: 12px;
  color: var(--text-secondary);
}
.dav-mounts-list,
.dav-cred-list {
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.dav-url-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  flex-wrap: wrap;
  padding: 11px 14px;
  border-radius: 14px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
  box-shadow: var(--fluid-item-card-shadow);
}
.dav-root-title {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}
.dav-root-icon {
  color: var(--accent-primary);
}
.dav-url-actions {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
  min-width: 0;
  flex: 1;
  justify-content: flex-end;
}
.dav-url {
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
  font-size: 12px;
  color: var(--text-primary);
  background: var(--fluid-card-fill);
  border: 1px solid var(--fluid-card-border);
  border-radius: 9px;
  padding: 6px 10px;
  overflow-wrap: anywhere;
  user-select: all;
}
.dav-create {
  display: flex;
  gap: 10px;
  flex-wrap: wrap;
  align-items: center;
}
.dav-create input {
  flex: 1;
  min-width: 220px;
  border: 1px solid var(--fluid-card-border);
  border-radius: 12px;
  padding: 10px 14px;
  background: var(--fluid-card-item-bottom);
  color: var(--text-primary);
  font-size: 13px;
  transition: border-color 0.2s ease, box-shadow 0.2s ease;
}
.dav-create input:focus {
  border-color: var(--accent-primary);
  box-shadow: 0 0 0 3px color-mix(in srgb, var(--accent-primary) 18%, transparent);
  outline: none;
}
.dav-fresh {
  display: grid;
  gap: 10px;
  padding: 14px 16px;
  border-radius: 14px;
  border: 1px solid color-mix(in srgb, var(--accent-primary) 35%, transparent);
  background: color-mix(in srgb, var(--accent-primary) 7%, transparent);
}
.dav-fresh p {
  margin: 0;
  font-size: 12.5px;
  font-weight: 650;
  display: flex;
  align-items: center;
  gap: 7px;
}
.dav-fresh-row {
  display: flex;
  align-items: center;
  gap: 10px;
  flex-wrap: wrap;
}
.dav-fresh-row code {
  font-size: 13px;
  letter-spacing: 0.4px;
  background: var(--fluid-card-fill);
  border: 1px solid var(--fluid-card-border);
  border-radius: 9px;
  padding: 7px 11px;
  user-select: all;
  overflow-wrap: anywhere;
}
.dav-fresh-close {
  justify-self: start;
}
.dav-item {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  flex-wrap: wrap;
  padding: 12px 16px;
  border-radius: 14px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
  box-shadow: var(--fluid-item-card-shadow);
}
.dav-item-actions {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}
.dav-item strong {
  display: block;
  font-size: 13.5px;
  color: var(--text-primary);
}
.dav-item small {
  font-size: 11.5px;
  color: var(--text-secondary);
}
.dav-guide {
  display: flex;
  align-items: flex-start;
  gap: 8px;
  width: 100%;
  font-size: 12px;
  line-height: 1.6;
  color: var(--text-secondary);
}
.dav-guide-icon {
  color: var(--accent-primary);
  flex-shrink: 0;
  margin-top: 2px;
}
.dav-guide strong {
  color: var(--text-primary);
}
</style>
