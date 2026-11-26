<script setup lang="ts">
import { computed, onMounted, ref, watch } from "vue";
import { Sparkles, RefreshCw, Trash2, CheckCircle2, ZoomIn, Check } from "lucide-vue-next";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleCharts from "../../components/ui/IsleCharts.vue";
import PhotoSimilarComparisonModal from "./PhotoSimilarComparisonModal.vue";
import { ISLE_CHART_COLORS } from "../../components/ui/isleChartsMath.ts";
import { formatBytes, dateLabel } from "./photoPresentation.ts";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import { requestConfirm } from "../../composables/useConfirmDialog.ts";
import {
  selectRecommendedWasteIds,
  type SimilarPhotoCandidate,
  type SimilarPhotoGroup,
} from "./usePhotoAISearchAndPeople.ts";

const props = defineProps<{
  active: boolean;
  rootKey: string;
  api: <T = unknown>(url: string, method?: string, body?: object, signal?: AbortSignal) => Promise<T>;
  apiPath: (path: string) => string;
  mediaPath: (path: string) => string;
}>();

const emit = defineEmits<{
  (e: "trashed"): void;
}>();

const groups = ref<SimilarPhotoGroup[]>([]);
const quotaNote = ref("移入回收站后可随时恢复；个人空间配额将在从回收站永久删除后释放。");
const loading = ref(false);
const trashingGroupId = ref("");
const error = ref("");
const feedback = ref("");
const selections = ref<Record<string, number[]>>({});
const previewState = ref<{ groupId: string; index: number } | null>(null);

const activePreviewGroup = computed(() => {
  const state = previewState.value;
  if (!state) return null;
  return groups.value.find((g) => g.groupId === state.groupId) ?? null;
});

function openPreview(group: SimilarPhotoGroup, item: SimilarPhotoCandidate) {
  const idx = group.items.findIndex((candidate) => candidate.assetId === item.assetId);
  previewState.value = { groupId: group.groupId, index: idx >= 0 ? idx : 0 };
}

function stepPreview(delta: number) {
  const state = previewState.value;
  const group = activePreviewGroup.value;
  if (!state || !group || group.items.length <= 1) return;
  const len = group.items.length;
  previewState.value = {
    groupId: group.groupId,
    index: (state.index + delta + len) % len,
  };
}

function setPreviewIndex(index: number) {
  if (!activePreviewGroup.value) return;
  previewState.value = { groupId: activePreviewGroup.value.groupId, index };
}

const cleanupSavingsSummary = computed(() => {
  if (!groups.value.length) return null;
  let keepBytes = 0;
  let reclaimableBytes = 0;
  let trashCount = 0;
  for (const g of groups.value) {
    const trashSet = new Set(selections.value[g.groupId] ?? []);
    for (const item of g.items) {
      const size = Math.max(0, item.size || 0);
      if (trashSet.has(item.assetId)) {
        reclaimableBytes += size;
        trashCount += 1;
      } else {
        keepBytes += size;
      }
    }
  }
  const totalBytes = keepBytes + reclaimableBytes;
  if (totalBytes <= 0) return null;
  const savedPercent = Math.round((reclaimableBytes / totalBytes) * 100);
  return {
    totalBytes,
    savedPercent,
    trashCount,
    segments: [
      { key: "keep", label: "保留精选体积", value: keepBytes, color: ISLE_CHART_COLORS.blue, displayValue: formatBytes(keepBytes) },
      { key: "reclaim", label: "可释放冗余空间", value: reclaimableBytes, color: ISLE_CHART_COLORS.green, displayValue: formatBytes(reclaimableBytes) },
    ],
  };
});

async function loadSimilar() {
  loading.value = true;
  error.value = "";
  try {
    const res = await props.api<{ groups: SimilarPhotoGroup[]; quotaReleaseNote?: string }>(
      props.apiPath("/api/v2/photos/cleanup/similar"),
    );
    groups.value = Array.isArray(res.groups) ? res.groups : [];
    if (res.quotaReleaseNote) quotaNote.value = res.quotaReleaseNote;
    const nextSel: Record<string, number[]> = {};
    for (const g of groups.value) {
      nextSel[g.groupId] = selectRecommendedWasteIds(g);
    }
    selections.value = nextSel;
  } catch (e) {
    error.value = "读取相似照片失败：" + describeUserFacingError(e);
  } finally {
    loading.value = false;
  }
}

function isSelectedForTrash(groupId: string, assetId: number): boolean {
  return (selections.value[groupId] ?? []).includes(assetId);
}

function toggleCandidate(group: SimilarPhotoGroup, assetId: number, canTrash: boolean) {
  if (!canTrash) return;
  const current = new Set(selections.value[group.groupId] ?? []);
  if (current.has(assetId)) {
    current.delete(assetId);
  } else {
    if (current.size + 1 >= group.items.length) {
      error.value = "每组相似照片至少需要保留 1 张，不能全部勾选清理。";
      return;
    }
    current.add(assetId);
  }
  selections.value = { ...selections.value, [group.groupId]: [...current] };
}

function selectAutoWaste(group: SimilarPhotoGroup) {
  selections.value = { ...selections.value, [group.groupId]: selectRecommendedWasteIds(group) };
}

function onCardKeydown(event: KeyboardEvent, group: SimilarPhotoGroup, item: SimilarPhotoCandidate) {
  if (event.key === "ArrowRight" || event.key === "ArrowLeft") {
    const strip = (event.currentTarget as HTMLElement | null)?.parentElement;
    if (!strip) return;
    const cards = Array.from(strip.querySelectorAll<HTMLElement>(".similar-candidate-card"));
    const idx = cards.indexOf(event.currentTarget as HTMLElement);
    if (idx < 0 || cards.length <= 1) return;
    event.preventDefault();
    const next = cards[(idx + (event.key === "ArrowRight" ? 1 : -1) + cards.length) % cards.length];
    next?.focus();
  } else if (event.key === "Enter" || event.key === " ") {
    event.preventDefault();
    if (event.shiftKey) openPreview(group, item);
    else toggleCandidate(group, item.assetId, item.canTrash);
  }
}

async function trashGroupSelection(group: SimilarPhotoGroup) {
  const trashIds = selections.value[group.groupId] ?? [];
  if (!trashIds.length || trashingGroupId.value) return;
  const keepCandidate = group.items.find((it) => !trashIds.includes(it.assetId));
  if (!keepCandidate) {
    error.value = "每组相似照片至少需要保留 1 张原片。";
    return;
  }
  const confirmed = await requestConfirm({
    title: "确认将相似废片移入回收站？",
    message: `即将把已勾选的 ${trashIds.length} 张相似或连拍照片移入回收站，并保留「${keepCandidate.name}」不变。移入回收站后可随时恢复。`,
    confirmText: "移入回收站",
    cancelText: "取消",
    variant: "danger",
  });
  if (!confirmed) return;
  trashingGroupId.value = group.groupId;
  error.value = "";
  feedback.value = "";
  try {
    const res = await props.api<{ trashed: number; stagedTrashBytes: number; quotaReleaseNote?: string }>(
      props.apiPath("/api/v2/photos/cleanup/trash"),
      "POST",
      { keepAssetId: keepCandidate.assetId, trashAssetIds: trashIds },
    );
    feedback.value = `已将 ${res.trashed} 张相似废片安全移入回收站（约 ${formatBytes(res.stagedTrashBytes)}）。${res.quotaReleaseNote ?? quotaNote.value}`;
    await loadSimilar();
    emit("trashed");
  } catch (e) {
    error.value = "移入回收站失败：" + describeUserFacingError(e);
  } finally {
    trashingGroupId.value = "";
  }
}

watch(() => [props.active, props.rootKey], ([isActive]) => {
  if (isActive) void loadSimilar();
});

onMounted(() => {
  if (props.active) void loadSimilar();
});
</script>

<template>
  <section class="similar-cleanup-view" aria-label="相似废片与连拍对比清理">
    <header class="similar-header">
      <div>
        <h3>连拍与相似废片清理</h3>
        <p>结合清晰度、美学评分与人像睁眼状态自动推荐最佳成片；清理仅移入回收站，永不静默删除原片。</p>
      </div>
      <IsleButton variant="glass" size="sm" :loading="loading" @click="loadSimilar">
        <RefreshCw :size="14" /><span>重新分析</span>
      </IsleButton>
    </header>

    <IsleBanner v-if="error" type="error" compact closable :message="error" @close="error = ''" />
    <IsleBanner v-if="feedback" type="success" compact closable :message="feedback" @close="feedback = ''" />

    <IsleEmpty
      v-if="!groups.length && !loading"
      card
      :icon="CheckCircle2"
      title="暂未发现需要清理的连拍或相似废片"
      description="照片完成后台智能识图索引后，短时间内的连拍或近似构图会自动归组供你对比挑选。"
    />

    <div v-else class="similar-group-list">
      <div v-if="cleanupSavingsSummary" class="similar-savings-card" aria-label="相似废片空间瘦身比例预览">
        <IsleCharts
          kind="donut"
          :size="52"
          :stroke-width="6"
          :segments="cleanupSavingsSummary.segments"
          :total="cleanupSavingsSummary.totalBytes"
          :show-legend="false"
          :center-label="`省 ${cleanupSavingsSummary.savedPercent}%`"
          center-sublabel="可释放"
          :aria-label="`已勾选 ${cleanupSavingsSummary.trashCount} 张待清理照片，预计可释放 ${cleanupSavingsSummary.savedPercent}% 体积`"
        />
        <div class="similar-savings-body">
          <strong class="similar-tabular">当前已选 {{ cleanupSavingsSummary.trashCount }} 张相似冗余照片（共 {{ groups.length }} 组对比）</strong>
          <IsleCharts
            kind="segmented"
            :segments="cleanupSavingsSummary.segments"
            :total="cleanupSavingsSummary.totalBytes"
            :bar-height="9"
            compact-legend
            aria-label="保留精选体积与可释放冗余空间占比条"
          />
        </div>
      </div>

      <article v-for="group in groups" :key="group.groupId" class="similar-group-card">
        <div class="similar-group-top">
          <div class="similar-group-heading">
            <span class="similar-kind-pill">{{ group.kind === "burst" ? "手机连拍" : "相似构图" }}</span>
            <strong class="similar-tabular">{{ dateLabel(group.takenAt) }} · 共 {{ group.items.length }} 张</strong>
            <small class="similar-reason"><Sparkles :size="12" /> <span>{{ group.recommendReason }}</span></small>
          </div>
          <div class="similar-group-actions">
            <button type="button" class="refresh" @click="selectAutoWaste(group)">勾选非推荐项</button>
            <IsleButton
              variant="tonal"
              size="sm"
              :loading="trashingGroupId === group.groupId"
              :disabled="!(selections[group.groupId] ?? []).length"
              @click="trashGroupSelection(group)"
            >
              <Trash2 :size="13" />
              <span class="similar-tabular">移入回收站 ({{ (selections[group.groupId] ?? []).length }})</span>
            </IsleButton>
          </div>
        </div>

        <div class="similar-candidate-strip">
          <div
            v-for="item in group.items"
            :key="item.assetId"
            class="similar-candidate-card"
            :class="{
              'is-recommended': item.recommended,
              'is-marked-trash': isSelectedForTrash(group.groupId, item.assetId),
            }"
            tabindex="0"
            role="button"
            :aria-pressed="isSelectedForTrash(group.groupId, item.assetId)"
            @keydown="onCardKeydown($event, group, item)"
            @click="toggleCandidate(group, item.assetId, item.canTrash)"
          >
            <div class="similar-thumb-wrap">
              <img :src="mediaPath('/api/v2/photos/' + item.assetId + '/thumbnail')" :alt="item.name" loading="lazy" decoding="async" />
              <div v-if="(item.qualityBadges ?? []).length" class="similar-badge-list">
                <span
                  v-for="badge in item.qualityBadges ?? []"
                  :key="badge"
                  class="similar-badge"
                  :class="{ best: item.recommended }"
                >
                  {{ badge }}
                </span>
              </div>
              <button
                type="button"
                class="similar-zoom-btn"
                title="并排或放大对比查看"
                :aria-label="'对比查看 ' + item.name"
                @click.stop="openPreview(group, item)"
              >
                <ZoomIn :size="13" />
              </button>
              <span
                class="similar-status-pill"
                :class="{
                  best: item.recommended && !isSelectedForTrash(group.groupId, item.assetId),
                  trash: item.canTrash && isSelectedForTrash(group.groupId, item.assetId),
                }"
              >
                <template v-if="!item.canTrash">只读</template>
                <template v-else-if="isSelectedForTrash(group.groupId, item.assetId)">
                  <Trash2 :size="10" /> 可清理
                </template>
                <template v-else-if="item.recommended">
                  <Sparkles :size="10" /> 最佳画质
                </template>
                <template v-else>
                  <Check :size="10" /> 保留
                </template>
              </span>
            </div>
            <div class="similar-meta">
              <strong :title="item.name">{{ item.name }}</strong>
              <small class="similar-tabular">{{ formatBytes(item.size) }}<span v-if="item.width && item.height"> · {{ item.width }}×{{ item.height }}</span></small>
            </div>
          </div>
        </div>
      </article>
    </div>

    <p class="footnote">{{ quotaNote }}</p>

    <PhotoSimilarComparisonModal
      :group="activePreviewGroup"
      :active-index="previewState?.index ?? 0"
      :selected-for-trash="activePreviewGroup ? (selections[activePreviewGroup.groupId] ?? []) : []"
      :media-path="mediaPath"
      @close="previewState = null"
      @step="stepPreview($event)"
      @select-index="setPreviewIndex($event)"
      @toggle-candidate="(id, canTrash) => activePreviewGroup && toggleCandidate(activePreviewGroup, id, canTrash)"
    />
  </section>
</template>

<style scoped>
.similar-cleanup-view {
  display: flex;
  flex-direction: column;
  gap: 14px;
}
.similar-header {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
}
.similar-header h3 {
  margin: 0 0 3px;
  font-size: 15.5px;
  font-weight: 650;
}
.similar-header p {
  margin: 0;
  font-size: 12.5px;
  color: var(--text-secondary);
}
.similar-group-list {
  display: flex;
  flex-direction: column;
  gap: 12px;
}
.similar-savings-card {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 11px 14px;
  border-radius: 14px;
  background: var(--fluid-card-fill);
  border: 1px solid var(--fluid-card-border);
  box-shadow: var(--fluid-card-shadow);
}
.similar-savings-body {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 6px;
  font-size: 12.5px;
}
.similar-group-card {
  padding: 13px 15px;
  border-radius: 14px;
  background: var(--fluid-card-fill);
  border: 1px solid var(--fluid-card-border);
  box-shadow: var(--fluid-card-shadow);
  display: flex;
  flex-direction: column;
  gap: 10px;
  content-visibility: auto;
  contain-intrinsic-size: auto 240px;
}
.similar-group-top {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  font-size: 13px;
}
.similar-group-heading {
  min-width: 0;
  flex: 1 1 220px;
}
.similar-kind-pill {
  display: inline-block;
  padding: 2px 8px;
  margin-right: 6px;
  border-radius: 999px;
  font-size: 11px;
  font-weight: 600;
  background: color-mix(in srgb, var(--accent-primary) 12%, transparent);
  color: var(--accent-primary, #2563eb);
}
.similar-reason {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  margin-left: 8px;
  font-size: 11.5px;
  color: var(--text-secondary);
}
.similar-reason svg {
  flex-shrink: 0;
}
.similar-group-actions {
  display: flex;
  align-items: center;
  gap: 6px;
}
.similar-candidate-strip {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(188px, 1fr));
  gap: 10px;
}
.similar-candidate-card {
  border-radius: 12px;
  overflow: hidden;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
  cursor: pointer;
  transition: transform var(--motion-fast) var(--motion-spring), border-color var(--motion-fast) ease, opacity 0.16s ease, box-shadow 0.18s ease;
}
.similar-candidate-card:hover {
  transform: translateY(-1px);
  border-color: var(--fluid-card-border-strong, var(--accent-primary));
  box-shadow: var(--fluid-item-card-shadow);
}
.similar-candidate-card:focus-visible {
  outline: 2px solid var(--accent-primary);
  outline-offset: 2px;
}
.similar-candidate-card.is-marked-trash {
  opacity: 0.78;
}
.similar-thumb-wrap {
  position: relative;
  aspect-ratio: 4 / 3;
  background: var(--surface-raised);
}
.similar-thumb-wrap img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}
.similar-badge-list {
  position: absolute;
  left: 6px;
  top: 6px;
  display: flex;
  flex-wrap: wrap;
  gap: 4px;
  max-width: calc(100% - 12px);
  pointer-events: none;
}
.similar-badge {
  position: static;
  padding: 2px 7px;
  border-radius: 999px;
  font-size: 10.5px;
  font-weight: 600;
  background: rgba(12, 14, 18, 0.68);
  color: #fff;
}
.similar-badge.best {
  background: rgba(16, 185, 129, 0.9);
}
.similar-zoom-btn {
  position: absolute;
  left: 7px;
  bottom: 7px;
  width: 26px;
  height: 26px;
  display: grid;
  place-items: center;
  border: 1px solid rgba(255, 255, 255, 0.28);
  border-radius: 999px;
  background: rgba(12, 14, 18, 0.68);
  color: #fff;
  cursor: pointer;
}
.similar-zoom-btn:hover {
  background: rgba(12, 14, 18, 0.88);
}
.similar-status-pill {
  position: absolute;
  right: 7px;
  bottom: 7px;
  display: inline-flex;
  align-items: center;
  gap: 4px;
  padding: 3px 8px;
  border-radius: 999px;
  font-size: 10.5px;
  font-weight: 650;
  background: rgba(12, 14, 18, 0.72);
  color: #fff;
  border: 1px solid rgba(255, 255, 255, 0.16);
}
.similar-status-pill.best {
  background: rgba(5, 150, 105, 0.92);
  border-color: rgba(110, 231, 183, 0.45);
}
.similar-status-pill.trash {
  background: rgba(225, 29, 72, 0.88);
  border-color: rgba(253, 164, 175, 0.4);
}
.similar-meta {
  padding: 8px 10px;
  display: flex;
  flex-direction: column;
  gap: 2px;
}
.similar-meta strong {
  font-size: 12px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.similar-meta small {
  font-size: 11px;
  color: var(--text-secondary);
}
.similar-tabular {
  font-variant-numeric: tabular-nums;
}
@media (max-width: 680px) {
  .similar-candidate-strip {
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 8px;
  }
  .similar-group-top {
    align-items: flex-start;
  }
  .similar-reason {
    display: flex;
    margin-left: 0;
    margin-top: 4px;
  }
}
@media (prefers-reduced-motion: reduce) {
  .similar-candidate-card {
    transition: none;
  }
}
</style>
