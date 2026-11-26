<script setup lang="ts">
import { computed, ref } from "vue";
import { FileArchive, FileText, Film, Images, Music } from "lucide-vue-next";
import IsleBadge from "../../components/ui/IsleBadge.vue";
import { formatShortDate } from "../../utils/dateTimeFormat.ts";
import { formatBytes } from "../photos/photoPresentation.ts";
import type { DuplicateFileGroup, DuplicateFileItem } from "../photos/usePhotoAISearchAndPeople.ts";
import {
  getDuplicateFileKind,
  isDuplicateThumbnailEligible,
  splitDuplicatePath,
} from "./duplicateFilesSupport.ts";

const props = defineProps<{
  group: DuplicateFileGroup;
  checkedSet?: Set<string>;
  thumbnailUrl: (path: string) => string;
}>();

const emit = defineEmits<{
  (e: "toggle-item", payload: { group: DuplicateFileGroup; path: string; canTrash: boolean }): void;
}>();

const loadedThumbs = ref(new Set<string>());
const failedThumbs = ref(new Set<string>());

const groupTitle = computed(() => {
  const first = props.group.items[0];
  if (!first) return `单文件 ${formatBytes(props.group.size)}`;
  return splitDuplicatePath(first.path).fileName;
});

function isCheckedItem(item: DuplicateFileItem): boolean {
  return props.checkedSet?.has(item.path) ?? false;
}

function isKeepItem(item: DuplicateFileItem): boolean {
  return !isCheckedItem(item);
}

function onThumbLoad(path: string, event: Event) {
  const img = event.target as HTMLImageElement | null;
  if (img && img.naturalWidth === 0) {
    markThumbFailed(path);
    return;
  }
  if (loadedThumbs.value.has(path)) return;
  const next = new Set(loadedThumbs.value);
  next.add(path);
  loadedThumbs.value = next;
}

function markThumbFailed(path: string) {
  if (failedThumbs.value.has(path)) return;
  const next = new Set(failedThumbs.value);
  next.add(path);
  failedThumbs.value = next;
}
</script>

<template>
  <article class="dup-group-card">
    <header class="dup-group-head">
      <div class="dup-group-head-main">
        <strong class="dup-group-name" :title="groupTitle">{{ groupTitle }}</strong>
        <span class="dup-group-meta">
          单份 {{ formatBytes(group.size) }} · {{ group.count }} 份副本
          <template v-if="group.allApfsClones"> · APFS 克隆共享物理块</template>
        </span>
      </div>
      <span class="dup-group-reclaim">可清理 {{ formatBytes(group.reclaimableBytes) }}</span>
    </header>

    <TransitionGroup name="dup-row" tag="div" class="dup-item-rows">
      <label
        v-for="item in group.items"
        :key="item.path"
        class="dup-item-row"
        :class="{ 'is-keep': isKeepItem(item), 'is-readonly': !item.canTrash }"
        :title="item.path"
      >
        <input
          type="checkbox"
          class="isle-checkbox"
          :checked="isCheckedItem(item)"
          :disabled="!item.canTrash"
          @change="emit('toggle-item', { group, path: item.path, canTrash: item.canTrash })"
        />

        <span class="dup-thumb-box" aria-hidden="true">
          <Images v-if="getDuplicateFileKind(item.name) === 'image'" :size="15" />
          <Film v-else-if="getDuplicateFileKind(item.name) === 'video'" :size="15" />
          <Music v-else-if="getDuplicateFileKind(item.name) === 'audio'" :size="15" />
          <FileArchive v-else-if="getDuplicateFileKind(item.name) === 'archive'" :size="15" />
          <FileText v-else :size="15" />
          <img
            v-if="isDuplicateThumbnailEligible(item.name) && !failedThumbs.has(item.path)"
            :src="thumbnailUrl(item.path)"
            :alt="item.name"
            loading="lazy"
            decoding="async"
            class="dup-thumb-img"
            :class="{ 'is-loaded': loadedThumbs.has(item.path) }"
            @load="onThumbLoad(item.path, $event)"
            @error="markThumbFailed(item.path)"
          />
        </span>

        <span class="dup-item-copy">
          <strong>{{ splitDuplicatePath(item.path).fileName }}</strong>
          <small>
            {{ splitDuplicatePath(item.path).parentFolder }}
            <template v-if="item.isApfsClone"> · APFS 克隆</template>
            <template v-else-if="item.modified"> · {{ formatShortDate(item.modified) }}</template>
          </small>
        </span>

        <span class="dup-item-end">
          <IsleBadge v-if="!item.canTrash" variant="warning" size="sm">只读目录</IsleBadge>
          <IsleBadge v-else-if="isKeepItem(item)" variant="online" size="sm">建议保留</IsleBadge>
          <IsleBadge v-else variant="danger" size="sm">可清理</IsleBadge>
          <span class="dup-item-size">{{ formatBytes(item.size) }}</span>
        </span>
      </label>
    </TransitionGroup>
  </article>
</template>

<style scoped>
.dup-group-card {
  padding: 11px 13px;
  border-radius: 13px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
}
.dup-group-head {
  display: flex;
  flex-wrap: wrap;
  justify-content: space-between;
  align-items: baseline;
  gap: 6px 12px;
  margin-bottom: 8px;
}
.dup-group-head-main {
  display: flex;
  align-items: baseline;
  flex-wrap: wrap;
  gap: 3px 8px;
  min-width: 0;
  flex: 1 1 220px;
}
.dup-group-name {
  font-size: 13px;
  font-weight: 650;
  color: var(--text-primary);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  max-width: 100%;
}
.dup-group-meta {
  font-size: 11.5px;
  color: var(--text-tertiary);
  font-variant-numeric: tabular-nums;
}
.dup-group-reclaim {
  font-size: 12px;
  font-weight: 600;
  color: var(--accent-primary);
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}
.dup-item-rows {
  position: relative;
  display: flex;
  flex-direction: column;
  border: 1px solid var(--fluid-card-border);
  border-radius: 10px;
  background: var(--fluid-card-fill);
  overflow: hidden;
}
.dup-item-row {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 8px 11px;
  border-bottom: 1px solid var(--fluid-divider, var(--fluid-card-border));
  cursor: pointer;
  transition: background-color 0.15s ease;
}
.dup-item-row:last-child {
  border-bottom: 0;
}
.dup-item-row:hover {
  background: var(--fluid-card-hover);
}
.dup-item-row.is-keep {
  background: color-mix(in srgb, var(--success, #167a54) 6%, transparent);
}
.dup-item-row.is-readonly {
  cursor: default;
}
.dup-thumb-box {
  position: relative;
  width: 34px;
  height: 34px;
  border-radius: 8px;
  display: grid;
  place-items: center;
  flex-shrink: 0;
  overflow: hidden;
  border: 1px solid var(--fluid-card-border);
  background: color-mix(in srgb, var(--text-primary) 5%, var(--fluid-card-top));
  color: var(--text-secondary);
}
.dup-thumb-img {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  object-fit: cover;
  opacity: 0;
  transition: opacity 0.22s ease;
}
.dup-thumb-img.is-loaded {
  opacity: 1;
}
.dup-item-copy {
  flex: 1;
  min-width: 0;
  display: grid;
  gap: 1px;
}
.dup-item-copy strong {
  font-size: 12.5px;
  font-weight: 560;
  color: var(--text-primary);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.dup-item-copy small {
  font-size: 11.5px;
  color: var(--text-tertiary);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.dup-item-end {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  flex-shrink: 0;
}
.dup-item-size {
  min-width: 64px;
  text-align: right;
  font-size: 12px;
  color: var(--text-secondary);
  font-variant-numeric: tabular-nums;
}
.dup-row-enter-active,
.dup-row-leave-active,
.dup-row-move {
  transition: opacity 0.22s ease, transform 0.22s cubic-bezier(0.22, 1, 0.36, 1);
}
.dup-row-enter-from,
.dup-row-leave-to {
  opacity: 0;
  transform: translate3d(-8px, 0, 0);
}
.dup-row-leave-active {
  position: absolute;
  left: 0;
  right: 0;
  pointer-events: none;
}
@media (max-width: 560px) {
  .dup-item-row {
    flex-wrap: wrap;
    gap: 8px;
  }
  .dup-item-copy {
    flex: 1 1 160px;
  }
  .dup-item-end {
    margin-left: auto;
  }
}
@media (prefers-reduced-motion: reduce) {
  .dup-item-row,
  .dup-thumb-img,
  .dup-row-enter-active,
  .dup-row-leave-active,
  .dup-row-move {
    transition: none;
  }
}
</style>
