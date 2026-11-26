<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue";
import {
  Check, Copy, ExternalLink, FileSearch, FileText, FolderArchive,
  LoaderCircle, RefreshCw, Sparkles, Upload,
} from "lucide-vue-next";
import { apiRequest } from "../../api/apiClient.ts";
import { describeRootOperationFailure } from "../../api/rootDiscovery.ts";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import { TIMINGS_MS } from "../../constants/timings.ts";
import { copyTextToClipboard } from "../../utils/clipboard.ts";
import AppleSelect from "../../components/ui/AppleSelect.vue";
import IsleBadge from "../../components/ui/IsleBadge.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleCard from "../../components/ui/IsleCard.vue";
import IsleChip from "../../components/ui/IsleChip.vue";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import IsleSearchInput from "../../components/ui/IsleSearchInput.vue";
import {
  buildDocsArchivePathPrefix,
  FAMILY_DOCS_CATEGORIES,
  FAMILY_DOCS_ROOT_FOLDER,
  type FamilyDocsCategory,
} from "../overview/familyRemindersApi.ts";
import { capturedLabel, formatBytes } from "./photoPresentation.ts";
import type { AssetAIDetail } from "./usePhotoAISearchAndPeople.ts";
import type { BatchAsset } from "./usePhotoBatchActions.ts";

interface StorageLocationReply {
  locations?: Array<{
    category: string;
    rootID: string;
    rootGeneration: number;
    relativePath: string;
  }>;
}

const props = defineProps<{
  active?: boolean;
  rootId?: string;
  rootGeneration?: number;
  admin: boolean;
  api: <T = unknown>(url: string, method?: string, body?: object, signal?: AbortSignal) => Promise<T>;
  apiPath: (path: string) => string;
  mediaPath: (path: string) => string;
  uploadRequest: (url: string, init?: RequestInit) => Promise<Response>;
}>();

const emit = defineEmits<{
  "open-asset": [asset: BatchAsset, list: BatchAsset[]];
}>();

const personalPhotosRoot = ref("");
const activeCategory = ref<"" | FamilyDocsCategory>("");
const searchInput = ref("");
const searchApplied = ref("");
const assets = ref<BatchAsset[]>([]);
const nextCursor = ref(0);
const loading = ref(false);
const error = ref("");
const statusNotice = ref("");

const selectedDoc = ref<BatchAsset | null>(null);
const docAIDetail = ref<AssetAIDetail | null>(null);
const docAILoading = ref(false);
const ocrPriorityBusy = ref(false);
const copiedOcr = ref(false);

const uploadCategory = ref<FamilyDocsCategory>("发票");
const uploading = ref(false);
const uploadProgressText = ref("");
const fileInputRef = ref<HTMLInputElement | null>(null);

let searchTimer: number | undefined;
let listAbort: AbortController | null = null;
let detailAbort: AbortController | null = null;
let copiedTimer: number | undefined;

const activePathPrefix = computed(() =>
  buildDocsArchivePathPrefix(personalPhotosRoot.value, activeCategory.value),
);

const uploadCategoryOptions = computed(() =>
  FAMILY_DOCS_CATEGORIES.map((cat) => ({ value: cat, label: `存入：${cat}` })),
);

async function resolvePersonalPhotosRoot() {
  try {
    const res = await apiRequest<StorageLocationReply>("/api/v2/me/storage");
    const locs = Array.isArray(res?.locations) ? res.locations : [];
    const exact = locs.find(
      (l) => l.category === "photos" && (!props.rootId || l.rootID === props.rootId),
    );
    const fallback = locs.find((l) => l.category === "photos");
    personalPhotosRoot.value = (exact?.relativePath || fallback?.relativePath || "").replace(/^\/+|\/+$/g, "");
  } catch {
    personalPhotosRoot.value = "";
  }
}

async function loadArchiveDocs(reset = true) {
  listAbort?.abort();
  const controller = new AbortController();
  listAbort = controller;
  loading.value = true;
  error.value = "";
  try {
    const query = new URLSearchParams({
      pathPrefix: activePathPrefix.value,
      limit: "48",
      cursor: String(reset ? 0 : nextCursor.value),
    });
    const term = searchApplied.value.trim();
    if (term) {
      query.set("searchMode", "ocr");
      query.set("q", term);
    }
    const res = await props.api<{ assets: BatchAsset[]; nextCursor: number }>(
      `${props.apiPath("/api/v2/photos")}?${query.toString()}`,
      "GET",
      undefined,
      controller.signal,
    );
    if (listAbort !== controller) return;
    const incoming = Array.isArray(res?.assets) ? res.assets : [];
    assets.value = reset ? incoming : [...assets.value, ...incoming];
    nextCursor.value = res?.nextCursor ?? 0;
    if (reset) {
      if (selectedDoc.value) {
        const stillExists = assets.value.find((a) => a.id === selectedDoc.value?.id) ?? null;
        selectedDoc.value = stillExists ?? assets.value[0] ?? null;
      } else {
        selectedDoc.value = assets.value[0] ?? null;
      }
    }
  } catch (err) {
    if (listAbort === controller && !(err instanceof Error && err.name === "AbortError")) {
      error.value = "读取家庭档案失败：" + describeRootOperationFailure(err);
    }
  } finally {
    if (listAbort === controller) loading.value = false;
  }
}

async function loadSelectedAIDetail(asset: BatchAsset | null) {
  detailAbort?.abort();
  detailAbort = null;
  docAIDetail.value = null;
  if (!asset || asset.type !== "photo") {
    docAILoading.value = false;
    return;
  }
  const controller = new AbortController();
  detailAbort = controller;
  docAILoading.value = true;
  try {
    const res = await props.api<AssetAIDetail>(
      props.apiPath(`/api/v2/photos/${asset.id}/ai`),
      "GET",
      undefined,
      controller.signal,
    );
    if (detailAbort === controller) docAIDetail.value = res;
  } catch {
    // Allow non-indexed items to trigger priority OCR smoothly.
  } finally {
    if (detailAbort === controller) docAILoading.value = false;
  }
}

async function triggerPriorityOCR(target: { path?: string; assetId?: number }) {
  ocrPriorityBusy.value = true;
  error.value = "";
  try {
    await props.api(props.apiPath("/api/v2/photos/ocr-priority"), "POST", target);
    statusNotice.value = "已加入 Vision 优先 OCR 识别队列，稍候刷新即可秒搜文中文字。";
    if (selectedDoc.value && (target.assetId === selectedDoc.value.id || target.path === selectedDoc.value.path)) {
      window.setTimeout(() => {
        if (selectedDoc.value) void loadSelectedAIDetail(selectedDoc.value);
      }, 1500);
    }
  } catch (err) {
    error.value = "触发优先 OCR 失败：" + describeUserFacingError(err);
  } finally {
    ocrPriorityBusy.value = false;
  }
}

async function ensureFolderExists(folderPath: string) {
  const parts = folderPath.split("/").filter(Boolean);
  let cur = "";
  for (const part of parts) {
    cur = cur ? `${cur}/${part}` : part;
    try {
      await props.api(props.apiPath("/api/v2/files/folders"), "POST", { path: cur });
    } catch {
      // Ignore already-exists or non-writable parent segments; upload call enforces real auth.
    }
  }
}

async function uploadSingleReceipt(file: File, targetDir: string): Promise<string> {
  const safeName = file.name.replace(/[\\/]+/g, "_") || `receipt_${Date.now()}.jpg`;
  const dest = `${targetDir}/${safeName}`;
  let state = await props.api<{ id: string; offset: number; size: number; path?: string }>(
    props.apiPath("/api/v2/uploads"),
    "POST",
    { path: dest, size: file.size, onConflict: "rename" },
  );
  const uploadEndpoint = props.apiPath(`/api/v2/uploads/${encodeURIComponent(state.id)}`);
  const chunkSize = 4 * 1024 * 1024;
  while (state.offset < file.size) {
    const chunk = file.slice(state.offset, Math.min(state.offset + chunkSize, file.size));
    const res = await props.uploadRequest(uploadEndpoint, {
      method: "PATCH",
      headers: { "X-Upload-Offset": String(state.offset) },
      body: chunk,
    });
    if (!res.ok) {
      throw new Error(`upload_chunk_failed_${res.status}`);
    }
    state = (await res.json()) as typeof state;
  }
  await props.api(`${uploadEndpoint}/complete`, "POST", {});
  return state.path || dest;
}

async function onReceiptFilesSelected(event: Event) {
  const input = event.target as HTMLInputElement | null;
  const files = Array.from(input?.files ?? []);
  if (input) input.value = "";
  if (!files.length || uploading.value) return;

  uploading.value = true;
  error.value = "";
  statusNotice.value = "";
  const targetDir = buildDocsArchivePathPrefix(personalPhotosRoot.value, uploadCategory.value);
  try {
    await ensureFolderExists(targetDir);
    let uploadedCount = 0;
    for (const file of files) {
      uploadProgressText.value = `正在上传并排队 OCR：${file.name} (${uploadedCount + 1}/${files.length})`;
      const publishedPath = await uploadSingleReceipt(file, targetDir);
      await props.api(props.apiPath("/api/v2/photos/ocr-priority"), "POST", { path: publishedPath });
      uploadedCount += 1;
    }
    statusNotice.value = `已归档 ${uploadedCount} 份票据至「${FAMILY_DOCS_ROOT_FOLDER}/${uploadCategory.value}」，并已插队执行离线 OCR 识别。`;
    if (activeCategory.value && activeCategory.value !== uploadCategory.value) {
      activeCategory.value = uploadCategory.value;
    } else {
      await loadArchiveDocs(true);
    }
  } catch (err) {
    error.value = "快捷归档失败：" + describeUserFacingError(err);
  } finally {
    uploading.value = false;
    uploadProgressText.value = "";
  }
}

async function copySelectedOcr() {
  const text = docAIDetail.value?.ocrText?.trim();
  if (!text) return;
  if (await copyTextToClipboard(text)) {
    copiedOcr.value = true;
    if (copiedTimer !== undefined) window.clearTimeout(copiedTimer);
    copiedTimer = window.setTimeout(() => { copiedOcr.value = false; }, TIMINGS_MS.COPIED_FEEDBACK);
  }
}

function selectCategory(cat: "" | FamilyDocsCategory) {
  activeCategory.value = cat;
  if (cat) uploadCategory.value = cat;
}

function submitSearch() {
  if (searchTimer) window.clearTimeout(searchTimer);
  searchApplied.value = searchInput.value.trim();
  void loadArchiveDocs(true);
}

function clearSearch() {
  if (searchTimer) window.clearTimeout(searchTimer);
  searchInput.value = "";
  if (searchApplied.value) {
    searchApplied.value = "";
    void loadArchiveDocs(true);
  }
}

watch(searchInput, (val) => {
  if (searchTimer) window.clearTimeout(searchTimer);
  searchTimer = window.setTimeout(() => {
    const term = val.trim();
    if (term === searchApplied.value) return;
    searchApplied.value = term;
    void loadArchiveDocs(true);
  }, TIMINGS_MS.SEARCH_DEBOUNCE);
});

watch(activeCategory, () => {
  void loadArchiveDocs(true);
});

watch(selectedDoc, (asset) => {
  void loadSelectedAIDetail(asset);
});

watch(
  () => [props.rootId, props.rootGeneration] as const,
  async () => {
    await resolvePersonalPhotosRoot();
    await loadArchiveDocs(true);
  },
);

onMounted(async () => {
  await resolvePersonalPhotosRoot();
  await loadArchiveDocs(true);
});

onBeforeUnmount(() => {
  if (searchTimer) window.clearTimeout(searchTimer);
  if (copiedTimer !== undefined) window.clearTimeout(copiedTimer);
  listAbort?.abort();
  detailAbort?.abort();
});
</script>

<template>
  <section class="docs-archive-view" aria-label="家庭档案 OCR 秒搜">
    <IsleCard padding="md" class="docs-archive-toolbar-card">
      <div class="docs-archive-top-row">
        <div class="docs-archive-heading">
          <div class="docs-archive-title-row">
            <FolderArchive :size="17" aria-hidden="true" />
            <h3>家庭档案 · 票据证件 OCR 秒搜</h3>
            <IsleBadge variant="accent" size="sm">{{ activePathPrefix }}</IsleBadge>
          </div>
          <p class="docs-archive-desc">
            仅检索家庭档案目录内的票据、证件、发票、保修与合同；支持输入任意文字（税号、单号、医院、金额）离线秒搜。
          </p>
        </div>

        <div class="docs-upload-cluster">
          <div class="docs-upload-select">
            <AppleSelect
              v-model="uploadCategory"
              :options="uploadCategoryOptions"
              size="sm"
              block
              aria-label="票据归档分类"
            />
          </div>
          <input
            ref="fileInputRef"
            type="file"
            accept="image/*"
            multiple
            class="docs-hidden-file-input"
            @change="onReceiptFilesSelected"
          />
          <IsleButton variant="primary" size="sm" :loading="uploading" @click="fileInputRef?.click()">
            <template #icon><Upload :size="14" /></template>
            {{ uploading ? "上传识别中…" : "快捷上传票据" }}
          </IsleButton>
          <IsleButton variant="glass" size="sm" :loading="loading" @click="loadArchiveDocs(true)">
            <template #icon><RefreshCw :size="14" /></template>
            刷新
          </IsleButton>
        </div>
      </div>

      <div class="docs-archive-filter-row">
        <div class="docs-category-chips" role="group" aria-label="档案分类筛选">
          <IsleChip small :selected="activeCategory === ''" @select="selectCategory('')">全部档案</IsleChip>
          <IsleChip
            v-for="cat in FAMILY_DOCS_CATEGORIES"
            :key="cat"
            small
            :selected="activeCategory === cat"
            @select="selectCategory(cat)"
          >
            {{ cat }}
          </IsleChip>
        </div>

        <div class="docs-search-box">
          <IsleSearchInput
            v-model="searchInput"
            placeholder="输入图中文字秒搜：发票号、保修期、姓名、公司…"
            aria-label="在家庭档案中按 OCR 文字搜索"
            @submit="submitSearch"
            @clear="clearSearch"
          />
        </div>
      </div>
    </IsleCard>

    <IsleBanner v-if="uploadProgressText" type="info" compact :message="uploadProgressText" />
    <IsleBanner v-if="statusNotice" type="success" compact closable :message="statusNotice" @close="statusNotice = ''" />
    <IsleBanner v-if="error" type="error" compact closable :message="error" @close="error = ''" />

    <div v-if="loading && !assets.length" class="docs-loading-strip" role="status">
      <LoaderCircle :size="16" class="docs-spin" />
      <span>正在检索家庭档案…</span>
    </div>

    <IsleEmpty
      v-else-if="!assets.length"
      card
      :icon="FileSearch"
      :title="searchApplied ? '没有找到包含该文字的档案' : '当前档案分类还没有文档'"
      :description="searchApplied ? '尝试换一个关键词，或切回「全部档案」查看全部已归档票据。' : '点击右上角「快捷上传票据」，照片会自动存入家庭档案并优先建立离线 OCR 索引。'"
    >
      <template #action>
        <IsleButton v-if="searchApplied" variant="tonal" size="sm" @click="clearSearch">清除搜索词</IsleButton>
        <IsleButton v-else variant="primary" size="sm" @click="fileInputRef?.click()">上传第一张票据</IsleButton>
      </template>
    </IsleEmpty>

    <div v-else class="docs-workspace-split">
      <div class="docs-grid-pane">
        <div class="docs-card-grid">
          <button
            v-for="asset in assets"
            :key="asset.id"
            type="button"
            class="docs-item-card"
            :class="{ 'is-selected': selectedDoc?.id === asset.id }"
            @click="selectedDoc = asset"
          >
            <div class="docs-thumb-wrap">
              <img
                :src="mediaPath('/api/v2/photos/' + asset.id + '/thumbnail')"
                :alt="asset.name"
                loading="lazy"
                decoding="async"
              />
            </div>
            <div class="docs-item-meta">
              <strong class="docs-item-name" :title="asset.name">{{ asset.name }}</strong>
              <small>{{ capturedLabel(asset) || formatBytes(asset.size) }}</small>
            </div>
          </button>
        </div>

        <div v-if="nextCursor > 0" class="docs-load-more">
          <IsleButton variant="glass" size="sm" :loading="loading" @click="loadArchiveDocs(false)">
            加载更多档案
          </IsleButton>
        </div>
      </div>

      <aside v-if="selectedDoc" class="docs-inspector-pane" aria-label="档案 OCR 文本详情">
        <div class="docs-inspector-head">
          <div class="docs-inspector-title">
            <FileText :size="15" aria-hidden="true" />
            <strong :title="selectedDoc.name">{{ selectedDoc.name }}</strong>
          </div>
          <IsleButton variant="glass" size="sm" @click="emit('open-asset', selectedDoc, assets)">
            <template #icon><ExternalLink :size="13" /></template>
            看大图
          </IsleButton>
        </div>

        <p class="docs-inspector-path">{{ selectedDoc.path }}</p>

        <div class="docs-ocr-header">
          <span>离线 OCR 识别文本</span>
          <div class="docs-ocr-actions">
            <IsleButton
              v-if="docAIDetail?.ocrText"
              variant="tonal"
              size="sm"
              @click="copySelectedOcr"
            >
              <template #icon><Check v-if="copiedOcr" :size="13" /><Copy v-else :size="13" /></template>
              {{ copiedOcr ? "已复制" : "一键复制文本" }}
            </IsleButton>
            <IsleButton
              variant="glass"
              size="sm"
              :loading="ocrPriorityBusy"
              @click="triggerPriorityOCR({ assetId: selectedDoc.id })"
            >
              <template #icon><Sparkles :size="13" /></template>
              优先识别
            </IsleButton>
          </div>
        </div>

        <div v-if="docAILoading" class="docs-ocr-placeholder">
          <LoaderCircle :size="15" class="docs-spin" /> 正在读取识别文本…
        </div>
        <pre v-else-if="docAIDetail?.ocrText" class="docs-ocr-text">{{ docAIDetail.ocrText }}</pre>
        <div v-else class="docs-ocr-placeholder">
          {{ docAIDetail?.indexed ? "该图片暂未识别到可读文字。" : "等待后台离线识图；点击「优先识别」可立即插队解析。" }}
        </div>
      </aside>
    </div>
  </section>
</template>

<style scoped>
.docs-archive-view { display: flex; flex-direction: column; gap: 12px; }
.docs-archive-top-row { display: flex; align-items: flex-start; justify-content: space-between; gap: 12px; flex-wrap: wrap; }
.docs-archive-heading { flex: 1 1 280px; min-width: 0; display: flex; flex-direction: column; gap: 4px; }
.docs-archive-title-row { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; color: var(--text-primary); }
.docs-archive-title-row h3 { margin: 0; font-size: 14.5px; font-weight: 650; }
.docs-archive-desc { margin: 0; font-size: 12px; color: var(--text-secondary); line-height: 1.45; }
.docs-upload-cluster { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.docs-upload-select { width: 136px; }
.docs-hidden-file-input { display: none; }
.docs-archive-filter-row {
  margin-top: 12px; padding-top: 10px; border-top: 1px solid var(--fluid-divider, var(--fluid-card-border));
  display: flex; align-items: center; justify-content: space-between; gap: 10px; flex-wrap: wrap;
}
.docs-category-chips { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; }
.docs-search-box { flex: 1 1 260px; max-width: 420px; }
.docs-loading-strip {
  display: flex; align-items: center; gap: 8px; padding: 18px; border-radius: 14px;
  background: var(--fluid-card-item-fill); color: var(--text-secondary); font-size: 13px;
}
.docs-workspace-split { display: grid; grid-template-columns: minmax(0, 1fr) minmax(290px, 360px); gap: 14px; align-items: start; }
.docs-grid-pane { display: flex; flex-direction: column; gap: 12px; min-width: 0; }
.docs-card-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(156px, 1fr)); gap: 10px; }
.docs-item-card {
  display: flex; flex-direction: column; padding: 6px; border-radius: 13px; text-align: left;
  border: 1px solid var(--fluid-card-border); background: var(--fluid-card-top); cursor: pointer;
  transition: border-color 0.15s ease, transform 0.15s ease;
}
.docs-item-card:hover { border-color: var(--fluid-card-border-strong); }
.docs-item-card.is-selected {
  border-color: var(--accent-primary);
  box-shadow: 0 0 0 2px color-mix(in srgb, var(--accent-primary) 22%, transparent);
}
.docs-thumb-wrap {
  width: 100%; aspect-ratio: 4 / 3; border-radius: 9px; overflow: hidden;
  background: var(--fluid-card-item-fill);
}
.docs-thumb-wrap img { width: 100%; height: 100%; object-fit: cover; display: block; }
.docs-item-meta { display: flex; flex-direction: column; gap: 2px; padding: 6px 3px 2px; min-width: 0; }
.docs-item-name {
  font-size: 12.5px; font-weight: 600; color: var(--text-primary);
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.docs-item-meta small { font-size: 11px; color: var(--text-tertiary); font-variant-numeric: tabular-nums; }
.docs-load-more { display: flex; justify-content: center; }
.docs-inspector-pane {
  position: sticky; top: 14px; padding: 14px; border-radius: 16px;
  border: 1px solid var(--fluid-card-border); background: var(--fluid-card-top);
  display: flex; flex-direction: column; gap: 10px;
}
.docs-inspector-head { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
.docs-inspector-title { display: flex; align-items: center; gap: 6px; min-width: 0; color: var(--text-primary); }
.docs-inspector-title strong { font-size: 13.5px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.docs-inspector-path {
  margin: 0; font-size: 11px; color: var(--text-tertiary); word-break: break-all;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
}
.docs-ocr-header { display: flex; align-items: center; justify-content: space-between; gap: 8px; flex-wrap: wrap; font-size: 12px; font-weight: 650; color: var(--text-secondary); }
.docs-ocr-actions { display: inline-flex; align-items: center; gap: 6px; }
.docs-ocr-text {
  margin: 0; padding: 11px 12px; max-height: 360px; overflow-y: auto;
  white-space: pre-wrap; word-break: break-word; font-family: inherit; font-size: 12.5px; line-height: 1.55;
  border-radius: 11px; border: 1px solid var(--fluid-card-border); background: var(--fluid-card-item-fill);
  color: var(--text-primary); user-select: text;
}
.docs-ocr-placeholder {
  display: flex; align-items: center; gap: 6px; padding: 14px 12px; border-radius: 11px;
  border: 1px dashed var(--fluid-card-border); background: var(--fluid-card-item-fill);
  font-size: 12px; color: var(--text-secondary);
}
.docs-spin { animation: docsSpin 1s linear infinite; }
@keyframes docsSpin { to { transform: rotate(360deg); } }
@media (max-width: 900px) {
  .docs-workspace-split { grid-template-columns: minmax(0, 1fr); }
  .docs-inspector-pane { position: static; }
}
@media (prefers-reduced-motion: reduce) {
  .docs-item-card { transition: none; }
  .docs-spin { animation: none; }
}
</style>
