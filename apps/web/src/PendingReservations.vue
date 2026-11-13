<script setup lang="ts">
import { onMounted, onUnmounted, reactive, ref } from "vue";
import { ChevronRight, Users } from "lucide-vue-next";
import IsleButton from "./IsleButton.vue";
import IsleBadge from "./IsleBadge.vue";
import IsleBanner from "./IsleBanner.vue";
import IsleEmpty from "./IsleEmpty.vue";
import { apiErrorFromResponse } from "./apiFailure.ts";
import { describeUserFacingError } from "./userFacingError.ts";
import { reservationRootLabel } from "./pendingReservationPresentation.ts";

type Account = { id: number; username: string; enabled: boolean };
type Root = { rootID: string; generation: number; name: string; online: boolean };
type Reservation = { id: string; rootID: string; rootGeneration: number; relativePath: string; sizeBytes: number; uploadID?: string; operation?: string; createdAt: number };
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
  const response = await fetch(path, { credentials: "same-origin", cache: "no-store", signal: controller.signal });
  const result = await response.json().catch(() => ({ error: "invalid_response" }));
  if (!response.ok) throw apiErrorFromResponse(response, result);
  return result as T;
}

async function loadAccounts() {
  accountError.value = "";
  try {
    const result = await request<{ users: Account[] }>("/api/v2/users");
    if (disposed) return;
    for (const account of result.users) group(account.id);
    accounts.value = result.users; accountsLoaded.value = true;
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
  target.loading = true; target.error = "";
  const query = new URLSearchParams({ limit: "20" });
  if (more && target.next) query.set("after", target.next);
  try {
    const result = await request<{ reservations: Reservation[]; nextCursor: string }>(`/api/v2/users/${id}/storage/reservations?${query}`);
    if (disposed) return;
    target.items = more ? [...target.items, ...result.reservations] : result.reservations;
    target.next = result.nextCursor; target.loaded = true;
  } catch (error) {
    if (!disposed) target.error = "读取失败，结果不完整：" + describeUserFacingError(error);
  } finally {
    target.loading = false;
  }
}

function openAccount(id: number, event: Event) {
  const target = group(id);
  if ((event.target as HTMLDetailsElement).open && !target.loaded && !target.loading) void load(id);
}

function rootLabel(item: Reservation) {
  return reservationRootLabel(item, props.roots, props.rootsKnown);
}

function size(bytes: number) { return (bytes / (1024 ** 2)).toLocaleString("zh-CN", { maximumFractionDigits: 1 }) + " MB"; }
function date(timestamp: number) { return timestamp ? new Date(timestamp * 1000).toLocaleString() : "时间未知"; }

onMounted(() => void loadAccounts());
onUnmounted(() => { disposed = true; controller.abort(); });
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

    <details
      v-for="account in accounts"
      :key="account.id"
      class="apple-disclosure-card"
      @toggle="openAccount(account.id, $event)"
    >
      <summary>
        <div class="disclosure-title">
          <Users :size="14" class="disclosure-icon" />
          <span>{{ account.username }}</span>
          <IsleBadge :variant="account.enabled ? 'online' : 'offline'" size="sm">
            {{ account.enabled ? "已启用" : "已停用" }}
          </IsleBadge>
        </div>
        <ChevronRight :size="14" class="disclosure-chevron" />
      </summary>
      <div class="disclosure-body">
        <IsleBanner v-if="group(account.id).error" type="error" compact role="alert">{{ group(account.id).error }}</IsleBanner>
        <p v-else-if="group(account.id).loading && !group(account.id).loaded" class="footnote">正在读取…</p>
        <IsleEmpty v-else-if="group(account.id).loaded && !group(account.id).items.length" compact description="该成员当前没有已记录的预占。" />
        <div v-for="item in group(account.id).items" :key="item.id" class="account-row">
          <div class="reservation-path">
            <strong>{{ item.relativePath }}</strong>
            <small>{{ rootLabel(item) }} · {{ size(item.sizeBytes) }} · {{ date(item.createdAt) }}</small>
            <small v-if="item.uploadID">有关联上传：请切换到对应硬盘，在「未完成上传」中检查任务后处理。</small>
            <small v-else-if="item.operation === 'download_publish'">下载发布待核对。请接回原盘，再到下载中心查看和继续原任务。</small>
            <small v-else-if="item.operation?.startsWith('dav_')">WebDAV 写入待核对。请接回原盘，核对目标文件和回收站。</small>
            <small v-else>没有可确认的上传关联；请在 Mac 上核对原硬盘、目标文件和存储配置，暂不能安全释放。</small>
          </div>
        </div>
        <div style="display: flex; gap: 8px; margin-top: 8px;">
          <IsleButton v-if="group(account.id).next" variant="glass" size="sm" :loading="group(account.id).loading" @click="load(account.id, true)">加载更多</IsleButton>
          <IsleButton variant="glass" size="sm" :loading="group(account.id).loading" @click="load(account.id)">重新检查</IsleButton>
        </div>
      </div>
    </details>

    <div style="margin-top: 14px;">
      <IsleButton variant="tonal" size="sm" @click="emit('open-storage')">打开成员存储管理</IsleButton>
    </div>
  </div>
</template>

<style scoped>
.pending-reservations {
  margin: 8px 0;
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.res-note {
  margin: 0 0 4px;
  font-size: 12.5px;
  color: var(--text-secondary);
}
.reservation-path {
  min-width: 0;
  overflow-wrap: anywhere;
}
</style>
