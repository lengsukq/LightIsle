<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from "vue";
import { ShieldAlert, ShieldCheck, RefreshCw } from "lucide-vue-next";
import IsleCard from "../../components/ui/IsleCard.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleBadge from "../../components/ui/IsleBadge.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import { apiFetch } from "../../api/apiClient.ts";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import { readApiFailure } from "../../api/apiFailure.ts";
import { formatDateTime } from "../../utils/dateTimeFormat.ts";

type Event = { id: number; actorId: number; actorUsername?: string; action: string; target: string; outcome: "success" | "denied" | "failed"; createdAt: number };
const props = defineProps<{ accounts?: Array<{ id: number; username: string }> }>();
const entries = ref<Event[]>([]);
const resolvedUsernames = ref<Record<number, string>>({});
const cursor = ref(0), loading = ref(false), error = ref(""), filter = ref<"all" | "issues">("all");
let generation = 0;
let controller = new AbortController();
let disposed = false;
const labels: Record<string, string> = {
  account_password_change: "修改账号密码",
  user_or_grant_change: "账号 / 文件权限修改",
  file_share_change: "公开分享链接操作",
  public_share_download: "公开分享下载",
  file_write: "文件管理操作",
  upload_write: "文件续传操作",
  gallery_write: "图库操作",
  cinema_write: "影视资料操作",
  mcp_call: "Agent 操作",
  mcp_call_pending: "Agent 操作待核实",
};

const accountNameMap = computed(() => {
  const map: Record<number, string> = { ...resolvedUsernames.value };
  for (const acc of props.accounts ?? []) {
    if (acc.username) map[acc.id] = acc.username;
  }
  return map;
});

function actorLabel(item: Event): string {
  if (item.actorUsername) return item.actorUsername;
  const known = accountNameMap.value[item.actorId];
  if (known) return known;
  return item.actorId > 0 ? `成员 #${item.actorId}` : "系统";
}

const filteredEntries = computed(() =>
  filter.value === "issues"
    ? entries.value.filter((item) => item.outcome !== "success" || item.action === "mcp_call_pending")
    : entries.value
);

const issueCount = computed(() =>
  entries.value.filter((item) => item.outcome !== "success" || item.action === "mcp_call_pending").length
);

async function ensureUsernames(signal: AbortSignal) {
  if ((props.accounts?.length ?? 0) > 0 || Object.keys(resolvedUsernames.value).length > 0) return;
  try {
    const response = await apiFetch("/api/v2/users", { signal });
    if (!response.ok) return;
    const data = (await response.json()) as { users?: Array<{ id: number; username: string }> };
    if (disposed || !Array.isArray(data.users)) return;
    const next: Record<number, string> = {};
    for (const user of data.users) {
      if (user.username) next[user.id] = user.username;
    }
    resolvedUsernames.value = next;
  } catch {
    /* Non-blocking: fall back to member ID if user list is unavailable. */
  }
}

async function load(reset = false) {
  if (loading.value && !reset) return;
  controller.abort();
  controller = new AbortController();
  const { signal } = controller;
  const current = reset ? ++generation : generation;
  loading.value = true;
  error.value = "";
  try {
    void ensureUsernames(signal);
    const url = new URL("/api/v2/audit", window.location.origin);
    url.searchParams.set("limit", "40");
    if (!reset && cursor.value) url.searchParams.set("before", String(cursor.value));
    const response = await apiFetch(url, { signal });
    if (!response.ok) throw await readApiFailure(response);
    const page = await response.json() as { events: Event[]; nextCursor: number };
    if (disposed || current !== generation) return;
    entries.value = reset ? page.events : [...entries.value, ...page.events];
    cursor.value = page.nextCursor;
  } catch (e) {
    if (!disposed && current === generation && !(e instanceof Error && e.name === "AbortError")) {
      error.value = "读取审计记录失败：" + describeUserFacingError(e);
    }
  } finally {
    if (!disposed && current === generation) loading.value = false;
  }
}

onMounted(() => void load(true));
onUnmounted(() => {
  disposed = true;
  controller.abort();
});
</script>

<template>
  <IsleCard
    class="audit-panel"
    aria-label="安全操作审计"
    title="安全审计"
    subtitle="保留最近 90 天（最多 20,000 条）关键操作记录，不含密码、令牌或文件内容。"
  >
    <template #icon><ShieldCheck :size="18" aria-hidden="true" /></template>
    <template #actions>
      <div class="audit-toolbar">
        <div v-if="entries.length" class="audit-filter-pills">
          <button type="button" class="audit-filter-btn" :class="{ active: filter === 'all' }" @click="filter = 'all'">
            全部 ({{ entries.length }})
          </button>
          <button type="button" class="audit-filter-btn" :class="{ active: filter === 'issues' }" @click="filter = 'issues'">
            异常与拒绝 ({{ issueCount }})
          </button>
        </div>
        <IsleButton variant="glass" size="sm" :loading="loading" @click="load(true)">
          <template #icon><RefreshCw :size="14" /></template> 刷新
        </IsleButton>
      </div>
    </template>

    <IsleBanner v-if="error" type="error" compact role="alert">
      {{ error }}
      <template #action>
        <IsleButton variant="glass" size="sm" @click="load(true)">重试</IsleButton>
      </template>
    </IsleBanner>
    <p v-if="loading && !entries.length" class="footnote">正在读取操作审计…</p>
    <IsleEmpty
      v-else-if="!filteredEntries.length && !error"
      compact
      :description="entries.length ? '当前筛选条件下暂无异常操作。' : '暂无需要审计的操作。'"
    />
    <div v-else class="audit-list">
      <div v-for="item in filteredEntries" :key="item.id" class="account-row audit-entry">
        <div class="audit-entry-left">
          <span class="audit-entry-icon" :class="item.outcome === 'success' ? 'is-ok' : 'is-warn'">
            <ShieldCheck v-if="item.outcome === 'success'" :size="14" />
            <ShieldAlert v-else :size="14" />
          </span>
          <div>
            <strong>{{ labels[item.action] || item.action }} · {{ actorLabel(item) }}</strong>
            <small>{{ formatDateTime(item.createdAt * 1000) }}<template v-if="item.target"> · {{ item.target }}</template></small>
          </div>
        </div>
        <IsleBadge
          :variant="item.outcome === 'success' ? 'online' : item.outcome === 'denied' ? 'danger' : 'warning'"
          size="sm"
        >
          {{ item.action === "mcp_call_pending" ? "结果待核实" : item.outcome === "success" ? "成功" : item.outcome === "denied" ? "被拒绝" : "失败" }}
        </IsleBadge>
      </div>
    </div>
    <div v-if="cursor" class="gallery-load">
      <IsleButton variant="glass" size="sm" :loading="loading" @click="load(false)">
        {{ loading ? "加载中…" : "查看更多审计记录" }}
      </IsleButton>
    </div>
  </IsleCard>
</template>

<style scoped>
.audit-panel { margin-bottom: 14px; }
.audit-toolbar { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.audit-filter-pills { display: inline-flex; padding: 2px; border-radius: 999px; background: var(--fluid-card-item-fill); border: 1px solid var(--fluid-card-border); gap: 2px; }
.audit-filter-btn { border: 0; background: transparent; color: var(--text-secondary); font-size: 11px; font-weight: 600; padding: 3px 9px; border-radius: 999px; cursor: pointer; }
.audit-filter-btn.active { background: var(--accent-primary); color: #fff; }
.audit-list { display: grid; gap: 0; }
.audit-list .account-row { margin: 0; }
.audit-entry { content-visibility: auto; contain-intrinsic-size: auto 52px; }
.audit-entry-left { display: flex; align-items: center; gap: 9px; min-width: 0; }
.audit-entry-icon { width: 28px; height: 28px; border-radius: 8px; display: grid; place-items: center; flex-shrink: 0; }
.audit-entry-icon.is-ok { background: color-mix(in srgb, var(--accent-primary) 12%, transparent); color: var(--accent-primary); }
.audit-entry-icon.is-warn { background: rgba(245, 158, 11, 0.14); color: #d97706; }
.audit-entry strong { font-size: 12.5px; }
.audit-entry small { display: block; margin-top: 2px; font-size: 11px; color: var(--text-secondary); overflow-wrap: anywhere; }
</style>
