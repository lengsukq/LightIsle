<script setup lang="ts">
import { onMounted, onUnmounted, reactive, ref } from "vue";
import { RefreshCw, Users } from "lucide-vue-next";
import IsleBadge from "../../components/ui/IsleBadge.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleDisclosure from "../../components/ui/IsleDisclosure.vue";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import IsleGroupedList from "../../components/ui/IsleGroupedList.vue";
import { apiFetch } from "../../api/apiClient.ts";
import { readApiFailure } from "../../api/apiFailure.ts";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import { reservationRootLabel } from "./pendingReservationPresentation.ts";
import { formatMegabytes, formatUnixDateTime } from "../../utils/format.ts";

type Account = { id: number; username: string; enabled: boolean };
type Root = { rootID: string; generation: number; name: string; online: boolean };
type Reservation = {
  id: string;
  rootID: string;
  rootGeneration: number;
  relativePath: string;
  sizeBytes: number;
  uploadID?: string;
  operation?: string;
  createdAt: number;
};
type Group = { items: Reservation[]; next: string; loading: boolean; loaded: boolean; error: string };

const props = defineProps<{ roots: Root[]; rootsKnown: boolean }>();
const emit = defineEmits<{ "open-storage": [] }>();
const accounts = ref<Account[]>([]);
const accountError = ref("");
const accountsLoaded = ref(false);
const groups = reactive<Record<number, Group>>({});
const controller = new AbortController();
let disposed = false;

async function request<T>(path: string): Promise<T> {
  const response = await apiFetch(path, { signal: controller.signal });
  if (!response.ok) throw await readApiFailure(response);
  return (await response.json()) as T;
}

async function loadAccounts() {
  accountError.value = "";
  try {
    const result = await request<{ users: Account[] }>("/api/v2/users");
    if (disposed) return;
    for (const account of result.users) group(account.id);
    accounts.value = result.users;
    accountsLoaded.value = true;
  } catch (error) {
    if (!disposed) accountError.value = "读取成员失败，预占情况不完整：" + describeUserFacingError(error);
  }
}

function group(id: number): Group {
  return groups[id] ?? (groups[id] = { items: [], next: "", loading: false, loaded: false, error: "" });
}

async function load(id: number, more = false) {
  const target = group(id);
  if (target.loading) return;
  target.loading = true;
  target.error = "";
  const query = new URLSearchParams({ limit: "20" });
  if (more && target.next) query.set("after", target.next);
  try {
    const result = await request<{ reservations: Reservation[]; nextCursor: string }>(
      `/api/v2/users/${id}/storage/reservations?${query}`,
    );
    if (disposed) return;
    target.items = more ? [...target.items, ...result.reservations] : result.reservations;
    target.next = result.nextCursor;
    target.loaded = true;
  } catch (error) {
    if (!disposed) target.error = "读取失败，结果不完整：" + describeUserFacingError(error);
  } finally {
    target.loading = false;
  }
}

function onToggleAccount(id: number, open: boolean) {
  const target = group(id);
  if (open && !target.loaded && !target.loading) void load(id);
}

function rootLabel(item: Reservation) {
  return reservationRootLabel(item, props.roots, props.rootsKnown);
}

function size(bytes: number) {
  return formatMegabytes(bytes);
}

function date(timestamp: number) {
  return formatUnixDateTime(timestamp, "时间未知");
}

onMounted(() => void loadAccounts());
onUnmounted(() => {
  disposed = true;
  controller.abort();
});
</script>

<template>
  <div class="pending-reservations">
    <p class="res-note">显示进行中或结果待确认的容量预占；磁盘离线时不会自动释放。</p>
    <IsleBanner v-if="accountError" type="error" compact role="alert">
      {{ accountError }}
      <template #action>
        <IsleButton variant="glass" size="sm" @click="loadAccounts">重试</IsleButton>
      </template>
    </IsleBanner>
    <p v-else-if="!accountsLoaded" class="footnote">正在读取成员…</p>
    <IsleEmpty v-else-if="!accounts.length" compact description="没有可检查的成员账号。" />

    <IsleDisclosure
      v-for="account in accounts"
      :key="account.id"
      :title="account.username"
      :icon="Users"
      @toggle="(open) => onToggleAccount(account.id, open)"
    >
      <template #meta>
        <IsleBadge :variant="account.enabled ? 'online' : 'offline'" size="sm" dot>
          {{ account.enabled ? "已启用" : "已停用" }}
        </IsleBadge>
      </template>

      <IsleBanner v-if="group(account.id).error" type="error" compact role="alert">{{ group(account.id).error }}</IsleBanner>
      <p v-else-if="group(account.id).loading && !group(account.id).loaded" class="footnote">正在读取…</p>
      <IsleEmpty
        v-else-if="group(account.id).loaded && !group(account.id).items.length"
        compact
        description="该成员当前没有已记录的预占。"
      />

      <IsleGroupedList v-if="group(account.id).items.length" variant="item" flush>
        <TransitionGroup name="isle-list" tag="div" class="settings-grouped-rows">
          <div v-for="item in group(account.id).items" :key="item.id" class="account-row reservation-row">
            <div class="reservation-path">
              <strong>{{ item.relativePath }}</strong>
              <small class="res-tabular">{{ rootLabel(item) }} · {{ size(item.sizeBytes) }} · {{ date(item.createdAt) }}</small>
              <small v-if="item.uploadID">有关联上传：请切换到对应硬盘，在「未完成上传」中检查任务后处理。</small>
              <small v-else-if="item.operation === 'download_publish'">下载发布待核对。请接回原盘，再到下载中心查看和继续原任务。</small>
              <small v-else-if="item.operation?.startsWith('dav_')">WebDAV 写入待核对。请接回原盘，核对目标文件和回收站。</small>
              <small v-else>没有可确认的上传关联；请在 Mac 上核对原硬盘、目标文件和存储配置，暂不能安全释放。</small>
            </div>
          </div>
        </TransitionGroup>
      </IsleGroupedList>

      <div class="reservation-actions">
        <IsleButton
          v-if="group(account.id).next"
          variant="glass"
          size="sm"
          :loading="group(account.id).loading"
          @click="load(account.id, true)"
        >
          加载更多
        </IsleButton>
        <IsleButton
          variant="ghost"
          size="sm"
          :loading="group(account.id).loading"
          aria-label="重新检查成员预占"
          title="重新检查"
          @click="load(account.id)"
        >
          <template #icon><RefreshCw :size="14" /></template>
          重新检查
        </IsleButton>
      </div>
    </IsleDisclosure>

    <div class="reservation-footer">
      <IsleButton variant="tonal" size="sm" @click="emit('open-storage')">打开成员存储管理</IsleButton>
    </div>
  </div>
</template>

<style scoped>
.pending-reservations {
  margin: 2px 0;
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.res-note {
  margin: 0 0 2px;
  font-size: 12px;
  color: var(--text-secondary);
}

.res-tabular {
  font-variant-numeric: tabular-nums;
}

.reservation-path {
  min-width: 0;
  overflow-wrap: anywhere;
}

.reservation-actions {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}

.reservation-footer {
  margin-top: 2px;
}
</style>
