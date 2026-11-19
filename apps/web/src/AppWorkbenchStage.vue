<script setup lang="ts">
import { ArrowLeft, ExternalLink, Maximize2, Minimize2, RotateCw } from "lucide-vue-next";
import IsleBadge from "./IsleBadge.vue";
import IsleButton from "./IsleButton.vue";
import type { PublicAppItem } from "./types/appsCenter.ts";

withDefaults(defineProps<{
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
</script>

<template>
  <div class="app-workbench" :class="{ fullscreen }">
    <header class="workbench-topbar">
      <div class="workbench-left">
        <IsleButton variant="glass" size="sm" @click="emit('close')">
          <ArrowLeft :size="15" /> {{ backLabel }}
        </IsleButton>
        <strong class="workbench-title">{{ app.name }}</strong>
        <IsleBadge variant="accent" size="sm">{{ badgeText }}</IsleBadge>
      </div>
      <div class="workbench-actions">
        <IsleButton variant="glass" size="sm" @click="emit('refresh')">
          <RotateCw :size="14" /> 刷新画面
        </IsleButton>
        <IsleButton variant="glass" size="sm" @click="emit('toggle-fullscreen')">
          <Minimize2 v-if="fullscreen" :size="14" /><Maximize2 v-else :size="14" />
          {{ fullscreen ? "退出全屏" : "全屏展开" }}
        </IsleButton>
        <IsleButton variant="primary" size="sm" @click="emit('open-external')">
          <ExternalLink :size="14" /> 新标签页打开
        </IsleButton>
      </div>
    </header>
    <iframe
      :key="iframeKey"
      :src="iframeUrl"
      sandbox="allow-scripts allow-forms allow-same-origin allow-popups allow-downloads"
      referrerpolicy="no-referrer"
      class="app-workbench-iframe"
      :title="app.name"
    />
  </div>
</template>
