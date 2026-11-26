<script setup lang="ts">
import { onMounted, ref } from "vue";
import {
  FolderSync,
  Plus,
  Copy,
  Check,
  Trash2,
  KeyRound,
  RefreshCw,
  HardDrive,
  Tv,
} from "lucide-vue-next";
import { requestConfirm } from "../../composables/useConfirmDialog.ts";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import { copyTextToClipboard } from "../../utils/clipboard.ts";
import { apiRequest } from "../../api/apiClient.ts";
import { formatUnixDateTime } from "../../utils/format.ts";
import { TIMINGS_MS } from "../../constants/timings.ts";
import IsleCard from "../../components/ui/IsleCard.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleBadge from "../../components/ui/IsleBadge.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import IsleHelpButton from "../../components/ui/IsleHelpButton.vue";
import IsleGroupedList from "../../components/ui/IsleGroupedList.vue";
import IsleDisclosure from "../../components/ui/IsleDisclosure.vue";
import IsleActionMenu from "../../components/ui/IsleActionMenu.vue";

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
const tvCopiedRoot = ref("");
const urlCopiedRoot = ref("");
const fieldCopiedKey = ref("");

const davHelpItems = [
  {
    title: "访达 / Windows / Infuse 连接方式",
    body: "macOS 访达按 ⌘K（连接服务器），或 Windows / Infuse / VidHub 选择 WebDAV，填入下方挂载地址、当前轻屿用户名与生成的独立密码。",
  },
  {
    title: "独立密码与换盘规则",
    body: "WebDAV 不复用网页登录密码，可按设备分别创建、重新生成或撤销；存储盘重新绑定后请刷新并复制新地址。",
  },
];

function mountUrl(root: MountRoot) {
  return `${location.origin}/dav-roots/${encodeURIComponent(root.rootID)}/${root.generation}/`;
}

function parsedMount(root: MountRoot) {
  const parsed = new URL(mountUrl(root));
  const defaultPort = parsed.protocol === "https:" ? "443" : "80";
  return {
    protocolLabel: parsed.protocol === "https:" ? "WebDAV (HTTPS)" : "WebDAV (HTTP)",
    host: parsed.hostname,
    port: parsed.port || defaultPort,
    pathname: parsed.pathname,
    fullUrl: parsed.href,
  };
}

function mountDetailRows(root: MountRoot) {
  const info = parsedMount(root);
  return [
    { key: "host", label: "服务器主机", value: info.host, aria: "复制服务器主机", wide: false },
    { key: "port", label: "端口", value: info.port, aria: "复制端口", wide: false },
    { key: "path", label: "路径（含磁盘标识）", value: info.pathname, aria: "复制挂载路径", wide: true },
  ];
}

function buildTvClientGuide(root: MountRoot) {
  const info = parsedMount(root);
  return [
    `【轻屿 · Apple TV / Infuse / VidHub WebDAV 接入参数】`,
    `存储盘：${root.name}`,
    `协议：${info.protocolLabel}`,
    `地址：${info.host}`,
    `端口：${info.port}`,
    `路径：${info.pathname}`,
    `完整 URL：${info.fullUrl}`,
    `用户名：（当前轻屿登录用户名）`,
    `密码：（使用下方生成的 WebDAV 独立连接密码，切勿填写网页登录密码）`,
  ].join("\n");
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

async function copy(text: string, what: string) {
  if (await copyTextToClipboard(text)) {
    if (what === "密码") {
      freshCopied.value = true;
      window.setTimeout(() => {
        freshCopied.value = false;
      }, TIMINGS_MS.COPIED_FEEDBACK);
    } else if (what.startsWith("TV:")) {
      const id = what.slice(3);
      tvCopiedRoot.value = id;
      window.setTimeout(() => {
        if (tvCopiedRoot.value === id) tvCopiedRoot.value = "";
      }, TIMINGS_MS.COPIED_FEEDBACK);
    } else if (what.startsWith("URL:")) {
      const id = what.slice(4);
      urlCopiedRoot.value = id;
      window.setTimeout(() => {
        if (urlCopiedRoot.value === id) urlCopiedRoot.value = "";
      }, TIMINGS_MS.COPIED_FEEDBACK);
    } else if (what.startsWith("FIELD:")) {
      const key = what.slice(6);
      fieldCopiedKey.value = key;
      window.setTimeout(() => {
        if (fieldCopiedKey.value === key) fieldCopiedKey.value = "";
      }, TIMINGS_MS.COPIED_FEEDBACK);
    }
    return;
  }
  error.value = "浏览器当前环境不支持一键写入剪贴板，请手动选中上方内容后复制。";
}

const formatDate = (unix: number, fallback = "—") =>
  formatUnixDateTime(unix, fallback);

onMounted(() => {
  void refresh();
});
</script>

<template>
  <IsleCard
    class="dav-panel"
    title="WebDAV 访问"
    subtitle="使用独立密码挂载至访达、Windows 或 Infuse。"
  >
    <template #icon><FolderSync :size="18" /></template>
    <template #actions>
      <IsleHelpButton title="WebDAV 连接向导与安全说明" :items="davHelpItems" modal-size="md" />
      <button
        type="button"
        class="storage-header-refresh"
        :disabled="loading || busy"
        aria-label="刷新 WebDAV 配置"
        title="刷新 WebDAV 配置"
        @click="refresh"
      >
        <RefreshCw :size="14" :class="{ 'is-spinning': loading }" />
      </button>
    </template>

    <div class="dav-body">
      <IsleBanner v-if="mountError" type="error" compact :message="mountError" />

      <IsleGroupedList
        title="已授权挂载地址"
        subtitle="点击复制即可在访达（⌘K）或 Infuse 中连接，无需暴露底层路径"
        variant="item"
        flush
      >
        <p v-if="loading && !roots.length" class="dav-list-hint" role="status">
          正在读取可挂载硬盘…
        </p>
        <p v-else-if="!roots.length && !mountError" class="dav-list-hint">
          当前账号还没有可挂载的硬盘。
        </p>
        <TransitionGroup v-else name="isle-list" tag="div" class="dav-mounts-list">
          <div v-for="root in roots" :key="root.rootID" class="dav-mount-item">
            <div class="dav-url-row">
              <div class="dav-root-title">
                <HardDrive :size="15" class="dav-root-icon" />
                <strong>{{ root.name }}</strong>
                <IsleBadge :variant="root.online ? 'online' : 'offline'" dot size="sm">
                  {{ root.online ? "在线" : "离线 · 请接回原盘" }}
                </IsleBadge>
                <IsleBadge v-if="root.online" variant="neutral" size="sm" class="dav-tabular">
                  {{ parsedMount(root).protocolLabel }} :{{ parsedMount(root).port }}
                </IsleBadge>
              </div>

              <div v-if="root.online" class="dav-url-actions">
                <IsleButton
                  variant="tonal"
                  size="sm"
                  :class="{ 'is-copied': urlCopiedRoot === root.rootID }"
                  @click="copy(mountUrl(root), 'URL:' + root.rootID)"
                >
                  <template #icon>
                    <Transition name="isle-copy-swap" mode="out-in">
                      <Check v-if="urlCopiedRoot === root.rootID" key="ok" :size="13" />
                      <Copy v-else key="copy" :size="13" />
                    </Transition>
                  </template>
                  {{ urlCopiedRoot === root.rootID ? "已复制地址" : "复制挂载地址" }}
                </IsleButton>
                <IsleActionMenu :aria-label="'更多挂载操作：' + root.name">
                  <button type="button" role="menuitem" @click="copy(buildTvClientGuide(root), 'TV:' + root.rootID)">
                    <Tv :size="14" />
                    {{ tvCopiedRoot === root.rootID ? "已复制 Infuse 大屏参数" : "复制 Infuse / VidHub 参数" }}
                  </button>
                </IsleActionMenu>
              </div>
            </div>

            <p v-if="!root.online" class="dav-offline-note">
              存储盘当前离线，请检查电源或重新连接硬盘后刷新挂载地址。
            </p>

            <IsleDisclosure
              v-else
              variant="inline"
              title="连接参数与路径详情"
              subtitle="手动配置 Infuse 或其他客户端时展开查看主机、端口与路径"
            >
              <div class="dav-detail-grid dav-tabular">
                <div
                  v-for="row in mountDetailRows(root)"
                  :key="row.key"
                  class="dav-detail-row"
                  :class="{ 'dav-detail-wide': row.wide }"
                >
                  <span class="dav-detail-key">{{ row.label }}</span>
                  <div class="dav-detail-val">
                    <code>{{ row.value }}</code>
                    <button
                      type="button"
                      class="dav-mini-copy"
                      :class="{ 'is-copied': fieldCopiedKey === `${root.rootID}:${row.key}` }"
                      :aria-label="row.aria"
                      @click="copy(row.value, `FIELD:${root.rootID}:${row.key}`)"
                    >
                      <Transition name="isle-copy-swap" mode="out-in">
                        <Check v-if="fieldCopiedKey === `${root.rootID}:${row.key}`" key="ok" :size="12" />
                        <Copy v-else key="copy" :size="12" />
                      </Transition>
                    </button>
                  </div>
                </div>
              </div>
            </IsleDisclosure>
          </div>
        </TransitionGroup>
      </IsleGroupedList>

      <div class="dav-section">
        <div class="dav-section-header">
          <strong>独立连接密码</strong>
          <small>按设备分别创建，与网页登录密码隔离</small>
        </div>

        <div class="dav-create">
          <input
            v-model="label"
            class="isle-text-input"
            maxlength="64"
            placeholder="设备标签（如 MacBook / Infuse）"
            @keyup.enter="create"
          />
          <IsleButton variant="primary" size="sm" :loading="busy" @click="create">
            <template #icon><Plus :size="14" /></template>
            生成新密码
          </IsleButton>
        </div>

        <div v-if="freshPassword" class="dav-fresh" role="status">
          <p><KeyRound :size="14" /> 新密码（仅显示一次，请立即保存）：</p>
          <div class="dav-fresh-row">
            <code>{{ freshPassword }}</code>
            <IsleButton variant="tonal" size="sm" :class="{ 'is-copied': freshCopied }" @click="copy(freshPassword, '密码')">
              <template #icon>
                <Transition name="isle-copy-swap" mode="out-in">
                  <Check v-if="freshCopied" key="ok" :size="13" />
                  <Copy v-else key="copy" :size="13" />
                </Transition>
              </template>
              {{ freshCopied ? "已复制" : "复制密码" }}
            </IsleButton>
          </div>
          <IsleButton variant="primary" size="sm" class="dav-fresh-close" @click="freshPassword = ''">
            我已保存，关闭
          </IsleButton>
        </div>

        <IsleBanner v-if="error" type="error" compact :message="error" />

        <p v-if="loading && !credentials.length" class="footnote" role="status">
          正在读取 WebDAV 独立密码…
        </p>
        <IsleEmpty
          v-else-if="!credentials.length"
          compact
          :icon="KeyRound"
          title="暂无 WebDAV 独立密码"
          description="生成一个后即可用「用户名 + 独立密码」安全挂载。"
        />

        <IsleGroupedList v-else variant="item" flush>
          <TransitionGroup name="isle-list" tag="div" class="dav-cred-list">
            <div v-for="item in credentials" :key="item.id" class="dav-item">
              <div>
                <strong>{{ item.label }}</strong>
                <small class="dav-tabular">
                  创建于 {{ formatDate(item.createdAt) }} · 最近使用
                  {{ formatDate(item.lastUsedAt, "从未") }}
                </small>
              </div>
              <div class="dav-item-actions">
                <IsleButton variant="glass" size="sm" :disabled="busy" @click="rotate(item)">
                  <template #icon><RefreshCw :size="13" /></template>
                  重新生成
                </IsleButton>
                <IsleActionMenu :aria-label="'密码操作：' + item.label">
                  <button type="button" role="menuitem" class="danger" :disabled="busy" @click="revoke(item)">
                    <Trash2 :size="14" />撤销此密码
                  </button>
                </IsleActionMenu>
              </div>
            </div>
          </TransitionGroup>
        </IsleGroupedList>
      </div>
    </div>
  </IsleCard>
</template>

<style scoped>
.dav-body {
  display: flex;
  flex-direction: column;
  gap: 14px;
}
.dav-section {
  display: flex;
  flex-direction: column;
  gap: 9px;
}
.dav-section .footnote {
  margin: 0;
}
.dav-section-header {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 8px;
  flex-wrap: wrap;
  padding: 0 2px;
}
.dav-section-header strong {
  font-size: 13px;
  font-weight: 650;
  color: var(--text-primary);
}
.dav-section-header small {
  font-size: 11.5px;
  color: var(--text-secondary);
}
.dav-tabular {
  font-variant-numeric: tabular-nums;
}
.dav-list-hint {
  margin: 0;
  padding: 12px 16px;
  font-size: 12px;
  color: var(--text-secondary);
}
.dav-mounts-list,
.dav-cred-list {
  display: flex;
  flex-direction: column;
  min-width: 0;
}
.dav-mount-item {
  display: flex;
  flex-direction: column;
  gap: 6px;
  padding: 11px 16px;
}
.dav-mount-item + .dav-mount-item {
  border-top: 1px solid var(--fluid-divider, rgba(20, 19, 17, 0.06));
}
.dav-url-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  flex-wrap: wrap;
}
.dav-root-title {
  display: inline-flex;
  align-items: center;
  gap: 7px;
  flex-wrap: wrap;
  min-width: 0;
  max-width: 100%;
  font-size: 13px;
}
.dav-root-icon {
  color: var(--accent-primary);
  flex-shrink: 0;
}
.dav-url-actions {
  display: flex;
  align-items: center;
  gap: 6px;
  flex-wrap: wrap;
  flex-shrink: 0;
}
.dav-offline-note {
  margin: 0;
  font-size: 11.5px;
  color: var(--text-secondary);
}
.dav-detail-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(min(100%, 190px), 1fr));
  gap: 8px 12px;
}
.dav-detail-row {
  display: flex;
  flex-direction: column;
  gap: 3px;
  min-width: 0;
}
.dav-detail-wide {
  grid-column: 1 / -1;
}
.dav-detail-key {
  font-size: 11px;
  color: var(--text-tertiary);
}
.dav-detail-val {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 6px;
  padding: 5px 8px;
  border-radius: 8px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-fill);
  min-width: 0;
}
.dav-detail-val code {
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
  font-size: 11.5px;
  color: var(--text-primary);
  overflow-wrap: anywhere;
  user-select: all;
}
.dav-mini-copy {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 24px;
  height: 24px;
  border: 0;
  border-radius: 6px;
  background: transparent;
  color: var(--text-secondary);
  cursor: pointer;
  flex-shrink: 0;
  transition: background-color 140ms ease, color 140ms ease;
}
.dav-mini-copy:hover {
  background: var(--fluid-card-hover);
  color: var(--accent-primary);
}
.dav-mini-copy.is-copied {
  color: var(--success, #167a54);
}
.dav-create {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
  align-items: center;
}
.dav-create input {
  flex: 1 1 190px;
  min-width: min(100%, 190px);
  border: 1px solid var(--fluid-card-border);
  border-radius: 10px;
  padding: 8px 12px;
  background: var(--fluid-card-item-bottom);
  color: var(--text-primary);
  font-size: 12.5px;
  transition: border-color 0.2s ease, box-shadow 0.2s ease;
}
.dav-create input:focus {
  border-color: var(--accent-primary);
  box-shadow: 0 0 0 3px color-mix(in srgb, var(--accent-primary) 16%, transparent);
  outline: none;
}
.dav-fresh {
  display: grid;
  gap: 8px;
  padding: 11px 13px;
  border-radius: 12px;
  border: 1px solid color-mix(in srgb, var(--accent-primary) 35%, transparent);
  background: color-mix(in srgb, var(--accent-primary) 7%, transparent);
}
.dav-fresh p {
  margin: 0;
  font-size: 12px;
  font-weight: 650;
  display: flex;
  align-items: center;
  gap: 6px;
}
.dav-fresh-row {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}
.dav-fresh-row code {
  font-size: 12.5px;
  letter-spacing: 0.3px;
  background: var(--fluid-card-fill);
  border: 1px solid var(--fluid-card-border);
  border-radius: 8px;
  padding: 6px 10px;
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
  padding: 11px 16px;
}
.dav-item + .dav-item {
  border-top: 1px solid var(--fluid-divider, rgba(20, 19, 17, 0.06));
}
.dav-item > div:first-child {
  min-width: 0;
  flex: 1 1 200px;
  overflow-wrap: anywhere;
}
.dav-item-actions {
  display: flex;
  align-items: center;
  gap: 6px;
  flex-wrap: wrap;
  flex-shrink: 0;
}
.dav-item strong {
  display: block;
  font-size: 13px;
  color: var(--text-primary);
}
.dav-item small {
  font-size: 11.5px;
  color: var(--text-secondary);
}
@media (max-width: 480px) {
  .dav-create input {
    flex: 1 1 100%;
    min-width: 0;
  }
}
@media (prefers-reduced-motion: reduce) {
  .dav-create input,
  .dav-mini-copy {
    transition: none;
  }
}
</style>
