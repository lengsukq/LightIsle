<script setup lang="ts">
import { describeUserFacingError } from "../../api/userFacingError.ts";
import type { Movie, Scan } from "./cinemaTypes.ts";

defineProps<{
  scan: Scan;
  scanStatusError: string;
  scanStatusLoaded: boolean;
  scanStatusLoading: boolean;
  scanActionError: string;
  actionError: string;
  loadError: string;
  loading: boolean;
  progressSaveError: string;
  movies: Movie[];
}>();

const emit = defineEmits<{
  (e: "retry-status"): void;
  (e: "retry-load"): void;
  (e: "retry-progress"): void;
}>();
</script>

<template>
  <div v-if="scan.running && !scanStatusError" class="cinema-alert cinema-tabular-meta">
    正在扫描：{{ scan.visited }} 项 · 已找到 {{ scan.found }} 部作品
  </div>
  <div v-if="scanStatusError && movies.length" class="cinema-alert" role="alert">
    扫描状态读取失败：{{ scanStatusError }}
    <span v-if="scanStatusLoaded">显示的是最近一次成功读取的状态。</span>
    <button type="button" class="account-action" :disabled="scanStatusLoading" @click="emit('retry-status')">
      {{ scanStatusLoading ? "正在重试…" : "重试状态" }}
    </button>
  </div>
  <div v-if="scanStatusLoaded && scan.lastError && movies.length" class="cinema-alert" role="alert">
    扫描未完成：{{ describeUserFacingError(scan.lastError) }}
  </div>
  <div v-if="scanActionError && movies.length" class="cinema-alert" role="alert">
    无法启动扫描：{{ scanActionError }}
  </div>
  <div v-if="actionError && movies.length" class="cinema-alert" role="alert">
    {{ actionError }}
  </div>
  <div v-if="loadError && movies.length" class="cinema-alert" role="alert">
    加载影视库失败：{{ loadError }} 当前仍显示上次成功读取的内容。
    <button type="button" class="account-action" :disabled="loading" @click="emit('retry-load')">
      重试加载
    </button>
  </div>
  <div v-if="progressSaveError" class="cinema-alert" role="alert">
    {{ progressSaveError }}
    <button type="button" class="account-action" @click="emit('retry-progress')">
      重试保存进度
    </button>
  </div>
</template>
