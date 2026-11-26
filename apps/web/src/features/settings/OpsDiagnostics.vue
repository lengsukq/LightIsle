<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from "vue";
import { Activity, Cpu, Download, HardDrive, Network, RefreshCcw, Server } from "lucide-vue-next";
import { apiFetch } from "../../api/apiClient.ts";
import { readApiFailure } from "../../api/apiFailure.ts";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import { TIMINGS_MS } from "../../constants/timings.ts";
import { bytes } from "../overview/useHostTelemetry.ts";
import { formatUnixDateTime } from "../../utils/format.ts";
import AppleSelect from "../../components/ui/AppleSelect.vue";
import IsleBadge from "../../components/ui/IsleBadge.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleCard from "../../components/ui/IsleCard.vue";
import IsleCharts from "../../components/ui/IsleCharts.vue";
import { ISLE_CHART_COLORS } from "../../components/ui/isleChartsMath.ts";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import IsleGroupedList from "../../components/ui/IsleGroupedList.vue";

const limitOptions = [
  { value: 180, label: "最近 3 小时" },
  { value: 720, label: "最近 12 小时" },
  { value: 1440, label: "最近 24 小时" },
  { value: 2880, label: "最近 48 小时" },
];

type Metric = {
  timestamp: number;
  cpuPercent: number | null;
  memoryPercent: number;
  diskPercent: number;
  downloadBps: number | null;
  uploadBps: number | null;
};
type NetworkInterface = { name: string; up: boolean; addresses: string[] };
type Diagnostics = {
  interfaces: NetworkInterface[];
  gatewayIPv4: string;
  defaultInterface: string;
  requestTransport: string;
  observedAt: string;
  tips: string[];
};

const history = ref<Metric[]>([]);
const diagnostics = ref<Diagnostics | null>(null);
const loading = ref(false);
const error = ref("");
const limit = ref(180);

const lastSeen = computed(() =>
  history.value.length ? formatUnixDateTime(history.value[history.value.length - 1].timestamp, "尚未收集") : "尚未收集",
);

const latestSample = computed(() => (history.value.length ? history.value[history.value.length - 1] : null));

function extractSeries(key: "cpuPercent" | "memoryPercent" | "diskPercent"): number[] {
  return history.value
    .map((item) => item[key])
    .filter((v): v is number => v !== null && Number.isFinite(v))
    .map((v) => Math.min(100, Math.max(0, v)));
}

function formatPct(val: number | null | undefined): string {
  if (val === null || val === undefined || !Number.isFinite(val)) return "—";
  return `${Math.round(Math.min(100, Math.max(0, val)))}%`;
}

function seriesPeak(points: number[]): string {
  if (!points.length) return "—";
  return `${Math.round(Math.max(...points))}%`;
}

const cpuPoints = computed(() => extractSeries("cpuPercent"));
const memPoints = computed(() => extractSeries("memoryPercent"));
const diskPoints = computed(() => extractSeries("diskPercent"));

const telemetryCards = computed(() => [
  {
    key: "cpu",
    label: "处理器负载",
    icon: Cpu,
    current: formatPct(latestSample.value?.cpuPercent),
    peak: seriesPeak(cpuPoints.value),
    points: cpuPoints.value,
    color: ISLE_CHART_COLORS.purple,
    ariaLabel: "处理器历史使用率趋势",
  },
  {
    key: "memory",
    label: "内存占用",
    icon: Server,
    current: formatPct(latestSample.value?.memoryPercent),
    peak: seriesPeak(memPoints.value),
    points: memPoints.value,
    color: ISLE_CHART_COLORS.blue,
    ariaLabel: "内存历史使用率趋势",
  },
  {
    key: "disk",
    label: "数据盘占用",
    icon: HardDrive,
    current: formatPct(latestSample.value?.diskPercent),
    peak: seriesPeak(diskPoints.value),
    points: diskPoints.value,
    color: ISLE_CHART_COLORS.amber,
    ariaLabel: "数据盘历史使用率趋势",
  },
]);

let controller = new AbortController();
let disposed = false;

async function load() {
  if (loading.value) return;
  controller.abort();
  controller = new AbortController();
  const { signal } = controller;
  loading.value = true;
  error.value = "";
  try {
    const [a, b] = await Promise.all([
      apiFetch("/api/v2/system/history?limit=" + limit.value, { signal }),
      apiFetch("/api/v2/system/diagnostics", { signal }),
    ]);
    if (!a.ok) throw await readApiFailure(a);
    if (!b.ok) throw await readApiFailure(b);
    const metrics = (await a.json()) as { samples: Metric[] };
    const diag = (await b.json()) as Diagnostics;
    if (disposed || signal.aborted) return;
    diagnostics.value = diag;
    history.value = Array.isArray(metrics.samples) ? metrics.samples : [];
  } catch (e) {
    if (!disposed && !(e instanceof Error && e.name === "AbortError")) {
      error.value = "无法读取本机诊断：" + describeUserFacingError(e);
    }
  } finally {
    if (!disposed) loading.value = false;
  }
}

function exportReport() {
  if (!diagnostics.value) return;
  const report = {
    exportedAt: new Date().toISOString(),
    scope: "本机资源指标",
    history: history.value.map(({ timestamp, cpuPercent, memoryPercent, diskPercent, downloadBps, uploadBps }) => ({
      timestamp,
      cpuPercent,
      memoryPercent,
      diskPercent,
      downloadBps,
      uploadBps,
    })),
  };
  const url = URL.createObjectURL(new Blob([JSON.stringify(report, null, 2)], { type: "application/json" }));
  const a = document.createElement("a");
  a.href = url;
  a.download = "lightisle-diagnostics.json";
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), TIMINGS_MS.BLOB_REVOKE_DELAY);
}

onMounted(() => {
  void load();
});

onUnmounted(() => {
  disposed = true;
  controller.abort();
});
</script>

<template>
  <IsleCard
    class="ops-diagnostics"
    title="资源历史与网络诊断"
    subtitle="本机资源负载趋势与网络出口实时观测（只读）。"
  >
    <template #icon><Activity :size="18" /></template>
    <template #actions>
      <span class="settings-updated-at">最近采样：{{ lastSeen }}</span>
      <AppleSelect v-model="limit" :options="limitOptions" size="sm" aria-label="资源历史时间范围" :disabled="loading" @change="load" />
      <IsleButton
        variant="ghost"
        size="sm"
        :loading="loading"
        aria-label="刷新系统诊断"
        title="刷新系统诊断"
        @click="load"
      >
        <template #icon><RefreshCcw :size="14" /></template>
      </IsleButton>
      <IsleButton variant="glass" size="sm" :disabled="!diagnostics" @click="exportReport">
        <template #icon><Download :size="14" /></template>
        导出诊断
      </IsleButton>
    </template>

    <div class="ops-diag-stack">
      <IsleBanner v-if="error" type="error" compact :message="error">
        <template #action>
          <IsleButton variant="tonal" size="sm" @click="load">重试</IsleButton>
        </template>
      </IsleBanner>

      <p v-if="loading && !history.length" class="footnote" role="status">正在读取历史指标…</p>

      <div class="ops-telemetry-grid">
        <div v-for="card in telemetryCards" :key="card.key" class="ops-metric-card">
          <div class="ops-metric-head">
            <span class="ops-metric-label"><component :is="card.icon" :size="14" /> {{ card.label }}</span>
            <strong class="ops-metric-value">{{ card.current }}</strong>
          </div>
          <IsleCharts
            kind="sparkline"
            :points="card.points"
            :min-bound="0"
            :max-bound="100"
            :spark-height="38"
            :color="card.color"
            :aria-label="card.ariaLabel"
          />
          <div class="ops-metric-foot">
            <span>区间峰值 {{ card.peak }}</span>
            <span>{{ card.points.length }} 个样本</span>
          </div>
        </div>
      </div>

      <IsleBanner
        v-if="history.length <= 1 && !loading"
        type="info"
        compact
        message="历史样本不足两条。保持 Mac App 运行，稍后会形成完整趋势曲线。"
      />

      <div
        v-if="latestSample && (latestSample.downloadBps !== null || latestSample.uploadBps !== null)"
        class="ops-net-throughput"
      >
        <span>当前吞吐观测：</span>
        <strong>下行 {{ latestSample.downloadBps !== null ? bytes(latestSample.downloadBps) + '/s' : '—' }}</strong>
        <strong>上行 {{ latestSample.uploadBps !== null ? bytes(latestSample.uploadBps) + '/s' : '—' }}</strong>
      </div>

      <IsleGroupedList
        v-if="diagnostics"
        title="Mac 本机网络接口"
        :subtitle="'当前请求通道：' + diagnostics.requestTransport"
        variant="item"
        flush
      >
        <template #actions>
          <span class="ops-diag-net-pill">
            <Network :size="12" aria-hidden="true" />
            默认出口 {{ diagnostics.defaultInterface || "未检测到" }}
          </span>
        </template>

        <div class="settings-grouped-rows">
          <div class="account-row ops-diag-row">
            <div>
              <strong>默认网关与出口路由</strong>
              <small class="ops-mono-tabular">
                默认网关：{{ diagnostics.gatewayIPv4 || "未检测到" }} · 默认网卡：{{ diagnostics.defaultInterface || "未检测到" }}
              </small>
            </div>
          </div>

          <div v-for="item in diagnostics.interfaces" :key="item.name" class="account-row ops-diag-row">
            <div>
              <strong class="ops-diag-if-title">
                <span class="ops-mono-tabular">{{ item.name }}</span>
                <IsleBadge :variant="item.up ? 'online' : 'offline'" size="sm" dot>
                  {{ item.up ? "已启用" : "未启用" }}
                </IsleBadge>
              </strong>
              <small class="ops-mono-tabular">
                {{ item.addresses.length ? item.addresses.join("、") : "没有分配非链路本地 IP 地址" }}
              </small>
            </div>
          </div>
        </div>

        <IsleEmpty
          v-if="!diagnostics.interfaces.length"
          compact
          description="没有发现可报告的以太网或网络桥接口。"
        />

        <template v-if="diagnostics.tips.length" #footnote>
          <div class="ops-diag-tips">
            <span v-for="tip in diagnostics.tips" :key="tip">{{ tip }}</span>
          </div>
        </template>
      </IsleGroupedList>
    </div>
  </IsleCard>
</template>

<style scoped>
.ops-diag-stack {
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.ops-diag-stack .footnote {
  margin: 0;
}

.ops-telemetry-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(min(100%, 190px), 1fr));
  gap: 10px;
}

.ops-metric-card {
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding: 11px 13px;
  border-radius: 13px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
  min-width: 0;
}

.ops-metric-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 8px;
}

.ops-metric-label {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  font-size: 12px;
  font-weight: 600;
  color: var(--text-secondary);
}

.ops-metric-value {
  font-size: 16px;
  font-weight: 700;
  color: var(--text-primary);
  font-variant-numeric: tabular-nums;
}

.ops-metric-foot {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  font-size: 11px;
  color: var(--text-tertiary);
  font-variant-numeric: tabular-nums;
}

.ops-net-throughput {
  display: flex;
  align-items: center;
  gap: 12px;
  flex-wrap: wrap;
  font-size: 12px;
  color: var(--text-secondary);
  font-variant-numeric: tabular-nums;
}

.ops-net-throughput strong {
  color: var(--text-primary);
  font-weight: 620;
}

.ops-diag-net-pill {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  padding: 3px 9px;
  border-radius: 999px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
  font-size: 11.5px;
  color: var(--text-secondary);
  font-variant-numeric: tabular-nums;
}

.ops-diag-row > div {
  min-width: 0;
  flex: 1;
  overflow-wrap: anywhere;
}

.ops-diag-if-title {
  display: flex;
  align-items: center;
  gap: 7px;
  flex-wrap: wrap;
}

.ops-mono-tabular {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-variant-numeric: tabular-nums;
}

.ops-diag-tips {
  display: grid;
  gap: 3px;
}
</style>
