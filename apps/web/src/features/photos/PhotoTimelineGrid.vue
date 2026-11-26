<script setup lang="ts">
import type { StyleValue } from "vue";
import { Check, Film, Heart, Images, Star } from "lucide-vue-next";
import { dateLabel, formatDuration } from "./photoPresentation.ts";
import type { BatchAsset } from "./usePhotoBatchActions.ts";
import type { PhotoTimelineGroup } from "./photoTimelineLayout.ts";

defineProps<{
  totalHeight: number;
  compactGrid: boolean;
  trashSelecting: boolean;
  trashBusy: boolean;
  trashIds: Set<number>;
  hasMore: boolean;
  visibleHeaders: PhotoTimelineGroup[];
  visibleAssets: BatchAsset[];
  startIndex: number;
  focusedIndex: number;
  thumbnailLoaded: Record<number, boolean>;
  thumbnailFailed: Record<number, boolean>;
  thumbFor: (asset: BatchAsset) => string;
  tileStyleFor: (index: number) => StyleValue;
  isMonthSelected: (header: PhotoTimelineGroup) => boolean;
  setGridRef: (el: HTMLElement | null) => void;
}>();

const emit = defineEmits<{
  (e: "toggle-month", header: PhotoTimelineGroup): void;
  (e: "focus-index", index: number): void;
  (e: "tile-keydown", event: KeyboardEvent, index: number): void;
  (e: "tile-click", asset: BatchAsset, index: number, shiftKey: boolean): void;
  (e: "thumb-load", event: Event, id: number): void;
  (e: "thumb-error", id: number): void;
}>();
</script>

<template>
  <div
    :ref="(el) => setGridRef(el as HTMLElement | null)"
    class="photo-grid"
    :class="{ 'photo-grid-compact': compactGrid, 'is-selecting': trashSelecting }"
    role="group"
    aria-label="按年月排列的照片和视频"
    :style="{ height: totalHeight + 'px' }"
  >
    <div
      v-for="header in visibleHeaders"
      :key="header.startIndex"
      class="photo-month-heading"
      :style="{ top: header.top + 'px' }"
      role="heading"
      aria-level="3"
    >
      <div class="photo-month-title">
        {{ header.title }}
        <small>{{ header.count }} 项<span v-if="hasMore"> · 已加载</span></small>
      </div>
      <button
        type="button"
        class="photo-month-select"
        :class="{ chosen: isMonthSelected(header) }"
        :disabled="trashBusy"
        :title="isMonthSelected(header) ? '取消选择当月' : '全选当月照片'"
        @click.stop="emit('toggle-month', header)"
      >
        <Check v-if="isMonthSelected(header)" :size="12" />
        <span>{{ isMonthSelected(header) ? "已选当月" : "全选当月" }}</span>
      </button>
    </div>

    <button
      v-for="(asset, visibleIndex) in visibleAssets"
      :key="asset.id"
      type="button"
      class="photo-tile"
      :aria-pressed="trashSelecting ? trashIds.has(asset.id) : undefined"
      :class="{ 'photo-trash-selected': trashSelecting && trashIds.has(asset.id) }"
      :data-photo-index="startIndex + visibleIndex"
      :tabindex="startIndex + visibleIndex === focusedIndex ? 0 : -1"
      :style="tileStyleFor(startIndex + visibleIndex)"
      @focus="emit('focus-index', startIndex + visibleIndex)"
      @keydown="emit('tile-keydown', $event, startIndex + visibleIndex)"
      @click="emit('tile-click', asset, startIndex + visibleIndex, $event.shiftKey)"
    >
      <img
        v-if="thumbFor(asset) && !thumbnailFailed[asset.id]"
        :src="thumbFor(asset)"
        :class="{ 'is-loaded': thumbnailLoaded[asset.id] }"
        loading="lazy"
        decoding="async"
        :alt="asset.name"
        @load="emit('thumb-load', $event, asset.id)"
        @error="emit('thumb-error', asset.id)"
      />
      <div v-else class="video-placeholder">
        <Film v-if="asset.type === 'video'" :size="26" />
        <Images v-else :size="26" />
        <small>{{ asset.type === "video" ? "视频" : "预览暂不可用" }}</small>
      </div>
      <span v-if="(asset.liveVideoAssetId ?? 0) > 0 && !trashSelecting" class="photo-live-chip" title="Apple 实况照片">实况</span>
      <span v-if="asset.favorite" class="photo-liked" title="共享收藏"><Heart :size="14" fill="currentColor" /></span>
      <span v-if="asset.personalFavorite" class="photo-private-liked" title="我的收藏"><Star :size="14" fill="currentColor" /></span>
      <span
        v-if="asset.type === 'video' && !trashSelecting"
        class="photo-duration-chip"
        :title="(asset.durationSeconds ?? 0) > 0 ? '视频时长 ' + formatDuration(asset.durationSeconds!) : '视频'"
      >
        <Film :size="11" />
        <template v-if="(asset.durationSeconds ?? 0) > 0">{{ formatDuration(asset.durationSeconds!) }}</template>
      </span>
      <span v-if="trashSelecting" class="photo-trash-indicator" :class="{ selected: trashIds.has(asset.id) }" aria-hidden="true">
        <Check v-if="trashIds.has(asset.id)" :size="13" :stroke-width="2.75" />
      </span>
      <small class="photo-date">{{ dateLabel(asset.takenAt) }}</small>
    </button>
  </div>
</template>
