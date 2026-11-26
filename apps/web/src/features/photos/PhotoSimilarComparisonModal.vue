<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { Check, ChevronLeft, ChevronRight, Columns2, Maximize2, Sparkles, Trash2 } from "lucide-vue-next";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleModal from "../../components/ui/IsleModal.vue";
import { formatBytes } from "./photoPresentation.ts";
import type { SimilarPhotoCandidate, SimilarPhotoGroup } from "./usePhotoAISearchAndPeople.ts";

const props = defineProps<{
  group: SimilarPhotoGroup | null;
  activeIndex: number;
  selectedForTrash: number[];
  mediaPath: (path: string) => string;
}>();

const emit = defineEmits<{
  (e: "close"): void;
  (e: "step", delta: number): void;
  (e: "select-index", index: number): void;
  (e: "toggle-candidate", assetId: number, canTrash: boolean): void;
}>();

const previewFallback = ref<Record<number, boolean>>({});
const sideBySide = ref(true);

const activeItem = computed<SimilarPhotoCandidate | null>(() => {
  if (!props.group || !props.group.items.length) return null;
  const idx = Math.max(0, Math.min(props.group.items.length - 1, props.activeIndex));
  return props.group.items[idx] ?? null;
});

const referenceItem = computed<SimilarPhotoCandidate | null>(() => {
  if (!props.group || props.group.items.length < 2) return null;
  return (
    props.group.items.find((it) => it.recommended) ??
    props.group.items.find((it) => it.assetId === props.group?.recommendedAssetId) ??
    props.group.items[0] ??
    null
  );
});

const canShowSideBySide = computed(() =>
  Boolean(
    sideBySide.value &&
    props.group &&
    props.group.items.length >= 2 &&
    referenceItem.value &&
    activeItem.value &&
    referenceItem.value.assetId !== activeItem.value.assetId,
  ),
);

function imageSrc(item: SimilarPhotoCandidate): string {
  if (!previewFallback.value[item.assetId] && item.path) {
    return props.mediaPath("/api/v2/files/thumbnail?path=" + encodeURIComponent(item.path) + "&size=2048");
  }
  return props.mediaPath("/api/v2/photos/" + item.assetId + "/thumbnail");
}

function isTrash(assetId: number): boolean {
  return props.selectedForTrash.includes(assetId);
}

function onKeydown(event: KeyboardEvent) {
  if (!props.group || !activeItem.value) return;
  if (
    event.target instanceof HTMLInputElement ||
    event.target instanceof HTMLTextAreaElement ||
    (event.target instanceof HTMLElement && event.target.isContentEditable)
  ) {
    return;
  }
  if (event.key === "ArrowLeft") {
    event.preventDefault();
    emit("step", -1);
  } else if (event.key === "ArrowRight") {
    event.preventDefault();
    emit("step", 1);
  }
}

watch(
  () => props.group?.groupId,
  () => {
    previewFallback.value = {};
  },
);

onMounted(() => {
  window.addEventListener("keydown", onKeydown);
});

onBeforeUnmount(() => {
  window.removeEventListener("keydown", onKeydown);
});
</script>

<template>
  <IsleModal
    v-if="group && activeItem"
    :title="`${activeItem.name} (${activeIndex + 1} / ${group.items.length})`"
    size="wide"
    @close="emit('close')"
  >
    <template #actions>
      <IsleButton
        v-if="group.items.length >= 2"
        variant="glass"
        size="sm"
        :selected="sideBySide"
        :title="sideBySide ? '切换为单图放大对比' : '与推荐最佳画质并排对比'"
        @click="sideBySide = !sideBySide"
      >
        <template #icon>
          <Columns2 v-if="!sideBySide" :size="14" />
          <Maximize2 v-else :size="14" />
        </template>
        {{ sideBySide ? "单图视图" : "并排对比" }}
      </IsleButton>
    </template>

    <div class="similar-compare-shell">
      <div v-if="canShowSideBySide && referenceItem" class="similar-split-stage">
        <div class="similar-split-pane">
          <div class="similar-split-label is-best">
            <Sparkles :size="12" />
            <span>最佳画质 · 推荐保留</span>
            <small>{{ formatBytes(referenceItem.size) }}<template v-if="referenceItem.width && referenceItem.height"> · {{ referenceItem.width }}×{{ referenceItem.height }}</template></small>
          </div>
          <div class="similar-split-img-box">
            <img
              :src="imageSrc(referenceItem)"
              :alt="referenceItem.name"
              @error="previewFallback = { ...previewFallback, [referenceItem.assetId]: true }"
            />
          </div>
        </div>

        <div class="similar-split-pane">
          <div class="similar-split-label" :class="{ 'is-trash': isTrash(activeItem.assetId) }">
            <Trash2 v-if="isTrash(activeItem.assetId)" :size="12" />
            <Check v-else :size="12" />
            <span>{{ isTrash(activeItem.assetId) ? "当前对比 · 可清理" : "当前对比 · 保留" }}</span>
            <small>{{ formatBytes(activeItem.size) }}<template v-if="activeItem.width && activeItem.height"> · {{ activeItem.width }}×{{ activeItem.height }}</template></small>
          </div>
          <div class="similar-split-img-box">
            <img
              :src="imageSrc(activeItem)"
              :alt="activeItem.name"
              @error="previewFallback = { ...previewFallback, [activeItem.assetId]: true }"
            />
          </div>
        </div>

        <button
          v-if="group.items.length > 1"
          type="button"
          class="similar-preview-nav prev"
          aria-label="上一张候选照片"
          @click="emit('step', -1)"
        >
          <ChevronLeft :size="20" />
        </button>
        <button
          v-if="group.items.length > 1"
          type="button"
          class="similar-preview-nav next"
          aria-label="下一张候选照片"
          @click="emit('step', 1)"
        >
          <ChevronRight :size="20" />
        </button>
      </div>

      <div v-else class="similar-preview-stage">
        <button
          v-if="group.items.length > 1"
          type="button"
          class="similar-preview-nav prev"
          aria-label="上一张候选照片"
          @click="emit('step', -1)"
        >
          <ChevronLeft :size="20" />
        </button>
        <img
          :src="imageSrc(activeItem)"
          :alt="activeItem.name"
          @error="previewFallback = { ...previewFallback, [activeItem.assetId]: true }"
        />
        <button
          v-if="group.items.length > 1"
          type="button"
          class="similar-preview-nav next"
          aria-label="下一张候选照片"
          @click="emit('step', 1)"
        >
          <ChevronRight :size="20" />
        </button>
      </div>

      <div v-if="group.items.length > 1" class="similar-compare-strip" role="listbox" aria-label="本组相似候选切换">
        <button
          v-for="(item, idx) in group.items"
          :key="item.assetId"
          type="button"
          class="similar-compare-thumb"
          :class="{ active: idx === activeIndex, trash: isTrash(item.assetId), best: item.recommended }"
          @click="emit('select-index', idx)"
        >
          <img :src="mediaPath('/api/v2/photos/' + item.assetId + '/thumbnail')" :alt="item.name" loading="lazy" />
          <span class="similar-compare-tag">
            {{ item.recommended ? "最佳" : isTrash(item.assetId) ? "清理" : "保留" }}
          </span>
        </button>
      </div>
    </div>

    <template #footer>
      <div class="similar-preview-footer">
        <div class="similar-preview-meta">
          <span class="similar-tabular">{{ formatBytes(activeItem.size) }}</span>
          <span v-if="activeItem.width && activeItem.height" class="similar-tabular">{{ activeItem.width }}×{{ activeItem.height }}</span>
          <span
            v-if="activeItem.recommended"
            class="similar-pill-badge best"
          >
            <Sparkles :size="11" /> 最佳画质
          </span>
          <span
            v-else-if="isTrash(activeItem.assetId)"
            class="similar-pill-badge trash"
          >
            <Trash2 :size="11" /> 可清理
          </span>
          <span
            v-for="badge in activeItem.qualityBadges ?? []"
            :key="badge"
            class="similar-pill-badge"
          >
            {{ badge }}
          </span>
          <span class="similar-key-hint">←/→ 键切换对比</span>
        </div>
        <div class="similar-preview-actions">
          <IsleButton
            v-if="activeItem.canTrash"
            :variant="isTrash(activeItem.assetId) ? 'tonal' : 'danger'"
            size="sm"
            @click="emit('toggle-candidate', activeItem.assetId, activeItem.canTrash)"
          >
            {{ isTrash(activeItem.assetId) ? "改为保留" : "标记为可清理" }}
          </IsleButton>
          <IsleButton variant="glass" size="sm" @click="emit('close')">关闭</IsleButton>
        </div>
      </div>
    </template>
  </IsleModal>
</template>

<style scoped>
.similar-compare-shell {
  display: flex;
  flex-direction: column;
  gap: 10px;
}
.similar-preview-stage,
.similar-split-stage {
  position: relative;
  border-radius: 12px;
  background: #0b0c0e;
  overflow: hidden;
}
.similar-preview-stage {
  display: grid;
  place-items: center;
  height: min(56vh, 500px);
}
.similar-preview-stage img {
  max-width: 100%;
  max-height: 100%;
  object-fit: contain;
}
.similar-split-stage {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 2px;
  height: min(56vh, 500px);
  background: #17191f;
}
.similar-split-pane {
  display: flex;
  flex-direction: column;
  min-width: 0;
  min-height: 0;
  background: #0b0c0e;
}
.similar-split-label {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 7px 12px;
  background: rgba(18, 20, 26, 0.92);
  color: rgba(255, 255, 255, 0.9);
  font-size: 11.5px;
  font-weight: 650;
  border-bottom: 1px solid rgba(255, 255, 255, 0.08);
}
.similar-split-label.is-best {
  color: #6ee7b7;
}
.similar-split-label.is-trash {
  color: #fca5a5;
}
.similar-split-label small {
  margin-left: auto;
  font-size: 11px;
  font-variant-numeric: tabular-nums;
  color: rgba(255, 255, 255, 0.68);
}
.similar-split-img-box {
  flex: 1;
  min-height: 0;
  display: grid;
  place-items: center;
  padding: 8px;
}
.similar-split-img-box img {
  max-width: 100%;
  max-height: 100%;
  object-fit: contain;
}
.similar-preview-nav {
  position: absolute;
  top: 50%;
  transform: translateY(-50%);
  z-index: 4;
  width: 34px;
  height: 34px;
  display: grid;
  place-items: center;
  border-radius: 999px;
  border: 1px solid rgba(255, 255, 255, 0.22);
  background: rgba(12, 13, 16, 0.72);
  color: #fff;
  cursor: pointer;
}
.similar-preview-nav.prev { left: 10px; }
.similar-preview-nav.next { right: 10px; }
.similar-compare-strip {
  display: flex;
  align-items: center;
  gap: 8px;
  overflow-x: auto;
  padding: 2px;
}
.similar-compare-thumb {
  position: relative;
  flex: 0 0 auto;
  width: 66px;
  height: 50px;
  padding: 0;
  border-radius: 8px;
  overflow: hidden;
  border: 2px solid transparent;
  opacity: 0.72;
  cursor: pointer;
  background: var(--surface-raised);
  transition: opacity 0.15s ease, transform 0.16s ease, border-color 0.15s ease;
}
.similar-compare-thumb.active {
  opacity: 1;
  border-color: var(--accent-primary);
  transform: scale(1.04);
}
.similar-compare-thumb img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}
.similar-compare-tag {
  position: absolute;
  right: 3px;
  bottom: 3px;
  padding: 1px 5px;
  border-radius: 999px;
  background: rgba(12, 14, 18, 0.78);
  color: #fff;
  font-size: 9.5px;
  font-weight: 650;
}
.similar-compare-thumb.best .similar-compare-tag {
  background: rgba(16, 185, 129, 0.9);
}
.similar-compare-thumb.trash .similar-compare-tag {
  background: rgba(225, 29, 72, 0.88);
}
.similar-preview-footer {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  flex-wrap: wrap;
  width: 100%;
}
.similar-preview-meta,
.similar-preview-actions {
  display: flex;
  align-items: center;
  gap: 6px;
  flex-wrap: wrap;
  font-size: 12px;
  color: var(--text-secondary);
}
.similar-tabular {
  font-variant-numeric: tabular-nums;
}
.similar-pill-badge {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  padding: 2px 8px;
  border-radius: 999px;
  font-size: 11px;
  font-weight: 600;
  background: var(--fluid-card-item-fill);
  border: 1px solid var(--fluid-card-border);
  color: var(--text-primary);
}
.similar-pill-badge.best {
  background: rgba(16, 185, 129, 0.16);
  border-color: rgba(16, 185, 129, 0.34);
  color: #059669;
}
[data-theme="dark"] .similar-pill-badge.best {
  color: #6ee7b7;
}
.similar-pill-badge.trash {
  background: rgba(239, 68, 68, 0.14);
  border-color: rgba(239, 68, 68, 0.3);
  color: #dc2626;
}
[data-theme="dark"] .similar-pill-badge.trash {
  color: #fca5a5;
}
.similar-key-hint {
  font-size: 11px;
  color: var(--text-tertiary);
}
@media (max-width: 720px) {
  .similar-split-stage {
    grid-template-columns: 1fr;
    height: min(64vh, 520px);
  }
}
@media (prefers-reduced-motion: reduce) {
  .similar-compare-thumb {
    transition: none;
  }
}
</style>
