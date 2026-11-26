<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from "vue";
import { RefreshCw, UploadCloud } from "lucide-vue-next";
import { rootApiPath } from "../../api/rootApi.ts";
import { apiFetch } from "../../api/apiClient.ts";
import { readApiFailure } from "../../api/apiFailure.ts";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import { formatDateTime } from "../../utils/dateTimeFormat.ts";
import { formatMegabytes as bytes, formatUnixDateTime } from "../../utils/format.ts";
import AppleSelect from "../../components/ui/AppleSelect.vue";
import IsleBadge from "../../components/ui/IsleBadge.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleCard from "../../components/ui/IsleCard.vue";
import IsleDisclosure from "../../components/ui/IsleDisclosure.vue";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import IsleGroupedList from "../../components/ui/IsleGroupedList.vue";
import IsleModal from "../../components/ui/IsleModal.vue";

const dayOptions = [
  { value: 7, label: "7 天" },
  { value: 30, label: "30 天" },
  { value: 90, label: "90 天" },
];

type Upload = {
  id: string;
  ownerID: number;
  ownerName: string;
  ownerEnabled: boolean;
  ownerMissing: boolean;
  ownerCanWrite: boolean;
  orphan: boolean;
  corrupt: boolean;
  path: string;
  size: number;
  offset: number;
  created: number;
  activity: number;
  published: boolean;
};

const props = defineProps<{ rootId?: string; rootGeneration?: number }>();
const uploads = ref<Upload[]>([]);
const nextCursor = ref("");
const loading = ref(false);
const busy = ref(false);
const error = ref("");
const notice = ref("");
const days = ref(30);
const confirming = ref<Upload | "expired" | null>(null);
const lastUpdatedAt = ref(0);
const unknownOpen = ref(false);
const unknownItems = ref<Array<{ name: string; nameBytes?: string }>>([]);
const unknownNext = ref("");
const unknownError = ref("");
const unknownLoading = ref(false);
const unknownLoaded = ref(false);
let generation = 0;
let disposed = false;
const controller = new AbortController();

const updatedLabel = computed(() =>
  lastUpdatedAt.value ? "更新于 " + formatDateTime(lastUpdatedAt.value).replace(/^.*?\s/, "") : "",
);

function apiPath(path: string) {
  return rootApiPath(props.rootId, path);
}

async function api<T>(path: string, method = "GET", body?: object): Promise<T> {
  const rootID = props.rootId;
  const rootGeneration = props.rootGeneration ?? 0;
  const headers = new Headers();
  if (rootID) headers.set("X-LightIsle-Root-Generation", String(rootGeneration));
  const response = await apiFetch(path, { method, signal: controller.signal, headers, json: body });
  if (rootID && (props.rootId !== rootID || props.rootGeneration !== rootGeneration || disposed)) {
    throw makeRootAbortError();
  }
  if (!response.ok) {
    const failureRes = await readApiFailure(response);
    if (rootID && response.status === 409 && failureRes.code === "root_generation_changed") {
      window.dispatchEvent(new Event("lightisle-root-generation-changed"));
    }
    throw failureRes;
  }
  return (await response.json()) as T;
}

function makeRootAbortError() {
  const err = new Error("root_context_changed");
  err.name = "AbortError";
  return err;
}

function failure(reason: unknown) {
  const code = reason instanceof Error ? reason.message : String(reason);
  const messages: Record<string, string> = {
    volume_offline: "共享磁盘当前不可用，请重新连接后重试。",
    share_offline: "共享磁盘当前不可用，请重新连接后重试。",
    upload_busy: "上传正在写入或提交，请稍后重试。",
    upload_inventory_limit: "上传记录超过本次安全扫描上限，未执行清理。请在 Mac 上检查共享目录后重试。",
    authentication_required: "登录状态已失效，请重新登录。",
    not_found: "上传已结束或已被清理，请刷新列表。",
  };
  return messages[code] ?? describeUserFacingError(reason);
}

async function load(more = false) {
  if (loading.value) return;
  const request = ++generation;
  loading.value = true;
  error.value = "";
  const query = new URLSearchParams({ limit: "20" });
  if (more && nextCursor.value) query.set("after", nextCursor.value);
  try {
    const page = await api<{ uploads: Upload[]; nextCursor: string }>(apiPath("/api/v2/admin/uploads") + "?" + query);
    if (disposed || request !== generation) return;
    uploads.value = more ? [...uploads.value, ...page.uploads] : page.uploads;
    nextCursor.value = page.nextCursor;
    lastUpdatedAt.value = Date.now();
  } catch (reason) {
    if (!disposed) error.value = failure(reason);
  } finally {
    if (request === generation) loading.value = false;
  }
}

async function loadUnknown(more = false) {
  if (unknownLoading.value) return;
  unknownLoading.value = true;
  unknownError.value = "";
  const query = new URLSearchParams({ limit: "20" });
  if (more && unknownNext.value) query.set("after", unknownNext.value);
  try {
    const page = await api<{ items: Array<{ name: string; nameBytes?: string }>; nextCursor: string }>(
      apiPath("/api/v2/admin/uploads/unrecognized") + "?" + query,
    );
    if (disposed) return;
    unknownItems.value = more ? [...unknownItems.value, ...page.items] : page.items;
    unknownNext.value = page.nextCursor;
    unknownLoaded.value = true;
  } catch (reason) {
    if (!disposed) unknownError.value = "读取失败，结果不完整：" + failure(reason);
  } finally {
    unknownLoading.value = false;
  }
}

function onToggleUnknown(open: boolean) {
  unknownOpen.value = open;
  if (open && !unknownLoaded.value && !unknownLoading.value) void loadUnknown();
}

async function confirmCleanup() {
  const target = confirming.value;
  if (!target || busy.value) return;
  busy.value = true;
  error.value = "";
  notice.value = "";
  try {
    if (target === "expired") {
      const result = await api<{ removed: number; skipped: number; hasMore: boolean; pendingReservations?: number }>(
        apiPath("/api/v2/admin/uploads/cleanup-expired"),
        "POST",
        { inactiveForSeconds: days.value * 86400 },
      );
      notice.value = `本次已清理 ${result.removed} 项${result.skipped ? `，保留 ${result.skipped} 项需单独检查的记录` : ""}。${result.pendingReservations ? `${result.pendingReservations} 项容量预占仍需在任务中心检查。` : ""}${result.hasMore ? "仍有过期残留，可再次清理。" : "已发布文件保持不变。"}`;
    } else {
      await api(apiPath("/api/v2/admin/uploads/" + encodeURIComponent(target.id)), "DELETE");
      notice.value = "上传残留已取消；已完成的原文件保持不变。";
    }
    if (disposed) return;
    confirming.value = null;
    await load();
  } catch (reason) {
    if (!disposed) error.value = failure(reason);
  } finally {
    busy.value = false;
  }
}

function date(value: number) {
  return formatUnixDateTime(value, "时间未知");
}

function closeConfirm() {
  if (!busy.value) confirming.value = null;
}

onMounted(() => void load());
onUnmounted(() => {
  disposed = true;
  generation++;
  controller.abort();
});
</script>

<template>
  <IsleCard
    class="upload-maintenance"
    title="未完成上传"
    subtitle="管理当前共享目录的断点续传残留。取消后需重新上传；不会删除已发布的文件。"
  >
    <template #icon><UploadCloud :size="18" /></template>
    <template #actions>
      <span v-if="updatedLabel" class="settings-updated-at">{{ updatedLabel }}</span>
      <IsleButton
        variant="ghost"
        size="sm"
        :loading="loading"
        :disabled="busy"
        aria-label="刷新未完成上传"
        title="刷新未完成上传"
        @click="load()"
      >
        <template #icon><RefreshCw :size="14" /></template>
      </IsleButton>
    </template>

    <div class="upload-stack">
      <IsleBanner v-if="error" type="error" compact role="alert">{{ error }}</IsleBanner>
      <IsleBanner v-if="notice" type="info" compact role="status">{{ notice }}</IsleBanner>
      <p v-if="loading && !uploads.length" class="footnote">正在读取上传记录…</p>
      <IsleEmpty
        v-else-if="!uploads.length && !error"
        compact
        description="当前没有已识别的未完成上传；无法识别的条目可在下方检查。"
      />

      <IsleGroupedList v-if="uploads.length" variant="item" flush>
        <TransitionGroup name="isle-list" tag="div" class="settings-grouped-rows">
          <div v-for="upload in uploads" :key="upload.id" class="account-row">
            <div class="upload-detail">
              <strong class="upload-title-row">
                <span>{{ upload.path }}</span>
                <IsleBadge
                  :variant="upload.ownerMissing || !upload.ownerEnabled || !upload.ownerCanWrite ? 'warning' : 'neutral'"
                  size="sm"
                >
                  {{ upload.ownerMissing ? "账号已移除" : !upload.ownerEnabled ? "账号已停用" : !upload.ownerCanWrite ? "写入授权已撤销" : "账号正常" }}
                </IsleBadge>
                <IsleBadge v-if="upload.published" variant="online" size="sm">已发布，待收尾</IsleBadge>
              </strong>
              <small class="upload-tabular">
                {{ upload.ownerName || `账号 #${upload.ownerID}` }} · {{ bytes(upload.offset) }} / {{ bytes(upload.size) }} · 上次活动 {{ date(upload.activity || upload.created) }}
              </small>
              <small v-if="upload.orphan || upload.corrupt" class="upload-warn-text">
                临时部分或记录异常，请单独检查后取消。
              </small>
            </div>
            <IsleButton variant="danger" size="sm" :disabled="busy" @click="confirming = upload">取消残留</IsleButton>
          </div>
        </TransitionGroup>
      </IsleGroupedList>

      <div v-if="nextCursor" class="gallery-load">
        <IsleButton variant="glass" size="sm" :loading="loading" :disabled="busy" @click="load(true)">
          {{ loading ? "正在加载…" : "加载更多上传" }}
        </IsleButton>
      </div>

      <IsleDisclosure
        :model-value="unknownOpen"
        title="检查无法识别的上传暂存文件"
        subtitle="位于 .lightisle-parts 的未识别文件不会自动清理，请在 Mac 访达核对"
        @update:model-value="onToggleUnknown"
      >
        <p class="upload-unknown-note">
          位于 <code>.lightisle-parts</code> 的未识别文件不会自动清理，请在 Mac 访达（⌘⇧. 显示隐藏文件）核对处理。
        </p>
        <IsleBanner v-if="unknownError" type="error" compact role="alert">{{ unknownError }}</IsleBanner>
        <p v-else-if="unknownLoading && !unknownLoaded" class="footnote">正在检查…</p>
        <IsleEmpty v-else-if="unknownLoaded && !unknownItems.length" compact description="当前未发现无法识别的条目。" />
        <IsleGroupedList v-if="unknownItems.length" variant="item" flush>
          <div class="settings-grouped-rows">
            <div v-for="item in unknownItems" :key="item.nameBytes || item.name" class="account-row">
              <div class="upload-detail">
                <strong>.lightisle-parts/{{ item.name }}</strong>
                <small v-if="item.nameBytes" class="upload-tabular">原始编码标识：{{ item.nameBytes }}</small>
              </div>
            </div>
          </div>
        </IsleGroupedList>
        <div class="upload-actions-row">
          <IsleButton v-if="unknownNext" variant="glass" size="sm" :loading="unknownLoading" @click="loadUnknown(true)">加载更多</IsleButton>
          <IsleButton variant="ghost" size="sm" :loading="unknownLoading" @click="loadUnknown()">
            <template #icon><RefreshCw :size="14" /></template>
            重新检查
          </IsleButton>
        </div>
      </IsleDisclosure>

      <div class="upload-cleanup-controls">
        <span class="upload-cleanup-label">清理多久未活动的上传</span>
        <AppleSelect v-model="days" :options="dayOptions" :disabled="busy" size="sm" aria-label="清理多久未活动的上传" />
        <IsleButton variant="glass" size="sm" :disabled="busy || loading" @click="confirming = 'expired'">清理过期残留…</IsleButton>
      </div>
    </div>

    <IsleModal
      :open="Boolean(confirming)"
      :title="confirming === 'expired' ? '清理过期上传残留' : '取消断点续传残留'"
      size="sm"
      @close="closeConfirm"
    >
      <p class="upload-confirm-copy">
        {{
          confirming === "expired"
            ? `确认清理 ${days} 天没有活动、尚未发布的上传残留？正在写入和提交的上传会受到保护。`
            : confirming
              ? `确认取消“${confirming.path}”的断点续传残留？已上传的临时部分将被清理，已完成的原文件保持不变。`
              : ""
        }}
      </p>
      <IsleBanner v-if="error" type="error" compact role="alert">{{ error }}</IsleBanner>
      <template #footer>
        <IsleButton variant="glass" size="sm" :disabled="busy" @click="confirming = null">保留</IsleButton>
        <IsleButton variant="danger" size="sm" :loading="busy" :disabled="busy" @click="confirmCleanup">
          {{ busy ? "正在处理…" : "确认清理" }}
        </IsleButton>
      </template>
    </IsleModal>
  </IsleCard>
</template>

<style scoped>
.upload-maintenance {
  margin-bottom: 0;
}

.upload-stack {
  display: flex;
  flex-direction: column;
  gap: 10px;
}

.upload-stack .footnote {
  margin: 0;
}

.upload-detail {
  min-width: 0;
  flex: 1 1 200px;
  overflow-wrap: anywhere;
}

.upload-title-row {
  display: flex;
  align-items: center;
  gap: 6px;
  flex-wrap: wrap;
}

.upload-tabular {
  font-variant-numeric: tabular-nums;
}

.upload-warn-text {
  color: var(--warning);
}

.upload-unknown-note {
  margin: 0;
  font-size: 12px;
  color: var(--text-secondary);
}

.upload-actions-row {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
}

.upload-cleanup-controls {
  display: flex;
  gap: 10px;
  flex-wrap: wrap;
  align-items: center;
  padding: 10px 14px;
  border-radius: 12px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
}

.upload-cleanup-label {
  font-size: 12.5px;
  color: var(--text-primary);
}

.upload-confirm-copy {
  margin: 0;
  font-size: 13px;
  line-height: 1.55;
  color: var(--text-secondary);
}
</style>
