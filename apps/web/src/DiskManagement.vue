<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { HardDrive, RefreshCcw, ShieldCheck, AlertTriangle, Pencil, PlugZap, ArrowUpRight, Activity, HeartPulse, ChevronDown } from "lucide-vue-next";
import { requestConfirm } from "./useConfirmDialog.ts";
import { describeUserFacingError } from "./userFacingError.ts";
import { apiErrorFromResponse } from "./apiFailure.ts";
import IsleCard from "./IsleCard.vue";
import IsleButton from "./IsleButton.vue";
import IsleBanner from "./IsleBanner.vue";
import IsleBadge from "./IsleBadge.vue";
import IsleEmpty from "./IsleEmpty.vue";
import IsleModal from "./IsleModal.vue";
import IsleCharts from "./IsleCharts.vue";
import { ISLE_CHART_COLORS } from "./isleChartsMath.ts";
import {
  type Disk,
  type HealthSample,
  type SmartReport,
  type Volume,
  DISK_ERROR_MESSAGES as errors,
  describeSmartReason as smartReason,
  formatDiskSize as formatSize,
  diskUsedPercent as pct,
  isSystemDiskPartition as isSystemPartition,
  isSystemVolume,
  healthRiskLabel as healthLabel,
  diskUsageSegments,
} from "./diskManagementSupport.ts";

const disks = ref<Disk[]>([]);
const volumes = ref<Volume[]>([]);
const smart = ref<Record<string, SmartReport>>({});
const healthHistory = ref<Record<string, HealthSample[]>>({});
const healthRisk = ref<Record<string, string>>({});
const healthNote = ref<Record<string, string>>({});
const smartOpen = ref<Record<string, boolean>>({});
const smartLoading = ref("");
const loading = ref(false);
const pending = ref("");
const error = ref("");
const notice = ref("");
const renameTarget = ref<Disk | null>(null);
const renameName = ref("");
const renameError = ref("");
const showSystemPartitions = ref(false);
const primaryDisks = computed(() => disks.value.filter((d) => !isSystemPartition(d)));
const systemPartitions = computed(() => disks.value.filter((d) => isSystemPartition(d)));
const systemDiskMounts = computed(() => new Set(systemPartitions.value.map((d) => d.mount).filter(Boolean)));
const primaryVolumes = computed(() => volumes.value.filter((v) => !isSystemVolume(v, systemDiskMounts.value)));
const systemVolumes = computed(() => volumes.value.filter((v) => isSystemVolume(v, systemDiskMounts.value)));
const visibleVolumes = computed(() => (showSystemPartitions.value ? volumes.value : primaryVolumes.value));
type DiskGridEntry =
  | { kind: "disk"; key: string; disk: Disk; system: boolean }
  | { kind: "toggle"; key: string };
const diskGridEntries = computed<DiskGridEntry[]>(() => {
  const entries: DiskGridEntry[] = primaryDisks.value.map((disk) => ({
    kind: "disk",
    key: "disk:" + disk.id,
    disk,
    system: false,
  }));
  if (systemPartitions.value.length > 0) {
    entries.push({ kind: "toggle", key: "system-toggle" });
    if (showSystemPartitions.value) {
      for (const disk of systemPartitions.value) {
        entries.push({ kind: "disk", key: "sys:" + disk.id, disk, system: true });
      }
    }
  }
  return entries;
});
const count = computed(() => disks.value.length);

async function jsonResponse(response: Response) {
  const value = await response.json().catch(() => ({})) as { error?: string; disks?: Disk[] };
  if (!response.ok) {
    const failure = apiErrorFromResponse(response, value);
    throw new Error(errors[value.error ?? ""] ?? describeUserFacingError(failure));
  }
  return value;
}

async function refresh() {
  if (loading.value || pending.value) return;
  loading.value = true; error.value = "";
  try {
    const data = await jsonResponse(await fetch("/api/v2/admin/disks", { credentials: "same-origin", cache: "no-store" }));
    disks.value = data.disks ?? [];
    const system = await fetch("/api/v2/system", { credentials: "same-origin", cache: "no-store" });
    if (system.ok) volumes.value = ((await system.json()) as { volumes?: Volume[] }).volumes ?? [];
  } catch (e) { error.value = describeUserFacingError(e); }
  finally { loading.value = false; }
}

async function toggleSmart(d: Disk) {
  smartOpen.value[d.id] = !smartOpen.value[d.id];
  if (!smartOpen.value[d.id] || smart.value[d.id]) return;
  await refreshSmart(d);
}

async function refreshSmart(d: Disk) {
  if (smartLoading.value) return;
  smartLoading.value = d.id;
  healthNote.value[d.id] = "";
  try {
    const response = await fetch("/api/v2/admin/disks/" + d.id + "/smart", { credentials: "same-origin", cache: "no-store" });
    const value = await response.json().catch(() => ({})) as { report?: SmartReport; risk?: string; historyRecorded?: boolean };
    if (!response.ok) throw new Error("smart_failed");
    if (value.report) smart.value[d.id] = value.report;
    healthRisk.value[d.id] = value.risk ?? "unknown";
    if (!value.historyRecorded) healthNote.value[d.id] = "该设备没有可持久关联的历史记录，或数据库暂不可用。";
    const historyResponse = await fetch("/api/v2/admin/disks/" + d.id + "/smart/history", { credentials: "same-origin", cache: "no-store" });
    if (historyResponse.ok) {
      const history = await historyResponse.json() as { samples?: HealthSample[] };
      healthHistory.value[d.id] = Array.isArray(history.samples) ? history.samples : [];
    } else { healthNote.value[d.id] = "历史读取不可用。当前 SMART 状态仍可查看。"; }
  } catch {
    smart.value[d.id] = { device: d.id, source: "none", reason: "smartctl_query_failed" };
    healthRisk.value[d.id] = "unknown";
    healthNote.value[d.id] = "未能读取健康报告。请检查磁盘连接或 smartctl 权限。";
  }
  finally { if (smartLoading.value === d.id) smartLoading.value = ""; }
}

function temperatureValues(id: string): number[] {
  return (healthHistory.value[id] ?? [])
    .map((s) => s.temperature)
    .filter((t): t is number => typeof t === "number" && Number.isFinite(t));
}

function openRenameModal(d: Disk) {
  if (pending.value || !d.external || !d.identity || d.identity.length !== 64) return;
  renameTarget.value = d;
  renameName.value = d.name;
  renameError.value = "";
}

function closeRenameModal() {
  if (pending.value) return;
  renameTarget.value = null;
  renameName.value = "";
  renameError.value = "";
}

async function submitRename() {
  const d = renameTarget.value;
  if (!d || pending.value || !d.external || !d.identity || d.identity.length !== 64) return;
  const name = renameName.value.trim();
  if (!name) {
    renameError.value = "请输入新的磁盘显示名称。";
    return;
  }
  if (name === d.name) {
    closeRenameModal();
    return;
  }
  pending.value = d.id;
  renameError.value = "";
  error.value = "";
  notice.value = "";
  try {
    const value = await jsonResponse(await fetch("/api/v2/admin/disks/actions", {
      method: "POST", credentials: "same-origin",
      headers: { "Content-Type": "application/json", "X-LightIsle-Request": "1" },
      body: JSON.stringify({ action: "rename", id: d.id, identity: d.identity, name })
    }));
    disks.value = value.disks ?? [];
    notice.value = "操作已提交并由 macOS 返回成功；请核对最新状态。";
    renameTarget.value = null;
    renameName.value = "";
  } catch (e) {
    renameError.value = describeUserFacingError(e);
  } finally {
    pending.value = "";
  }
}

async function act(d: Disk, action: "mount" | "eject") {
  if (pending.value || !d.external || !d.identity || d.identity.length !== 64) return;
  if (!(await requestConfirm(
    action === "eject"
      ? "确认安全弹出「" + d.name + "」？请先完成文件上传与拷贝，NAS 存储卷会受到保护。"
      : "确认挂载「" + d.name + "」？macOS 会验证该卷并挂载。"
  ))) return;
  pending.value = d.id; error.value = ""; notice.value = "";
  try {
    const value = await jsonResponse(await fetch("/api/v2/admin/disks/actions", {
      method: "POST", credentials: "same-origin",
      headers: { "Content-Type": "application/json", "X-LightIsle-Request": "1" },
      body: JSON.stringify({ action, id: d.id, identity: d.identity, name: "" })
    }));
    disks.value = value.disks ?? [];
    notice.value = "操作已提交并由 macOS 返回成功；请核对最新状态。";
  } catch (e) { error.value = describeUserFacingError(e); }
  finally { pending.value = ""; }
}

onMounted(() => { void refresh(); });
</script>

<template>
  <IsleCard
    class="disk-admin-panel"
    title="硬盘基础管理"
    :subtitle="`Mac 外置磁盘 · ${count} 个设备 · 由 Core 校验物理身份后执行受控挂载、重命名或安全弹出`"
  >
    <template #icon><HardDrive :size="18" /></template>
    <template #actions>
      <IsleButton variant="glass" size="sm" :loading="loading" :disabled="!!pending" @click="refresh">
        <template #icon><RefreshCcw :size="15" /></template>
        {{ loading ? "检测中…" : "刷新" }}
      </IsleButton>
    </template>

    <div class="disk-body">
      <IsleBanner v-if="error" type="error" compact :message="error" />
      <IsleBanner v-if="notice" type="success" compact :message="notice" />
      <IsleEmpty v-if="!count && !loading" compact :icon="HardDrive" title="未发现外置磁盘" description="没有发现可管理的外置磁盘。请连接硬盘并刷新。" />

      <div v-if="count" class="disk-admin-grid">
        <template v-for="entry in diskGridEntries" :key="entry.key">
          <div v-if="entry.kind === 'toggle'" class="disk-system-toggle-row">
            <button
              type="button"
              class="disk-system-toggle"
              :aria-expanded="showSystemPartitions"
              @click="showSystemPartitions = !showSystemPartitions"
            >
              <ChevronDown :size="14" class="disk-system-toggle-chevron" />
              <span>{{ showSystemPartitions ? "隐藏" : "显示" }}系统引导分区与磁盘映像 ({{ systemPartitions.length }})</span>
            </button>
            <span v-if="!primaryDisks.length" class="disk-system-hint">当前未检测到独立外置数据磁盘</span>
          </div>
          <div v-else class="disk-admin-item" :class="{ 'is-system': entry.system }">
            <div class="disk-admin-main">
              <span class="disk-admin-icon"><HardDrive :size="20" /></span>
              <div class="disk-admin-name">
                <strong>{{ entry.disk.name }}</strong>
                <span>{{ entry.disk.id }} · {{ entry.disk.filesystem || "格式未知" }} · {{ entry.disk.protocol || "连接方式未知" }}</span>
                <small>{{ entry.disk.mount || "尚未挂载" }} · {{ entry.disk.readOnly ? "只读" : "可写" }} · SMART：{{ entry.disk.smart || "未知/不支持" }}</small>
              </div>
              <IsleBadge :variant="entry.disk.mounted ? 'online' : 'offline'" dot size="sm">{{ entry.disk.mounted ? "已挂载" : "未挂载" }}</IsleBadge>
            </div>

            <div v-if="entry.disk.total > 0" class="disk-admin-capacity-chart">
              <IsleCharts
                kind="donut"
                :size="50"
                :stroke-width="5"
                :percent="entry.disk.mounted ? pct(entry.disk) : null"
                :color="pct(entry.disk) >= 90 ? ISLE_CHART_COLORS.rose : ISLE_CHART_COLORS.blue"
                :aria-label="`${entry.disk.name} 容量使用率`"
              />
              <div class="disk-admin-capacity-bar">
                <template v-if="entry.disk.mounted">
                  <IsleCharts
                    kind="segmented"
                    :segments="diskUsageSegments(entry.disk.total, entry.disk.free)"
                    :total="entry.disk.total"
                    :bar-height="9"
                    compact-legend
                    :aria-label="`${entry.disk.name} 已用与可用空间比例`"
                  />
                  <span class="disk-capacity-caption">总计 {{ formatSize(entry.disk.total) }}</span>
                </template>
                <div v-else class="disk-unmounted-bar" :aria-label="`${entry.disk.name} 未挂载容量信息`">
                  <div class="disk-unmounted-track" aria-hidden="true" />
                  <span class="disk-capacity-caption">分区容量 {{ formatSize(entry.disk.total) }} · 未挂载（挂载后读取可用空间）</span>
                </div>
              </div>
            </div>

            <div class="disk-admin-actions">
              <IsleButton variant="tonal" size="sm" :disabled="smartLoading === entry.disk.id" @click="toggleSmart(entry.disk)">
                <template #icon><HeartPulse :size="14" /></template>
                {{ smartOpen[entry.disk.id] ? "收起健康详情" : "健康详情" }}{{ smartLoading === entry.disk.id ? "…" : "" }}
              </IsleButton>
              <template v-if="!entry.disk.identity">
                <span class="disk-admin-warning"><AlertTriangle :size="14" /> 设备唯一身份不可验证，禁止修改</span>
              </template>
              <template v-else>
                <IsleButton v-if="entry.disk.mounted" variant="glass" size="sm" :disabled="!!pending" @click="openRenameModal(entry.disk)">
                  <template #icon><Pencil :size="14" /></template>重命名
                </IsleButton>
                <IsleButton v-if="entry.disk.mounted" variant="glass" size="sm" :disabled="!!pending" @click="act(entry.disk, 'eject')">
                  <template #icon><ArrowUpRight :size="14" /></template>安全弹出
                </IsleButton>
                <IsleButton v-else variant="primary" size="sm" :disabled="!!pending" @click="act(entry.disk, 'mount')">
                  <template #icon><PlugZap :size="14" /></template>挂载
                </IsleButton>
                <span v-if="pending === entry.disk.id" class="disk-admin-pending">macOS 正在处理…</span>
              </template>
            </div>

            <div v-if="smartOpen[entry.disk.id]" class="disk-admin-smart">
              <div class="disk-admin-health-title">
                <strong :class="{ 'smart-bad': healthRisk[entry.disk.id] === 'critical', 'smart-warning': healthRisk[entry.disk.id] === 'warning' }">
                  {{ healthLabel(healthRisk[entry.disk.id]) }}
                </strong>
                <IsleButton variant="glass" size="sm" :disabled="!!smartLoading" @click="refreshSmart(entry.disk)">
                  重新读取 SMART
                </IsleButton>
              </div>
              <template v-if="smart[entry.disk.id] && smart[entry.disk.id].source === 'smartctl'">
                <div class="disk-admin-smart-grid">
                  <span>型号</span><strong>{{ smart[entry.disk.id].model || "未知" }}</strong>
                  <span>序列号</span><strong>{{ smart[entry.disk.id].serial || "未知" }}</strong>
                  <span>固件</span><strong>{{ smart[entry.disk.id].firmware || "未知" }}</strong>
                  <span>温度</span><strong>{{ smart[entry.disk.id].temperature != null ? smart[entry.disk.id].temperature + " °C" : "—" }}</strong>
                  <span>SMART 结论</span>
                  <strong :class="{ 'smart-bad': smart[entry.disk.id].passed === false, 'smart-good': smart[entry.disk.id].passed === true }">
                    {{ smart[entry.disk.id].passed === true ? "健康（已通过）" : smart[entry.disk.id].passed === false ? "警告：SMART 报告异常" : "未报告" }}
                  </strong>
                  <span>通电时长</span><strong>{{ smart[entry.disk.id].powerOnHours != null ? smart[entry.disk.id].powerOnHours + " 小时" : "—" }}</strong>
                  <span>已用寿命</span><strong>{{ smart[entry.disk.id].lifeUsed != null ? smart[entry.disk.id].lifeUsed + "%" : "—" }}</strong>
                </div>
              </template>
              <p v-else class="disk-admin-smart-reason"><AlertTriangle :size="14" />{{ smartReason(smart[entry.disk.id]) }}</p>
              <small>macOS 基础 SMART 状态（diskutil）：{{ entry.disk.smart || "未知/不支持" }}</small>
              <p v-if="healthNote[entry.disk.id]" class="disk-admin-smart-reason">{{ healthNote[entry.disk.id] }}</p>
              <div class="disk-health-history">
                <strong>按需健康历史（最近 30 天）</strong>
                <small>仅在手动读取 SMART 时记录。并非后台连续监控；相同 BSD 磁盘号不代表同一块硬盘。</small>
                <template v-if="(healthHistory[entry.disk.id] ?? []).length">
                  <IsleCharts
                    v-if="temperatureValues(entry.disk.id).length"
                    kind="sparkline"
                    :points="temperatureValues(entry.disk.id)"
                    :spark-height="44"
                    :color="ISLE_CHART_COLORS.amber"
                    aria-label="历史温度变化曲线"
                  />
                  <div v-for="(item, i) in [...healthHistory[entry.disk.id]].reverse().slice(0, 4)" :key="i" class="disk-health-item">
                    <span>{{ new Date(item.timestamp * 1000).toLocaleString() }}</span>
                    <span>{{ item.temperature != null ? item.temperature + " °C" : "温度未知" }} · {{ healthLabel(item.risk) }}</span>
                  </div>
                </template>
                <small v-else>尚无历史样本，点击读取后才会记录；硬盘不支持 SMART 时也保留未知状态。</small>
              </div>
            </div>
          </div>
        </template>
      </div>

      <div v-if="volumes.length" class="disk-admin-volumes">
        <div class="disk-volumes-head">
          <h4><Activity :size="15" /> 存储卷概览</h4>
          <button
            v-if="systemVolumes.length && !systemPartitions.length"
            type="button"
            class="disk-system-toggle"
            :aria-expanded="showSystemPartitions"
            @click="showSystemPartitions = !showSystemPartitions"
          >
            <ChevronDown :size="14" class="disk-system-toggle-chevron" />
            <span>{{ showSystemPartitions ? "隐藏" : "显示" }}系统与映像卷 ({{ systemVolumes.length }})</span>
          </button>
        </div>
        <div v-if="!visibleVolumes.length" class="disk-system-hint">当前仅检测到系统恢复卷或临时磁盘映像（已默认折叠）。</div>
        <div v-for="v in visibleVolumes" :key="v.mount" class="disk-admin-volume" :class="{ 'is-system': isSystemVolume(v, systemDiskMounts) }">
          <div class="disk-admin-volume-main">
            <strong>{{ v.name }}</strong>
            <span>{{ v.mount }} · {{ v.filesystem || "未知格式" }} · {{ v.readOnly ? "只读" : "可写" }}</span>
          </div>
          <div v-if="v.total > 0" class="disk-admin-volume-capacity">
            <IsleCharts
              kind="segmented"
              :segments="diskUsageSegments(v.total, v.free)"
              :total="v.total"
              :bar-height="8"
              compact-legend
              :aria-label="`${v.name} 存储卷空间比例`"
            />
          </div>
        </div>
      </div>
    </div>

    <template #footer>
      <div class="disk-admin-footer">
        <ShieldCheck :size="15" />
        <span>SMART 不支持读取并不等于健康。格式化为 APFS 或 exFAT 请在 Mac 的「磁盘工具」中操作，并先备份原文件。</span>
      </div>
    </template>
  </IsleCard>

  <IsleModal
    :open="Boolean(renameTarget)"
    :title="renameTarget ? '重命名磁盘「' + renameTarget.name + '」' : '重命名磁盘'"
    description="此操作仅改变 macOS 卷显示名称，不会自动移动或修改原有文件。"
    size="sm"
    :close-on-backdrop="!pending"
    :close-on-esc="!pending"
    :show-close="!pending"
    @close="closeRenameModal"
  >
    <template #icon><Pencil :size="18" /></template>
    <IsleBanner v-if="renameError" type="error" compact :message="renameError" style="margin-bottom: 12px" />
    <form id="disk-rename-form" class="disk-rename-form" @submit.prevent="submitRename">
      <label>
        <span>新卷显示名称</span>
        <input
          v-model="renameName"
          type="text"
          maxlength="128"
          required
          autofocus
          :disabled="!!pending"
          placeholder="输入新磁盘名称"
        />
      </label>
    </form>
    <template #footer>
      <div style="display:flex;justify-content:flex-end;gap:10px;width:100%">
        <IsleButton variant="glass" :disabled="!!pending" @click="closeRenameModal">取消</IsleButton>
        <IsleButton type="submit" form="disk-rename-form" variant="primary" :loading="!!pending">确认重命名</IsleButton>
      </div>
    </template>
  </IsleModal>
</template>

<style scoped>
.disk-body {
  display: flex;
  flex-direction: column;
  gap: 12px;
}
.disk-admin-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(min(100%, 340px), 1fr));
  gap: 12px;
  align-items: start;
}
.disk-system-toggle-row {
  grid-column: 1 / -1;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  flex-wrap: wrap;
  padding-top: 2px;
}
.disk-system-toggle {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 6px 13px;
  border-radius: 999px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-fill);
  color: var(--text-secondary);
  font: inherit;
  font-size: 12px;
  font-weight: 600;
  cursor: pointer;
  transition: background var(--motion-fast) ease, color var(--motion-fast) ease, border-color var(--motion-fast) ease;
}
.disk-system-toggle:hover {
  color: var(--text-primary);
  background: var(--fluid-card-hover);
  border-color: color-mix(in srgb, var(--accent-primary) 38%, var(--fluid-card-border));
}
.disk-system-toggle-chevron {
  transition: transform var(--motion-fast) ease;
}
.disk-system-toggle[aria-expanded="true"] .disk-system-toggle-chevron {
  transform: rotate(180deg);
}
.disk-system-hint {
  font-size: 12px;
  color: var(--text-tertiary);
}
.disk-admin-item {
  padding: 16px 18px;
  border-radius: 18px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
  box-shadow: var(--fluid-item-card-shadow);
  min-width: 0;
}
.disk-admin-item.is-system {
  opacity: 0.9;
}
.disk-admin-main {
  display: flex;
  align-items: center;
  gap: 12px;
}
.disk-admin-icon {
  width: 42px;
  height: 42px;
  border-radius: 14px;
  background: color-mix(in srgb, var(--accent-primary) 10%, transparent);
  color: var(--accent-primary);
  display: grid;
  place-items: center;
  flex: none;
}
.disk-admin-name {
  display: grid;
  gap: 3px;
  min-width: 0;
  flex: 1;
}
.disk-admin-name strong {
  font-size: 14px;
  color: var(--text-primary);
}
.disk-admin-name span,
.disk-admin-name small {
  color: var(--text-secondary);
  font-size: 11.5px;
  overflow-wrap: anywhere;
}
.disk-admin-capacity {
  display: flex;
  align-items: center;
  gap: 12px;
  margin-top: 13px;
}
.disk-admin-meter {
  height: 6px;
  flex: 1;
  min-width: 60px;
  border-radius: 8px;
  background: var(--stroke-subtle);
  overflow: hidden;
}
.disk-admin-meter > div {
  height: 100%;
  border-radius: inherit;
  background: var(--accent-primary);
}
.disk-admin-capacity span {
  font-size: 11.5px;
  color: var(--text-secondary);
}
.disk-admin-actions {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
  margin-top: 14px;
}
.disk-admin-warning,
.disk-admin-pending {
  font-size: 11.5px;
  color: var(--text-secondary);
  display: flex;
  gap: 6px;
  align-items: center;
}
.disk-admin-footer {
  display: flex;
  gap: 8px;
  align-items: center;
  width: 100%;
  font-size: 12px;
  line-height: 1.5;
  color: var(--text-secondary);
}
.disk-admin-footer svg {
  flex: none;
  color: var(--accent-primary);
}
.disk-admin-smart {
  margin-top: 12px;
  padding: 14px 16px;
  border-radius: 14px;
  background: var(--fluid-card-fill);
  border: 1px solid var(--fluid-card-border);
  display: grid;
  gap: 10px;
}
.disk-admin-smart-grid {
  display: grid;
  grid-template-columns: auto 1fr;
  gap: 6px 16px;
  font-size: 12px;
}
.disk-admin-smart-grid span {
  color: var(--text-secondary);
}
.disk-admin-smart-grid strong {
  color: var(--text-primary);
  font-weight: 600;
  overflow-wrap: anywhere;
}
.disk-admin-smart-grid .smart-good {
  color: var(--accent-primary);
}
.disk-admin-smart-grid .smart-bad {
  color: var(--danger, #d94f4f);
}
.disk-admin-smart-reason {
  margin: 0;
  display: flex;
  gap: 7px;
  align-items: flex-start;
  font-size: 12px;
  line-height: 1.6;
  color: var(--text-secondary);
}
.disk-admin-smart small {
  font-size: 11px;
  color: var(--text-secondary);
}
.disk-admin-health-title {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 12px;
  flex-wrap: wrap;
}
.disk-admin-health-title strong {
  font-size: 12.5px;
  font-weight: 650;
}
.disk-admin-health-title .smart-warning {
  color: #b87717;
}
.disk-admin-health-title .smart-bad {
  color: var(--danger, #d94f4f);
}
.disk-health-history {
  display: grid;
  gap: 7px;
  margin-top: 6px;
  border-top: 1px solid var(--stroke-subtle);
  padding-top: 12px;
}
.disk-health-history > strong {
  font-size: 12px;
}
.disk-health-history svg {
  width: 100%;
  max-height: 116px;
  background: var(--surface-base);
  border-radius: 10px;
}
.disk-health-item {
  display: flex;
  justify-content: space-between;
  gap: 10px;
  flex-wrap: wrap;
  font-size: 11px;
  color: var(--text-secondary);
}
.disk-admin-volumes {
  display: grid;
  gap: 6px;
  margin-top: 8px;
  border-top: 1px solid var(--stroke-subtle);
  padding-top: 12px;
}
.disk-volumes-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  flex-wrap: wrap;
}
.disk-admin-volume.is-system {
  opacity: 0.86;
}
.disk-admin-capacity-chart {
  display: flex;
  align-items: center;
  gap: 12px;
  margin-top: 12px;
}
.disk-admin-capacity-bar {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 4px;
}
.disk-unmounted-bar {
  display: flex;
  flex-direction: column;
  gap: 6px;
}
.disk-unmounted-track {
  height: 9px;
  width: 100%;
  border-radius: 999px;
  background: color-mix(in srgb, var(--stroke-subtle) 55%, transparent);
  border: 1px dashed color-mix(in srgb, var(--text-tertiary) 35%, transparent);
}
.disk-capacity-caption {
  font-size: 11px;
  color: var(--text-tertiary);
}
.disk-admin-volumes h4 {
  display: flex;
  align-items: center;
  gap: 8px;
  margin: 0 0 4px;
  font-size: 13.5px;
  color: var(--text-primary);
}
.disk-admin-volume {
  padding: 10px 0;
  border-bottom: 1px solid var(--stroke-subtle);
  display: grid;
  gap: 6px;
}
.disk-admin-volume:last-child {
  border-bottom: none;
  padding-bottom: 0;
}
.disk-admin-volume-main {
  display: flex;
  align-items: baseline;
  gap: 10px;
  flex-wrap: wrap;
}
.disk-admin-volume-main strong {
  font-size: 13px;
  color: var(--text-primary);
}
.disk-admin-volume-main span {
  font-size: 11.5px;
  color: var(--text-secondary);
}
.disk-admin-volume-capacity {
  margin-top: 0;
}
@media (max-width: 600px) {
  .disk-admin-main {
    flex-wrap: wrap;
  }
  .disk-admin-capacity {
    flex-wrap: wrap;
  }
}
.disk-rename-form label {
  display: grid;
  gap: 6px;
  font-size: 12px;
  font-weight: 600;
  color: var(--text-secondary);
}
.disk-rename-form input {
  width: 100%;
  box-sizing: border-box;
  border: 1px solid var(--stroke-subtle);
  border-radius: 10px;
  background: var(--surface-base);
  color: var(--text-primary);
  padding: 9px 12px;
  font-size: 14px;
}
@media (prefers-reduced-motion: reduce) {
  .disk-system-toggle,
  .disk-system-toggle-chevron {
    transition: none;
  }
}
</style>
