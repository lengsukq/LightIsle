<script setup lang="ts">
import {
  Activity, AlertTriangle, CheckCircle2, ChevronRight, Clock, Images, RefreshCcw, UploadCloud,
} from "lucide-vue-next";
import { taskHistoryErrorLabel, taskOperationLabel, taskRunStatusLabel } from "./taskHistoryPresentation.ts";
import { bytes } from "./useHostTelemetry.ts";
import type { BackendTask, TaskRun } from "./useTaskCenter.ts";
import IsleCard from "./IsleCard.vue";
import IsleButton from "./IsleButton.vue";
import IsleBadge from "./IsleBadge.vue";
import IsleBanner from "./IsleBanner.vue";
import IsleEmpty from "./IsleEmpty.vue";
import PendingMedia from "./PendingMedia.vue";
import UploadMaintenance from "./UploadMaintenance.vue";

defineProps<{
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
  multiRootMode: boolean;
  adminPendingMediaOpen: boolean;
  pendingUploadsOpen: boolean;
  refreshTaskCenter: () => Promise<void>;
  taskControl: (task: BackendTask, action: "cancel" | "retry") => Promise<void>;
  startMediaTask: (kind: "gallery" | "cinema") => void;
  reloadTaskHistory: (reset: boolean) => Promise<void>;
  togglePendingMedia: (admin: boolean, event: Event) => void;
  togglePendingUploads: (event: Event) => void;
}>();
</script>

<template>
  <IsleCard
    class="ops-panel"
    title="待处理数据与健康巡检"
    subtitle="汇总离线存储根、失败后台任务、缺失媒体与断点续传残留。"
  >
    <template #icon><Activity :size="18" /></template>
    <template #actions>
      <IsleButton variant="glass" size="sm" :disabled="!rootFeatureContextReady" @click="refreshTaskCenter">
        <template #icon><RefreshCcw :size="14" /></template>
        刷新
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

      <!-- 异常事项：离线硬盘 -->
      <div v-for="root in sharedRoots.filter(item => !item.online)" :key="root.rootID" class="account-row ops-alert-row">
        <div class="ops-alert-info">
          <IsleBadge variant="warning" size="sm" dot>离线</IsleBadge>
          <div>
            <strong>{{ root.name }} · 硬盘离线</strong>
            <small>请检查连接并重新接入原硬盘；旧数据和绑定应保留。</small>
          </div>
        </div>
      </div>

      <!-- 异常事项：失败后台任务 -->
      <div v-for="task in tasks.filter(item => !!item.lastError && !item.running)" :key="task.kind" class="account-row ops-alert-row">
        <div class="ops-alert-info">
          <IsleBadge variant="danger" size="sm">未完成</IsleBadge>
          <div>
            <strong>{{ task.kind === 'gallery' ? '图库索引' : task.kind === 'cinema' ? '影视索引' : task.kind === 'uploads' ? '上传清理' : task.kind === 'trash' ? '旧版回收站清理' : task.kind }}</strong>
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

      <!-- 正常常态 -->
      <div
        v-if="rootFeatureContextReady && !sharedRoots.some(item => !item.online) && !tasks.some(item => !!item.lastError && !item.running) && !taskError && !rootDiscoveryError"
        class="account-row ops-healthy-row"
      >
        <div class="ops-healthy-info">
          <span class="ops-status-badge is-healthy"><CheckCircle2 :size="13" /> 正常</span>
          <div>
            <strong>存储与任务运行正常</strong>
            <small>当前硬盘已接入，所有索引和清理任务无异常。</small>
          </div>
        </div>
      </div>

      <!-- 维护与排障工具组 -->
      <div v-if="rootFeatureContextReady" class="ops-tools-group">
        <details class="apple-disclosure-card" @toggle="togglePendingMedia(true, $event)">
          <summary>
            <div class="disclosure-title">
              <Images :size="15" class="disclosure-icon" />
              <span>缺失媒体排查与修复</span>
            </div>
            <ChevronRight :size="14" class="disclosure-chevron" />
          </summary>
          <div class="disclosure-body">
            <PendingMedia
              v-if="adminPendingMediaOpen"
              :key="rootViewKey"
              :root-id="selectedRootId"
              :root-generation="selectedRootGeneration"
              :admin="true"
            />
          </div>
        </details>

        <details class="apple-disclosure-card" @toggle="togglePendingUploads">
          <summary>
            <div class="disclosure-title">
              <UploadCloud :size="15" class="disclosure-icon" />
              <span>断点续传残留与上传清理</span>
            </div>
            <ChevronRight :size="14" class="disclosure-chevron" />
          </summary>
          <div class="disclosure-body">
            <UploadMaintenance
              v-if="pendingUploadsOpen"
              :key="rootViewKey"
              :root-id="multiRootMode ? selectedRootId : undefined"
              :root-generation="selectedRootGeneration"
            />
          </div>
        </details>
      </div>
    </div>
  </IsleCard>

  <IsleCard
    v-if="rootFeatureContextReady"
    title="后台任务中心"
    subtitle="查看媒体自动索引进度、手动触发扫描与最近任务记录。"
  >
    <template #icon><Clock :size="18" /></template>
    <template #actions>
      <IsleButton variant="glass" size="sm" @click="refreshTaskCenter">
        <template #icon><RefreshCcw :size="14" /></template>
        刷新
      </IsleButton>
    </template>

    <div class="ops-stack">
      <div v-if="!tasks.some(task => task.kind === 'gallery') || !tasks.some(task => task.kind === 'cinema')" class="account-row">
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

      <div v-for="task in tasks" :key="task.kind" class="account-row">
        <div>
          <div class="ops-task-title">
            <strong>{{ task.kind === 'gallery' ? '图库索引' : task.kind === 'cinema' ? '影视索引' : task.kind === 'uploads' ? '上传清理' : task.kind === 'trash' ? '旧版回收站清理' : '文件备份' }}</strong>
            <IsleBadge :variant="task.running ? 'accent' : 'neutral'" size="sm" :dot="task.running">
              {{ task.running ? '进行中' : '空闲' }}
            </IsleBadge>
          </div>
          <small>
            已处理 {{ task.progress }} 项{{ task.lastError ? ' · ' + taskHistoryErrorLabel(task.lastError) : '' }}{{ task.lastDone ? ' · ' + new Date(task.lastDone * 1000).toLocaleString() : '' }}
          </small>
        </div>
        <IsleButton
          v-if="task.kind === 'gallery' || task.kind === 'cinema'"
          :variant="task.running ? 'danger' : 'glass'"
          size="sm"
          @click="taskControl(task, task.running ? 'cancel' : 'retry')"
        >
          {{ task.running ? '取消扫描' : task.lastDone || task.lastError ? '重新扫描' : '开始扫描' }}
        </IsleButton>
      </div>

      <IsleBanner v-if="taskError" type="error" compact role="alert" :message="taskError" />

      <div class="account-heading task-history-heading">
        <h4>最近任务记录</h4>
        <IsleBadge variant="neutral" size="sm">{{ taskHistory.length }} 条</IsleBadge>
      </div>

      <IsleBanner v-if="taskHistoryError" type="error" compact role="alert" :message="taskHistoryError">
        <template #action>
          <IsleButton variant="ghost" size="sm" :loading="taskHistoryLoading" @click="reloadTaskHistory(true)">重试</IsleButton>
        </template>
      </IsleBanner>

      <div v-if="taskHistoryLoading && !taskHistory.length" class="files-empty">正在读取任务记录…</div>
      <IsleEmpty v-else-if="!taskHistory.length && !taskHistoryError" compact description="还没有任务记录" />

      <div v-for="run in taskHistory" :key="run.id" class="account-row task-history-row">
        <div>
          <strong>
            {{ run.kind === 'gallery' ? '图库索引' : run.kind === 'cinema' ? '影视索引' : run.kind === 'uploads' ? '上传清理' : run.kind === 'trash' ? '旧版回收站清理' : '文件备份' }}
            · {{ taskOperationLabel(run.operation) }} · {{ taskRunStatusLabel(run) }}
          </strong>
          <small>
            开始于 {{ run.startedAt ? new Date(run.startedAt * 1000).toLocaleString() : '时间未知' }} · 已处理 {{ run.progress }} 项{{ run.bytes ? ' · ' + bytes(run.bytes) : '' }} · 第 {{ run.attempts }} 次
          </small>
          <small v-if="run.lastError" class="task-history-error">{{ taskHistoryErrorLabel(run.lastError) }}</small>
        </div>
      </div>

      <div v-if="taskHistoryNextCursor" class="gallery-load task-history-more">
        <IsleButton variant="glass" size="sm" :loading="taskHistoryLoading" @click="reloadTaskHistory(false)">
          {{ taskHistoryLoading ? '正在加载…' : '加载更早记录' }}
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
  gap: 10px;
}
.ops-stack .account-row {
  margin: 0;
}
.ops-task-title {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}
</style>
