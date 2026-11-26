<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from "vue";
import { AlertTriangle, CheckCircle2, RefreshCw } from "lucide-vue-next";
import IsleBadge from "../../components/ui/IsleBadge.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleCard from "../../components/ui/IsleCard.vue";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import IsleGroupedList from "../../components/ui/IsleGroupedList.vue";
import { createLatestRequestGate } from "../../api/latestRequestGate.ts";
import { apiFetch } from "../../api/apiClient.ts";
import { readApiFailure } from "../../api/apiFailure.ts";
import { rootApiPath } from "../../api/rootApi.ts";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import { TIMINGS_MS } from "../../constants/timings.ts";
import { formatDateTime } from "../../utils/dateTimeFormat.ts";
import { formatUnixDateTime } from "../../utils/format.ts";

type Alert = {
  code: string;
  severity: "warning" | "critical";
  message: string;
  active: boolean;
  acknowledged: boolean;
  firstSeen: number;
  lastSeen: number;
};

const props = defineProps<{ rootId?: string; rootGeneration?: number }>();
const alerts = ref<Alert[]>([]);
const loading = ref(false);
const error = ref("");
const history = ref(false);
const lastUpdatedAt = ref(0);
let timer: number | undefined;
let disposed = false;
const alertRequests = createLatestRequestGate();

const updatedLabel = computed(() =>
  lastUpdatedAt.value ? "更新于 " + formatDateTime(lastUpdatedAt.value).replace(/^.*?\s/, "") : "",
);

function apiPath(path: string) {
  return rootApiPath(props.rootId, path);
}

async function load(force = false) {
  if (disposed || (loading.value && !force)) return;
  const request = alertRequests.begin();
  const rootID = props.rootId;
  const rootGeneration = props.rootGeneration ?? 0;
  loading.value = true;
  error.value = "";
  try {
    const headers = new Headers();
    if (rootID) headers.set("X-LightIsle-Root-Generation", String(rootGeneration));
    const response = await apiFetch(apiPath("/api/v2/alerts") + (history.value ? "?history=1" : ""), {
      signal: request.signal,
      headers,
    });
    if (!response.ok) {
      const failure = await readApiFailure(response);
      if (rootID && response.status === 409 && failure.code === "root_generation_changed") {
        window.dispatchEvent(new Event("lightisle-root-generation-changed"));
      }
      throw failure;
    }
    const result = (await response.json()) as { alerts: Alert[] };
    if (!disposed && request.isCurrent() && rootID === props.rootId && rootGeneration === (props.rootGeneration ?? 0)) {
      alerts.value = result.alerts;
      lastUpdatedAt.value = Date.now();
    }
  } catch (e) {
    if (!disposed && request.isCurrent() && !(e instanceof Error && e.name === "AbortError")) {
      error.value = "无法获取异常通知：" + describeUserFacingError(e);
    }
  } finally {
    if (request.isCurrent()) loading.value = false;
  }
}

function toggleHistory() {
  history.value = !history.value;
  void load(true);
}

watch(
  () => [props.rootId, props.rootGeneration],
  () => {
    void load(true);
  },
);

onMounted(() => {
  disposed = false;
  void load();
  timer = window.setInterval(() => {
    if (!document.hidden) void load();
  }, TIMINGS_MS.ALERTS_POLL);
});

onUnmounted(() => {
  disposed = true;
  if (timer) clearInterval(timer);
  alertRequests.cancel();
});
</script>

<template>
  <IsleCard
    class="alert-center"
    aria-label="运行状态异常"
    title="运行异常提醒"
    subtitle="集中展示存储离线、空间不足、备份与媒体扫描异常；问题处理完成后会自动恢复。"
  >
    <template #icon><AlertTriangle :size="18" aria-hidden="true" /></template>
    <template #actions>
      <div class="alert-actions">
        <span v-if="updatedLabel" class="settings-updated-at">{{ updatedLabel }}</span>
        <IsleButton variant="glass" size="sm" @click="toggleHistory">
          {{ history ? "仅看未恢复" : "查看历史" }}
        </IsleButton>
        <IsleButton
          variant="ghost"
          size="sm"
          :loading="loading"
          aria-label="刷新异常提醒"
          title="刷新异常提醒"
          @click="load()"
        >
          <template #icon><RefreshCw :size="14" /></template>
        </IsleButton>
      </div>
    </template>

    <div class="alert-body">
      <IsleBanner v-if="error" type="error" compact role="alert">{{ error }}</IsleBanner>
      <p v-if="loading && !alerts.length && !error" class="footnote" role="status">正在读取运行异常提醒…</p>
      <IsleEmpty
        v-else-if="!alerts.length && !error"
        compact
        :description="'目前没有' + (history ? '历史' : '未恢复的') + '异常记录。'"
      />
      <IsleGroupedList v-if="alerts.length" variant="item" flush>
        <TransitionGroup name="isle-list" tag="div" class="settings-grouped-rows">
          <div v-for="alert in alerts" :key="alert.code" class="account-row alert-item">
            <div>
              <strong>
                <IsleBadge
                  :variant="alert.severity === 'critical' ? 'danger' : alert.active ? 'warning' : 'online'"
                  size="sm"
                >
                  {{ alert.severity === "critical" ? "严重" : alert.active ? "警告" : "恢复" }}
                </IsleBadge>
                <AlertTriangle v-if="alert.active" :size="14" aria-hidden="true" />
                <CheckCircle2 v-else :size="14" aria-hidden="true" />
                <span>{{ alert.message }}</span>
              </strong>
              <small class="alert-tabular">
                {{ alert.active ? "待处理" : "已恢复" }} · 发现于 {{ formatUnixDateTime(alert.firstSeen, "时间未知") }}
              </small>
            </div>
          </div>
        </TransitionGroup>
      </IsleGroupedList>
    </div>
  </IsleCard>
</template>

<style scoped>
.alert-body {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.alert-body .footnote {
  margin: 0;
}

.alert-item > div {
  min-width: 0;
  flex: 1;
  overflow-wrap: anywhere;
}

.alert-item strong {
  display: flex;
  align-items: center;
  gap: 6px;
  font-size: 12.5px;
  flex-wrap: wrap;
}

.alert-item small {
  display: block;
  margin-top: 3px;
  color: var(--text-secondary);
  font-size: 11px;
}

.alert-tabular {
  font-variant-numeric: tabular-nums;
}

.alert-actions {
  display: flex;
  gap: 6px;
  align-items: center;
  flex-wrap: wrap;
}
</style>
