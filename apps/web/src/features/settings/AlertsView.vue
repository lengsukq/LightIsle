<script setup lang="ts">
import { onMounted, onUnmounted, ref } from "vue";
import { AlertTriangle, CheckCircle2, RefreshCw } from "lucide-vue-next";
import IsleCard from "../../components/ui/IsleCard.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleBadge from "../../components/ui/IsleBadge.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import { createLatestRequestGate } from "../../api/latestRequestGate.ts";
import { apiFetch } from "../../api/apiClient.ts";
import { readApiFailure } from "../../api/apiFailure.ts";
import { rootApiPath } from "../../api/rootApi.ts";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import { formatUnixDateTime } from "../../utils/format.ts";
import { TIMINGS_MS } from "../../constants/timings.ts";

type Alert = { code: string; severity: "warning" | "critical"; message: string; active: boolean; acknowledged: boolean; firstSeen: number; lastSeen: number };
const props = defineProps<{ rootId?: string; rootGeneration?: number }>();
const alerts = ref<Alert[]>([]);
const loading = ref(false), error = ref(""), history = ref(false);
let timer: number | undefined, disposed = false;
const alertRequests = createLatestRequestGate();

function apiPath(path: string) { return rootApiPath(props.rootId, path); }

async function load(force = false) {
  if (disposed || loading.value && !force) return;
  const request = alertRequests.begin();
  const rootID = props.rootId, rootGeneration = props.rootGeneration ?? 0;
  loading.value = true; error.value = "";
  try {
    const headers = new Headers();
    if (rootID) headers.set("X-LightIsle-Root-Generation", String(rootGeneration));
    const response = await apiFetch(apiPath("/api/v2/alerts") + (history.value ? "?history=1" : ""), { signal: request.signal, headers });
    if (!response.ok) {
      const failure = await readApiFailure(response);
      if (rootID && response.status === 409 && failure.code === "root_generation_changed") window.dispatchEvent(new Event("lightisle-root-generation-changed"));
      throw failure;
    }
    const result = await response.json() as { alerts: Alert[] };
    if (!disposed && request.isCurrent() && rootID === props.rootId && rootGeneration === (props.rootGeneration ?? 0)) alerts.value = result.alerts;
  } catch (e) {
    if (!disposed && request.isCurrent() && !(e instanceof Error && e.name === "AbortError")) error.value = "无法获取异常通知：" + describeUserFacingError(e);
  } finally {
    if (request.isCurrent()) loading.value = false;
  }
}

function toggleHistory() { history.value = !history.value; void load(true); }
onMounted(() => { disposed = false; void load(); timer = window.setInterval(() => { if (!document.hidden) void load(); }, TIMINGS_MS.ALERTS_POLL); });
onUnmounted(() => { disposed = true; if (timer) clearInterval(timer); alertRequests.cancel(); });
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
        <IsleButton variant="glass" size="sm" @click="toggleHistory">
          {{ history ? "仅看未恢复" : "查看历史" }}
        </IsleButton>
        <IsleButton variant="glass" size="sm" :loading="loading" @click="load()">
          <template #icon><RefreshCw :size="14" /></template>
          刷新
        </IsleButton>
      </div>
    </template>

    <div class="alert-body">
      <IsleBanner v-if="error" type="error" compact role="alert">{{ error }}</IsleBanner>
      <IsleEmpty v-if="!alerts.length && !loading && !error" compact :description="'目前没有' + (history ? '历史' : '未恢复的') + '异常记录。'" />
      <div v-if="alerts.length" class="alert-group-list">
        <div v-for="alert in alerts" :key="alert.code" class="account-row alert-item">
          <div>
            <strong>
              <IsleBadge
                :variant="alert.severity === 'critical' ? 'danger' : alert.active ? 'warning' : 'online'"
                size="sm"
              >
                {{ alert.severity === 'critical' ? '严重' : alert.active ? '警告' : '恢复' }}
              </IsleBadge>
              <AlertTriangle v-if="alert.active" :size="14" aria-hidden="true" />
              <CheckCircle2 v-else :size="14" aria-hidden="true" />
              {{ alert.message }}
            </strong>
            <small>{{ alert.active ? "待处理" : "已恢复" }} · 发现于 {{ formatUnixDateTime(alert.firstSeen, "时间未知") }}</small>
          </div>
        </div>
      </div>
    </div>
  </IsleCard>
</template>

<style scoped>
.alert-body {
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.alert-group-list {
  border: 1px solid var(--fluid-card-border);
  border-radius: 12px;
  background: var(--fluid-card-item-fill);
  overflow: hidden;
}
.alert-group-list .account-row {
  margin: 0;
  border: 0;
  border-bottom: 1px solid var(--fluid-divider, var(--fluid-card-border));
  border-radius: 0;
  background: transparent;
  box-shadow: none;
  padding: 9px 13px;
}
.alert-group-list .account-row:last-child {
  border-bottom: 0;
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
.alert-actions {
  display: flex;
  gap: 6px;
  align-items: center;
  flex-wrap: wrap;
}
</style>
