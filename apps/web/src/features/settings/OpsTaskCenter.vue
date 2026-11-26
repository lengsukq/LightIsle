<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { Activity, CheckCircle2, Clock, Images, RefreshCw } from "lucide-vue-next";
import {
  taskHistoryErrorLabel,
  taskKindLabel,
  taskOperationLabel,
  taskRunStatusLabel,
} from "./taskHistoryPresentation.ts";
import { bytes } from "../overview/useHostTelemetry.ts";
import { formatDateTime } from "../../utils/dateTimeFormat.ts";
import { formatUnixDateTime } from "../../utils/format.ts";
import type { BackendTask, TaskRun } from "./useTaskCenter.ts";
import IsleBadge from "../../components/ui/IsleBadge.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleCard from "../../components/ui/IsleCard.vue";
import IsleDisclosure from "../../components/ui/IsleDisclosure.vue";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import IsleGroupedList from "../../components/ui/IsleGroupedList.vue";
import PendingMedia from "./PendingMedia.vue";

const props = defineProps<{
  sharedRoots: { rootID: string; name: string; online: boolean }[];
  rootDiscoveryError: string;
  rootFeatureContextReady: boolean;
  tasks: BackendTask[];
  taskError: string;
  taskHistory: TaskRun[];
  taskHistoryError: string;
  taskHistoryLoading: boolean;
  taskHistoryNextCursor: string;
  rootViewKey: string;
  selectedRootId: string;
  selectedRootGeneration: number;
  adminPendingMediaOpen: boolean;
  refreshTaskCenter: () => Promise<void>;
  taskControl: (task: BackendTask, action: "cancel" | "retry") => Promise<void>;
  startMediaTask: (kind: "gallery" | "cinema") => void;
  reloadTaskHistory: (reset: boolean) => Promise<void>;
  togglePendingMedia: (admin: boolean, event: Event) => void;
}>();

const refreshing = ref(false);
const lastUpdatedAt = ref(Date.now());

const updatedLabel = computed(() =>
  lastUpdatedAt.value ? "更新于 " + formatDateTime(lastUpdatedAt.value).replace(/^.*?\s/, "") : "",
);

const offlineRoots = computed(() => props.sharedRoots.filter((item) => !item.online));
const failedTasks = computed(() => props.tasks.filter((item) => !!item.lastError && !item.running));
const isAllHealthy = computed(
  () =>
    props.rootFeatureContextReady &&
    !offlineRoots.value.length &&
    !failedTasks.value.length &&
    !props.taskError &&
    !props.rootDiscoveryError,
);

async function handleRefresh() {
  if (!props.rootFeatureContextReady || refreshing.value) return;
  refreshing.value = true;
  try {
    await props.refreshTaskCenter();
    lastUpdatedAt.value = Date.now();
  } finally {
    refreshing.value = false;
  }
}

function handlePendingMediaToggle(open: boolean) {
  props.togglePendingMedia(true, { target: { open } } as unknown as Event);
}

function runBadgeVariant(run: TaskRun): "accent" | "online" | "neutral" | "danger" | "warning" {
  if (run.running) return "accent";
  if (!run.lastError) return "online";
  if (run.lastError === "cancelled" || run.lastError === "scan_limit_reached") return "warning";
  return "danger";
}

watch(
  () => [props.tasks, props.taskHistory, props.sharedRoots],
  () => {
    lastUpdatedAt.value = Date.now();
  },
);
</script>

<template>
  <IsleCard
    class="ops-panel"
    title="运行状态与健康巡检"
    subtitle="汇总离线存储目录、未完成的后台任务与缺失媒体记录。"
  >
    <template #icon><Activity :size="18" /></template>
    <template #actions>
      <span v-if="updatedLabel" class="settings-updated-at">{{ updatedLabel }}</span>
      <IsleButton
        variant="ghost"
        size="sm"
        :loading="refreshing"
        :disabled="!rootFeatureContextReady"
        aria-label="刷新巡检状态"
        title="刷新巡检状态"
        @click="handleRefresh"
      >
        <template #icon><RefreshCw :size="14" /></template>
      </IsleButton>
    </template>

    <div class="ops-stack">
      <IsleBanner
        v-if="rootDiscoveryError"
        type="error"
        compact
        role="alert"
        :message="'硬盘列表读取失败，待处理情况不完整：' + rootDiscoveryError"
      />
      <IsleBanner
        v-if="taskError"
        type="error"
        compact
        role="alert"
        :message="'当前硬盘待处理任务读取不完整：' + taskError"
      />
      <p v-if="!rootFeatureContextReady" class="footnote">
        选择硬盘后可查看该硬盘的任务与上传；离线硬盘需先连接原硬盘。
      </p>

      <IsleGroupedList
        v-if="offlineRoots.length || failedTasks.length || isAllHealthy"
        variant="item"
        flush
      >
        <div class="settings-grouped-rows">
          <div v-for="root in offlineRoots" :key="root.rootID" class="account-row ops-alert-row">
            <div class="ops-alert-info">
              <IsleBadge variant="warning" size="sm" dot>离线</IsleBadge>
              <div>
                <strong>{{ root.name }} · 硬盘离线</strong>
                <small>请检查连接并重新接入原硬盘；旧数据和绑定应保留。</small>
              </div>
            </div>
          </div>

          <div v-for="task in failedTasks" :key="task.kind" class="account-row ops-alert-row">
            <div class="ops-alert-info">
              <IsleBadge variant="danger" size="sm">未完成</IsleBadge>
              <div>
                <strong>{{ taskKindLabel(task.kind) }}</strong>
                <small>{{ taskHistoryErrorLabel(task.lastError) }}</small>
              </div>
            </div>
            <IsleButton
              v-if="task.kind === 'gallery' || task.kind === 'cinema'"
              variant="tonal"
              size="sm"
              @click="taskControl(task, 'retry')"
            >
              重新扫描
            </IsleButton>
          </div>

          <div v-if="isAllHealthy" class="account-row ops-healthy-row">
            <div class="ops-healthy-info">
              <span class="ops-status-badge is-healthy"><CheckCircle2 :size="13" /> 正常</span>
              <div>
                <strong>存储与任务运行正常</strong>
                <small>当前硬盘已接入，所有索引和清理任务无异常。</small>
              </div>
            </div>
          </div>
        </div>
      </IsleGroupedList>

      <IsleDisclosure
        v-if="rootFeatureContextReady"
        :model-value="adminPendingMediaOpen"
        title="缺失媒体排查与修复"
        subtitle="查看移动或重命名后的照片与影视记录并重新关联"
        :icon="Images"
        @update:model-value="handlePendingMediaToggle"
      >
        <PendingMedia
          v-if="adminPendingMediaOpen"
          :key="rootViewKey"
          :root-id="selectedRootId"
          :root-generation="selectedRootGeneration"
          :admin="true"
        />
      </IsleDisclosure>
    </div>
  </IsleCard>

  <IsleCard
    v-if="rootFeatureContextReady"
    title="后台任务中心"
    subtitle="查看媒体自动索引进度、手动触发扫描与最近任务记录。"
  >
    <template #icon><Clock :size="18" /></template>
    <template #actions>
      <span v-if="updatedLabel" class="settings-updated-at">{{ updatedLabel }}</span>
      <IsleButton
        variant="ghost"
        size="sm"
        :loading="refreshing"
        aria-label="刷新任务中心"
        title="刷新任务中心"
        @click="handleRefresh"
      >
        <template #icon><RefreshCw :size="14" /></template>
      </IsleButton>
    </template>

    <div class="ops-stack">
      <IsleGroupedList variant="item" flush>
        <div
          v-if="!tasks.some(task => task.kind === 'gallery') || !tasks.some(task => task.kind === 'cinema')"
          class="account-row ops-quick-row"
        >
          <div>
            <strong>媒体扫描</strong>
            <small>可以手动开始尚无记录的媒体扫描。</small>
          </div>
          <div class="task-empty-actions">
            <IsleButton v-if="!tasks.some(task => task.kind === 'gallery')" variant="tonal" size="sm" @click="startMediaTask('gallery')">
              扫描图库
            </IsleButton>
            <IsleButton v-if="!tasks.some(task => task.kind === 'cinema')" variant="tonal" size="sm" @click="startMediaTask('cinema')">
              扫描影视
            </IsleButton>
          </div>
        </div>

        <TransitionGroup name="isle-list" tag="div" class="settings-grouped-rows">
          <div v-for="task in tasks" :key="task.kind" class="account-row">
            <div>
              <div class="ops-task-title">
                <strong>{{ taskKindLabel(task.kind) }}</strong>
                <IsleBadge :variant="task.running ? 'accent' : 'neutral'" size="sm" :dot="task.running">
                  {{ task.running ? "进行中" : "空闲" }}
                </IsleBadge>
              </div>
              <small class="ops-tabular">
                已处理 {{ task.progress }} 项{{ task.lastError ? " · " + taskHistoryErrorLabel(task.lastError) : "" }}{{ task.lastDone ? " · " + formatUnixDateTime(task.lastDone) : "" }}
              </small>
            </div>
            <IsleButton
              v-if="task.kind === 'gallery' || task.kind === 'cinema'"
              :variant="task.running ? 'danger' : 'glass'"
              size="sm"
              @click="taskControl(task, task.running ? 'cancel' : 'retry')"
            >
              {{ task.running ? "取消扫描" : task.lastDone || task.lastError ? "重新扫描" : "开始扫描" }}
            </IsleButton>
          </div>
        </TransitionGroup>
      </IsleGroupedList>

      <IsleBanner v-if="taskError" type="error" compact role="alert" :message="taskError" />

      <IsleGroupedList title="最近任务记录" variant="item" flush>
        <template #actions>
          <IsleBadge variant="neutral" size="sm">{{ taskHistory.length }} 条</IsleBadge>
        </template>

        <IsleBanner v-if="taskHistoryError" type="error" compact role="alert" :message="taskHistoryError">
          <template #action>
            <IsleButton variant="glass" size="sm" :loading="taskHistoryLoading" @click="reloadTaskHistory(true)">重试</IsleButton>
          </template>
        </IsleBanner>

        <p v-if="taskHistoryLoading && !taskHistory.length" class="ops-empty-pad footnote" role="status">正在读取任务记录…</p>
        <div v-else-if="!taskHistory.length && !taskHistoryError" class="ops-empty-pad">
          <IsleEmpty compact description="还没有任务记录" />
        </div>

        <TransitionGroup v-else-if="taskHistory.length" name="isle-list" tag="div" class="settings-grouped-rows">
          <div v-for="run in taskHistory" :key="run.id" class="account-row task-history-row">
            <div>
              <div class="ops-task-title">
                <strong>{{ taskKindLabel(run.kind) }} · {{ taskOperationLabel(run.operation) }}</strong>
                <IsleBadge :variant="runBadgeVariant(run)" size="sm" :dot="run.running">
                  {{ taskRunStatusLabel(run) }}
                </IsleBadge>
              </div>
              <small class="ops-tabular">
                开始于 {{ formatUnixDateTime(run.startedAt, "时间未知") }} · 已处理 {{ run.progress }} 项{{ run.bytes ? " · " + bytes(run.bytes) : "" }} · 第 {{ run.attempts }} 次
              </small>
              <small v-if="run.lastError" class="task-history-error">{{ taskHistoryErrorLabel(run.lastError) }}</small>
            </div>
          </div>
        </TransitionGroup>
      </IsleGroupedList>

      <div v-if="taskHistoryNextCursor" class="gallery-load task-history-more">
        <IsleButton variant="glass" size="sm" :loading="taskHistoryLoading" @click="reloadTaskHistory(false)">
          {{ taskHistoryLoading ? "正在加载…" : "加载更早记录" }}
        </IsleButton>
      </div>
    </div>
  </IsleCard>
  <p v-else class="footnote">选择共享目录后可查看该目录的任务状态。</p>
</template>

<style scoped>
.ops-stack {
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.ops-stack .footnote {
  margin: 0;
}

.ops-empty-pad {
  padding: 12px 16px;
}

.ops-quick-row {
  padding: 12px 16px;
}

.ops-alert-row > div:first-child,
.ops-alert-info,
.ops-healthy-info,
.ops-alert-info > div,
.ops-healthy-info > div,
.task-history-row > div {
  min-width: 0;
  flex: 1;
  overflow-wrap: anywhere;
}

.ops-task-title {
  display: flex;
  align-items: center;
  gap: 7px;
  flex-wrap: wrap;
}

.ops-tabular {
  font-variant-numeric: tabular-nums;
}

.task-empty-actions {
  display: flex;
  align-items: center;
  gap: 6px;
  flex-wrap: wrap;
}

.account-row .task-history-error {
  color: var(--error);
}
</style>
