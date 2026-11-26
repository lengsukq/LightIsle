<script setup lang="ts">
import { onUnmounted, ref, watch } from "vue";
import { ArrowLeft, ExternalLink, Maximize2, Minimize2, RefreshCcw, RotateCw } from "lucide-vue-next";
import IsleBadge from "../../components/ui/IsleBadge.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import { pushModalLayer, type ModalLayerHandle } from "../../utils/modalStack.ts";
import type { PublicAppItem } from "../../types/appsCenter.ts";

const props = withDefaults(defineProps<{
  app: PublicAppItem;
  iframeUrl: string;
  iframeKey: number;
  fullscreen: boolean;
  badgeText: string;
  backLabel?: string;
}>(), {
  backLabel: "返回应用中心",
});

const emit = defineEmits<{
  close: [];
  refresh: [];
  "toggle-fullscreen": [];
  "open-external": [];
}>();

const frameLoaded = ref(false);
let fullscreenLayer: ModalLayerHandle | null = null;

watch(
  [() => props.iframeKey, () => props.iframeUrl],
  () => {
    frameLoaded.value = false;
  },
);

watch(
  () => props.fullscreen,
  (isFull) => {
    fullscreenLayer?.dispose();
    fullscreenLayer = null;
    if (isFull) {
      fullscreenLayer = pushModalLayer({
        onEsc: () => emit("toggle-fullscreen"),
        lockScroll: true,
      });
    }
  },
  { immediate: true },
);

onUnmounted(() => {
  fullscreenLayer?.dispose();
  fullscreenLayer = null;
});
</script>

<template>
  <div class="app-workbench" :class="{ 'is-fullscreen': fullscreen }">
    <header class="workbench-topbar">
      <div class="workbench-left">
        <IsleButton variant="glass" size="sm" @click="emit('close')">
          <template #icon><ArrowLeft :size="15" /></template>
          {{ backLabel }}
        </IsleButton>
        <strong class="workbench-title" :title="app.name">{{ app.name }}</strong>
        <IsleBadge variant="accent" dot size="sm">{{ badgeText }}</IsleBadge>
      </div>
      <div class="workbench-actions">
        <IsleButton variant="glass" size="sm" @click="emit('refresh')">
          <template #icon><RotateCw :size="14" /></template>
          刷新画面
        </IsleButton>
        <IsleButton variant="glass" size="sm" @click="emit('toggle-fullscreen')">
          <template #icon><Minimize2 v-if="fullscreen" :size="14" /><Maximize2 v-else :size="14" /></template>
          {{ fullscreen ? "退出全屏" : "全屏展开" }}
        </IsleButton>
        <IsleButton variant="primary" size="sm" @click="emit('open-external')">
          <template #icon><ExternalLink :size="14" /></template>
          新标签页打开
        </IsleButton>
      </div>
    </header>
    <div class="app-workbench-frame-wrap">
      <div v-if="!frameLoaded" class="app-workbench-loading" role="status">
        <span class="app-workbench-loading-pill">
          <RefreshCcw :size="14" class="spinning" aria-hidden="true" />
          <span>正在载入 {{ app.name }}…</span>
        </span>
      </div>
      <iframe
        :key="iframeKey"
        :src="iframeUrl"
        sandbox="allow-scripts allow-forms allow-same-origin allow-popups allow-downloads"
        referrerpolicy="no-referrer"
        class="app-workbench-iframe"
        :class="{ 'is-loaded': frameLoaded }"
        :title="app.name"
        @load="frameLoaded = true"
      />
    </div>
  </div>
</template>
