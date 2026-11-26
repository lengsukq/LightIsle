<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from "vue";
import {
  BookOpen, ChevronLeft, ChevronRight, Columns, Download, FileArchive,
  List, Minus, Plus, Rows3,
} from "lucide-vue-next";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import IsleModal from "../../components/ui/IsleModal.vue";
import { readApiFailure } from "../../api/apiFailure.ts";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import type { SharedFileEntry } from "./useFileShares.ts";
import {
  computeReadingPercent,
  encodeComicLocator,
  encodeEpubLocator,
  extractEpubBodyAndRewriteImages,
  parseComicLocator,
  parseEpubContainerOpfPath,
  parseEpubLocator,
  parseEpubNcxTitles,
  parseEpubOpf,
  type ArchiveEntryDescriptor,
  type EpubChapterItem,
} from "./fileReaderSupport.ts";

interface ArchiveEntriesResponse {
  path: string;
  format: "cbz" | "zip" | "epub";
  size: number;
  mtimeUnixNano: number;
  entryCount: number;
  entries: ArchiveEntryDescriptor[];
}

interface ReadingProgressRecord {
  rootId: string;
  rootGeneration: number;
  path: string;
  locator: string;
  percent: number;
  updatedAt: number;
}

const PREFS_KEY = "lightisle:reader-prefs";

const props = defineProps<{
  file: SharedFileEntry | null;
  canWrite: boolean;
  extracting: boolean;
  scopedApiPath: (path: string) => string;
  scopedMediaPath: (path: string) => string;
  rootFetch: (endpoint: string, init?: RequestInit) => Promise<Response>;
  jsonGet: <T>(endpoint: string) => Promise<T>;
  jsonWrite: <T>(endpoint: string, method: "PUT", body?: object) => Promise<T>;
  isAbortError: (error: unknown) => boolean;
}>();

const emit = defineEmits<{
  close: [];
  download: [file: SharedFileEntry];
  extractZip: [file: SharedFileEntry];
}>();

function loadReaderPrefs(): { fontSize: number; theme: "system" | "sepia" | "dark"; comicMode: "single" | "strip" } {
  try {
    const raw = typeof localStorage !== "undefined" ? localStorage.getItem(PREFS_KEY) : null;
    if (raw) {
      const parsed = JSON.parse(raw) as Partial<{ fontSize: number; theme: string; comicMode: string }>;
      return {
        fontSize: typeof parsed.fontSize === "number" ? Math.max(14, Math.min(24, parsed.fontSize)) : 16,
        theme: parsed.theme === "sepia" || parsed.theme === "dark" ? parsed.theme : "system",
        comicMode: parsed.comicMode === "strip" ? "strip" : "single",
      };
    }
  } catch {
    // Ignore storage errors.
  }
  return { fontSize: 16, theme: "system", comicMode: "single" };
}

const initPrefs = loadReaderPrefs();
const loading = ref(false);
const error = ref("");
const archiveFormat = ref<"cbz" | "zip" | "epub">("cbz");
const imageEntries = ref<ArchiveEntryDescriptor[]>([]);
const comicMode = ref<"single" | "strip">(initPrefs.comicMode);
const comicPageIndex = ref(0);
const comicStripRef = ref<HTMLElement | null>(null);

const epubTitle = ref("");
const epubAuthor = ref("");
const epubChapters = ref<EpubChapterItem[]>([]);
const epubChapterIndex = ref(0);
const epubChapterHtml = ref("");
const epubChapterLoading = ref(false);
const epubTocOpen = ref(false);
const epubFontSize = ref(initPrefs.fontSize);
const epubTheme = ref<"system" | "sepia" | "dark">(initPrefs.theme);
const epubScrollRef = ref<HTMLElement | null>(null);

const restoredNotice = ref("");
const progressSaving = ref(false);

let loadSeq = 0;
let chapterSeq = 0;
let saveProgressTimer: number | null = null;
let pendingProgressPayload: { path: string; locator: string; percent: number } | null = null;
let domPurifyPromise: Promise<{ sanitize: (dirty: string, cfg?: Record<string, unknown>) => string }> | null = null;

async function getDomPurify() {
  if (!domPurifyPromise) {
    domPurifyPromise = import("dompurify").then((mod) => mod.default);
  }
  return domPurifyPromise;
}

function persistPrefs() {
  try {
    localStorage.setItem(
      PREFS_KEY,
      JSON.stringify({ fontSize: epubFontSize.value, theme: epubTheme.value, comicMode: comicMode.value }),
    );
  } catch {
    // Ignore storage errors.
  }
}

watch([epubFontSize, epubTheme, comicMode], persistPrefs);

const isEpub = computed(() => archiveFormat.value === "epub");
const currentImage = computed(() => imageEntries.value[comicPageIndex.value] ?? null);
const currentChapter = computed(() => epubChapters.value[epubChapterIndex.value] ?? null);

const readingPercent = computed(() =>
  isEpub.value
    ? computeReadingPercent(epubChapterIndex.value, epubChapters.value.length)
    : computeReadingPercent(comicPageIndex.value, imageEntries.value.length),
);

function buildEntryMediaUrl(entryName: string): string {
  if (!props.file) return "";
  return props.scopedMediaPath(
    "/api/v2/files/archive-entry?path=" + encodeURIComponent(props.file.path) + "&entry=" + encodeURIComponent(entryName),
  );
}

async function fetchArchiveEntryText(filePath: string, entryName: string): Promise<string> {
  const response = await props.rootFetch(
    props.scopedApiPath("/api/v2/files/archive-entry") +
      "?path=" + encodeURIComponent(filePath) +
      "&entry=" + encodeURIComponent(entryName),
    { credentials: "same-origin" },
  );
  if (!response.ok) throw await readApiFailure(response);
  return response.text();
}

function scheduleProgressSave() {
  const target = props.file;
  if (!target) return;
  const total = isEpub.value ? epubChapters.value.length : imageEntries.value.length;
  if (total <= 0) return;

  const locator = isEpub.value
    ? encodeEpubLocator(epubChapterIndex.value, currentEpubScrollRatio())
    : encodeComicLocator(comicPageIndex.value, comicMode.value);
  const percent = readingPercent.value;

  pendingProgressPayload = { path: target.path, locator, percent };
  if (saveProgressTimer !== null && typeof window !== "undefined") {
    window.clearTimeout(saveProgressTimer);
  }
  if (typeof window !== "undefined") {
    saveProgressTimer = window.setTimeout(() => {
      saveProgressTimer = null;
      void flushProgressSave();
    }, 800);
  }
}

async function flushProgressSave() {
  if (saveProgressTimer !== null && typeof window !== "undefined") {
    window.clearTimeout(saveProgressTimer);
    saveProgressTimer = null;
  }
  const payload = pendingProgressPayload;
  if (!payload) return;
  pendingProgressPayload = null;
  progressSaving.value = true;
  try {
    await props.jsonWrite(props.scopedApiPath("/api/v2/files/reading-progress"), "PUT", payload);
  } catch {
    // Non-blocking best-effort reading progress sync.
  } finally {
    progressSaving.value = false;
  }
}

function currentEpubScrollRatio(): number {
  const el = epubScrollRef.value;
  if (!el) return 0;
  const max = el.scrollHeight - el.clientHeight;
  return max > 0 ? Math.max(0, Math.min(1, el.scrollTop / max)) : 0;
}

async function loadEpubChapter(index: number, restoreScrollRatio = 0) {
  const target = props.file;
  const chapter = epubChapters.value[index];
  if (!target || !chapter) return;
  const seq = ++chapterSeq;
  epubChapterIndex.value = index;
  epubChapterLoading.value = true;
  error.value = "";
  try {
    const raw = await fetchArchiveEntryText(target.path, chapter.entryPath);
    if (seq !== chapterSeq) return;
    const rewritten = extractEpubBodyAndRewriteImages(raw, chapter.entryPath, buildEntryMediaUrl);
    const DOMPurify = await getDomPurify();
    if (seq !== chapterSeq) return;
    epubChapterHtml.value = DOMPurify.sanitize(rewritten, {
      USE_PROFILES: { html: true },
      FORBID_TAGS: ["script", "style", "iframe", "object", "embed", "form"],
      FORBID_ATTR: ["onerror", "onload", "onclick"],
    });
    await nextTick();
    const el = epubScrollRef.value;
    if (el) {
      const max = el.scrollHeight - el.clientHeight;
      el.scrollTop = restoreScrollRatio > 0 && max > 0 ? Math.round(max * restoreScrollRatio) : 0;
    }
    scheduleProgressSave();
  } catch (err) {
    if (seq === chapterSeq && !props.isAbortError(err)) {
      error.value = "加载章节内容失败：" + describeUserFacingError(err);
    }
  } finally {
    if (seq === chapterSeq) epubChapterLoading.value = false;
  }
}

async function loadArchiveReader() {
  const target = props.file;
  if (!target) return;
  const seq = ++loadSeq;
  loading.value = true;
  error.value = "";
  restoredNotice.value = "";
  imageEntries.value = [];
  epubChapters.value = [];
  epubChapterHtml.value = "";
  epubTitle.value = "";
  epubAuthor.value = "";
  epubTocOpen.value = false;
  comicPageIndex.value = 0;
  epubChapterIndex.value = 0;

  try {
    const [entriesRes, progressRes] = await Promise.all([
      props.jsonGet<ArchiveEntriesResponse>(
        props.scopedApiPath("/api/v2/files/archive-entries") + "?path=" + encodeURIComponent(target.path),
      ),
      props
        .jsonGet<{ found: boolean; progress?: ReadingProgressRecord }>(
          props.scopedApiPath("/api/v2/files/reading-progress") + "?path=" + encodeURIComponent(target.path),
        )
        .catch(() => ({ found: false, progress: undefined })),
    ]);
    if (seq !== loadSeq) return;

    archiveFormat.value = entriesRes.format;
    const allEntries = Array.isArray(entriesRes.entries) ? entriesRes.entries : [];

    if (entriesRes.format === "epub") {
      let opfPath = "";
      const containerEntry = allEntries.find((e) => e.name.toLowerCase() === "meta-inf/container.xml");
      if (containerEntry) {
        const containerXml = await fetchArchiveEntryText(target.path, containerEntry.name).catch(() => "");
        opfPath = parseEpubContainerOpfPath(containerXml);
      }
      if (!opfPath) {
        opfPath = allEntries.find((e) => e.name.toLowerCase().endsWith(".opf"))?.name ?? "";
      }
      let opfXml = "";
      if (opfPath) {
        opfXml = await fetchArchiveEntryText(target.path, opfPath).catch(() => "");
      }
      const ncxEntry = allEntries.find((e) => e.name.toLowerCase().endsWith(".ncx"));
      let ncxTitles: Map<string, string> | undefined;
      if (ncxEntry) {
        const ncxXml = await fetchArchiveEntryText(target.path, ncxEntry.name).catch(() => "");
        if (ncxXml) ncxTitles = parseEpubNcxTitles(ncxXml, ncxEntry.name);
      }
      if (seq !== loadSeq) return;
      const summary = parseEpubOpf(opfXml, opfPath, allEntries, ncxTitles);
      epubTitle.value = summary.title || target.name;
      epubAuthor.value = summary.creator;
      epubChapters.value = summary.chapters;

      let startChapter = 0;
      let startScroll = 0;
      if (progressRes.found && progressRes.progress?.locator) {
        const parsed = parseEpubLocator(progressRes.progress.locator);
        startChapter = Math.max(0, Math.min(summary.chapters.length - 1, parsed.chapterIndex));
        startScroll = parsed.scrollRatio;
        if (startChapter > 0 || startScroll > 0.02) {
          restoredNotice.value = `已恢复上次阅读进度（${Math.round(progressRes.progress.percent)}%）`;
        }
      }
      if (summary.chapters.length > 0) {
        await loadEpubChapter(startChapter, startScroll);
      }
    } else {
      const images = allEntries.filter((e) => e.kind === "image");
      imageEntries.value = images;
      if (images.length > 0 && progressRes.found && progressRes.progress?.locator) {
        const parsed = parseComicLocator(progressRes.progress.locator);
        if (parsed.mode) comicMode.value = parsed.mode;
        comicPageIndex.value = Math.max(0, Math.min(images.length - 1, parsed.pageIndex));
        if (comicPageIndex.value > 0) {
          restoredNotice.value = `已恢复上次进度：第 ${comicPageIndex.value + 1} / ${images.length} 页`;
        }
      }
    }
  } catch (err) {
    if (seq !== loadSeq || props.isAbortError(err)) return;
    const code = err instanceof Error ? err.message : "";
    const map: Record<string, string> = {
      archive_limit_exceeded: "该归档体积或条目数超出在线阅读安全上限，请下载原件本地查看。",
      invalid_zip_archive: "无法解析该归档文件，可能已损坏或非标准 ZIP/EPUB 容器。",
    };
    error.value = map[code] ?? "打开阅读器失败：" + describeUserFacingError(err);
  } finally {
    if (seq === loadSeq) loading.value = false;
  }
}

watch(
  () => props.file?.path,
  (path) => {
    if (path) {
      void loadArchiveReader();
    } else {
      void flushProgressSave();
      loadSeq += 1;
      chapterSeq += 1;
      imageEntries.value = [];
      epubChapters.value = [];
      epubChapterHtml.value = "";
      error.value = "";
    }
  },
  { immediate: true },
);

function setComicPage(nextIndex: number) {
  const total = imageEntries.value.length;
  if (!total) return;
  comicPageIndex.value = Math.max(0, Math.min(total - 1, nextIndex));
  scheduleProgressSave();
}

function onComicRangeInput(event: Event) {
  const val = Number((event.target as HTMLInputElement).value);
  if (Number.isFinite(val)) setComicPage(val);
}

function onComicStripScroll() {
  const container = comicStripRef.value;
  if (!container || comicMode.value !== "strip") return;
  const pages = container.querySelectorAll<HTMLElement>("[data-comic-page]");
  const topEdge = container.scrollTop + 48;
  let current = comicPageIndex.value;
  for (let i = 0; i < pages.length; i += 1) {
    if (pages[i].offsetTop <= topEdge) current = i;
    else break;
  }
  if (current !== comicPageIndex.value) {
    comicPageIndex.value = current;
    scheduleProgressSave();
  }
}

function switchComicMode(nextMode: "single" | "strip") {
  comicMode.value = nextMode;
  scheduleProgressSave();
  if (nextMode === "strip") {
    void nextTick(() => {
      const target = comicStripRef.value?.querySelector<HTMLElement>(`[data-comic-page="${comicPageIndex.value}"]`);
      target?.scrollIntoView({ behavior: "auto", block: "start" });
    });
  }
}

function handleKeydown(event: KeyboardEvent) {
  if (!props.file || loading.value) return;
  const tag = (event.target as HTMLElement | null)?.tagName;
  if (tag === "INPUT" || tag === "TEXTAREA") return;
  if (!isEpub.value && comicMode.value === "single" && imageEntries.value.length > 0) {
    if (event.key === "ArrowRight" || event.key === " ") {
      event.preventDefault();
      setComicPage(comicPageIndex.value + 1);
    } else if (event.key === "ArrowLeft") {
      event.preventDefault();
      setComicPage(comicPageIndex.value - 1);
    }
  } else if (isEpub.value && epubChapters.value.length > 0) {
    if (event.key === "ArrowRight" && epubChapterIndex.value < epubChapters.value.length - 1) {
      event.preventDefault();
      void loadEpubChapter(epubChapterIndex.value + 1);
    } else if (event.key === "ArrowLeft" && epubChapterIndex.value > 0) {
      event.preventDefault();
      void loadEpubChapter(epubChapterIndex.value - 1);
    }
  }
}

function handleClose() {
  void flushProgressSave();
  emit("close");
}

onMounted(() => window.addEventListener("keydown", handleKeydown));
onUnmounted(() => {
  window.removeEventListener("keydown", handleKeydown);
  void flushProgressSave();
});
</script>

<template>
  <IsleModal
    :open="Boolean(file)"
    :title="isEpub ? (epubTitle || file?.name || 'EPUB 阅读器') : (file?.name || '漫画阅读器')"
    size="wide"
    role="dialog"
    aria-label="漫画与 EPUB 轻阅读器"
    @close="handleClose"
  >
    <template #icon><BookOpen :size="17" /></template>

    <div v-if="file" class="reader-shell">
      <div class="reader-toolbar">
        <div class="reader-toolbar-left">
          <template v-if="!isEpub && imageEntries.length">
            <div class="reader-seg" role="tablist" aria-label="漫画阅读模式">
              <button
                type="button"
                role="tab"
                :aria-selected="comicMode === 'single' ? 'true' : 'false'"
                class="reader-seg-btn"
                :class="{ 'is-active': comicMode === 'single' }"
                @click="switchComicMode('single')"
              >
                <Columns :size="13" /> 单页
              </button>
              <button
                type="button"
                role="tab"
                :aria-selected="comicMode === 'strip' ? 'true' : 'false'"
                class="reader-seg-btn"
                :class="{ 'is-active': comicMode === 'strip' }"
                @click="switchComicMode('strip')"
              >
                <Rows3 :size="13" /> 条漫竖滑
              </button>
            </div>
            <span class="reader-pill">第 {{ comicPageIndex + 1 }} / {{ imageEntries.length }} 页 · {{ Math.round(readingPercent) }}%</span>
          </template>

          <template v-else-if="isEpub && epubChapters.length">
            <IsleButton type="button" variant="glass" size="sm" :selected="epubTocOpen" @click="epubTocOpen = !epubTocOpen">
              <template #icon><List :size="13" /></template>
              目录 ({{ epubChapters.length }})
            </IsleButton>
            <div class="reader-font-ctrl" aria-label="字号调节">
              <button type="button" class="reader-icon-btn" :disabled="epubFontSize <= 14" aria-label="减小字号" @click="epubFontSize = Math.max(14, epubFontSize - 1)"><Minus :size="13" /></button>
              <span>{{ epubFontSize }}px</span>
              <button type="button" class="reader-icon-btn" :disabled="epubFontSize >= 24" aria-label="增大字号" @click="epubFontSize = Math.min(24, epubFontSize + 1)"><Plus :size="13" /></button>
            </div>
            <div class="reader-seg" role="radiogroup" aria-label="阅读主题">
              <button type="button" role="radio" :aria-checked="epubTheme === 'system' ? 'true' : 'false'" class="reader-seg-btn" :class="{ 'is-active': epubTheme === 'system' }" @click="epubTheme = 'system'">默认</button>
              <button type="button" role="radio" :aria-checked="epubTheme === 'sepia' ? 'true' : 'false'" class="reader-seg-btn" :class="{ 'is-active': epubTheme === 'sepia' }" @click="epubTheme = 'sepia'">护眼</button>
              <button type="button" role="radio" :aria-checked="epubTheme === 'dark' ? 'true' : 'false'" class="reader-seg-btn" :class="{ 'is-active': epubTheme === 'dark' }" @click="epubTheme = 'dark'">夜间</button>
            </div>
            <span class="reader-pill">{{ Math.round(readingPercent) }}%</span>
          </template>
        </div>

        <div class="reader-toolbar-right">
          <span v-if="restoredNotice" class="reader-restored-pill">{{ restoredNotice }}</span>
          <IsleButton type="button" variant="glass" size="sm" @click="emit('download', file)">
            <template #icon><Download :size="13" /></template>
            下载
          </IsleButton>
        </div>
      </div>

      <IsleBanner v-if="error" type="error" compact :message="error" />

      <div v-if="loading" class="reader-loading" role="status">正在免解压读取归档目录与阅读进度…</div>

      <!-- Comic Reader -->
      <template v-else-if="!isEpub">
        <IsleEmpty
          v-if="!imageEntries.length"
          compact
          :icon="FileArchive"
          title="压缩包内没有可浏览的图片页"
          description="可将其解压到同名文件夹或直接下载原件查看全部内容。"
        >
          <template #action>
            <div class="reader-empty-actions">
              <IsleButton
                v-if="canWrite && /\.zip$/i.test(file.name)"
                variant="tonal"
                size="sm"
                :loading="extracting"
                @click="emit('extractZip', file); handleClose()"
              >
                解压到同名文件夹
              </IsleButton>
              <IsleButton variant="primary" size="sm" @click="emit('download', file)">下载原件</IsleButton>
            </div>
          </template>
        </IsleEmpty>

        <div v-else-if="comicMode === 'single' && currentImage" class="comic-single-stage">
          <div class="comic-canvas">
            <button type="button" class="comic-nav-btn is-prev" :disabled="comicPageIndex <= 0" aria-label="上一页" @click="setComicPage(comicPageIndex - 1)">
              <ChevronLeft :size="20" />
            </button>
            <img :src="buildEntryMediaUrl(currentImage.name)" :alt="currentImage.name" class="comic-single-img" />
            <button type="button" class="comic-nav-btn is-next" :disabled="comicPageIndex >= imageEntries.length - 1" aria-label="下一页" @click="setComicPage(comicPageIndex + 1)">
              <ChevronRight :size="20" />
            </button>
          </div>
          <div class="comic-pager">
            <span>1</span>
            <input
              type="range"
              :min="0"
              :max="Math.max(0, imageEntries.length - 1)"
              :value="comicPageIndex"
              aria-label="漫画页码进度条"
              class="comic-range"
              @input="onComicRangeInput"
            />
            <span>{{ imageEntries.length }}</span>
          </div>
        </div>

        <div v-else ref="comicStripRef" class="comic-strip-stage" @scroll.passive="onComicStripScroll">
          <figure v-for="(img, idx) in imageEntries" :key="img.name" :data-comic-page="idx" class="comic-strip-item">
            <img :src="buildEntryMediaUrl(img.name)" :alt="img.name" loading="lazy" decoding="async" />
            <figcaption>{{ idx + 1 }} / {{ imageEntries.length }}</figcaption>
          </figure>
        </div>
      </template>

      <!-- EPUB Reader -->
      <template v-else>
        <IsleEmpty v-if="!epubChapters.length" compact :icon="BookOpen" title="未在 EPUB 中找到可阅读章节" description="请下载原件使用系统图书应用打开。" />
        <div v-else class="epub-layout" :class="{ 'has-toc': epubTocOpen }">
          <aside v-if="epubTocOpen" class="epub-toc" aria-label="章节目录">
            <div v-if="epubAuthor" class="epub-author">作者：{{ epubAuthor }}</div>
            <button
              v-for="(ch, idx) in epubChapters"
              :key="ch.id + idx"
              type="button"
              class="epub-toc-item"
              :class="{ 'is-active': idx === epubChapterIndex }"
              @click="loadEpubChapter(idx)"
            >
              <span>{{ ch.title }}</span>
            </button>
          </aside>

          <div
            ref="epubScrollRef"
            class="epub-reader-pane"
            :class="['theme-' + epubTheme]"
            :style="{ fontSize: epubFontSize + 'px' }"
            @scroll.passive="scheduleProgressSave"
          >
            <div v-if="epubChapterLoading" class="reader-loading" role="status">正在加载章节…</div>
            <article v-else class="epub-chapter-body" v-html="epubChapterHtml"></article>
            <div v-if="!epubChapterLoading" class="epub-chapter-nav">
              <IsleButton type="button" variant="glass" size="sm" :disabled="epubChapterIndex <= 0" @click="loadEpubChapter(epubChapterIndex - 1)">
                <template #icon><ChevronLeft :size="14" /></template>上一章
              </IsleButton>
              <span class="epub-chapter-label">{{ currentChapter?.title }} ({{ epubChapterIndex + 1 }}/{{ epubChapters.length }})</span>
              <IsleButton type="button" variant="glass" size="sm" :disabled="epubChapterIndex >= epubChapters.length - 1" @click="loadEpubChapter(epubChapterIndex + 1)">
                下一章<template #icon><ChevronRight :size="14" /></template>
              </IsleButton>
            </div>
          </div>
        </div>
      </template>
    </div>

    <template #footer>
      <div class="reader-footer">
        <small class="reader-footer-hint">{{ progressSaving ? "正在同步跨端阅读进度…" : "阅读进度将自动跨设备同步 · 支持 ← / → 方向键翻页" }}</small>
        <IsleButton variant="glass" @click="handleClose">关闭</IsleButton>
      </div>
    </template>
  </IsleModal>
</template>

<style scoped>
.reader-shell { display: grid; gap: 10px; }
.reader-toolbar { display: flex; align-items: center; justify-content: space-between; gap: 8px; flex-wrap: wrap; }
.reader-toolbar-left, .reader-toolbar-right { display: inline-flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.reader-seg { display: inline-flex; align-items: center; gap: 3px; padding: 3px; border-radius: 9px; border: 1px solid var(--fluid-card-border); background: var(--fluid-card-item-fill); }
.reader-seg-btn { display: inline-flex; align-items: center; gap: 4px; border: 0; border-radius: 6px; background: transparent; color: var(--text-secondary); padding: 4px 9px; font-size: 12px; font-weight: 600; cursor: pointer; }
.reader-seg-btn.is-active { background: var(--fluid-card-top); color: var(--text-primary); box-shadow: var(--fluid-item-card-shadow); }
.reader-font-ctrl { display: inline-flex; align-items: center; gap: 6px; padding: 2px 6px; border-radius: 9px; border: 1px solid var(--fluid-card-border); background: var(--fluid-card-item-fill); font-size: 12px; font-variant-numeric: tabular-nums; }
.reader-icon-btn { display: grid; place-items: center; width: 24px; height: 24px; border: 0; border-radius: 6px; background: transparent; color: var(--text-primary); cursor: pointer; }
.reader-icon-btn:disabled { opacity: 0.4; cursor: not-allowed; }
.reader-pill { font-size: 11.5px; font-weight: 600; padding: 3px 9px; border-radius: 999px; border: 1px solid var(--fluid-card-border); background: var(--fluid-card-item-fill); color: var(--text-secondary); font-variant-numeric: tabular-nums; }
.reader-restored-pill { font-size: 11.5px; font-weight: 600; padding: 3px 9px; border-radius: 999px; background: color-mix(in srgb, var(--accent-primary) 12%, transparent); color: var(--accent-primary); }
.reader-loading { padding: 48px 16px; text-align: center; font-size: 13px; color: var(--text-secondary); }
.reader-empty-actions { display: inline-flex; gap: 8px; flex-wrap: wrap; }
.comic-single-stage { display: grid; gap: 10px; }
.comic-canvas { position: relative; display: flex; align-items: center; justify-content: center; min-height: 54vh; max-height: 64vh; border-radius: 13px; background: #111214; overflow: hidden; }
.comic-single-img { max-width: 100%; max-height: 62vh; object-fit: contain; user-select: none; }
.comic-nav-btn { position: absolute; top: 50%; transform: translateY(-50%); width: 38px; height: 56px; border: 0; border-radius: 10px; background: rgba(0, 0, 0, 0.48); color: #fff; display: grid; place-items: center; cursor: pointer; }
.comic-nav-btn.is-prev { left: 10px; }
.comic-nav-btn.is-next { right: 10px; }
.comic-nav-btn:disabled { opacity: 0.25; cursor: not-allowed; }
.comic-pager { display: flex; align-items: center; gap: 10px; font-size: 12px; color: var(--text-secondary); font-variant-numeric: tabular-nums; }
.comic-range { flex: 1; accent-color: var(--accent-primary); }
.comic-strip-stage { max-height: 64vh; overflow-y: auto; display: grid; gap: 10px; padding: 10px; border-radius: 13px; background: #111214; }
.comic-strip-item { margin: 0; display: grid; justify-items: center; gap: 4px; }
.comic-strip-item img { max-width: min(860px, 100%); height: auto; border-radius: 6px; }
.comic-strip-item figcaption { font-size: 11px; color: rgba(255, 255, 255, 0.65); font-variant-numeric: tabular-nums; }
.epub-layout { display: grid; grid-template-columns: 1fr; gap: 10px; min-height: 56vh; max-height: 65vh; }
.epub-layout.has-toc { grid-template-columns: 220px minmax(0, 1fr); }
.epub-toc { display: flex; flex-direction: column; gap: 4px; padding: 10px; border-radius: 12px; border: 1px solid var(--fluid-card-border); background: var(--fluid-card-item-fill); overflow-y: auto; max-height: 65vh; }
.epub-author { font-size: 11.5px; color: var(--text-tertiary); padding: 2px 6px 6px; border-bottom: 1px solid var(--fluid-divider); margin-bottom: 4px; }
.epub-toc-item { text-align: left; border: 0; border-radius: 8px; background: transparent; color: var(--text-secondary); padding: 6px 8px; font-size: 12.5px; cursor: pointer; }
.epub-toc-item:hover { background: color-mix(in srgb, var(--text-primary) 6%, transparent); color: var(--text-primary); }
.epub-toc-item.is-active { background: color-mix(in srgb, var(--accent-primary) 13%, var(--fluid-card-top)); color: var(--accent-primary); font-weight: 650; }
.epub-reader-pane { overflow-y: auto; max-height: 65vh; padding: 22px 28px; border-radius: 13px; border: 1px solid var(--fluid-card-border); background: var(--fluid-card-top); color: var(--text-primary); line-height: 1.85; }
.epub-reader-pane.theme-sepia { background: #f6eedc; color: #3a2f1e; }
.epub-reader-pane.theme-dark { background: #17181b; color: #e2e4e9; }
.epub-chapter-body { max-width: 72ch; margin: 0 auto; word-break: break-word; }
.epub-chapter-body img { max-width: 100%; height: auto; border-radius: 6px; }
.epub-chapter-nav { display: flex; align-items: center; justify-content: space-between; gap: 10px; margin-top: 24px; padding-top: 14px; border-top: 1px solid var(--fluid-divider); flex-wrap: wrap; }
.epub-chapter-label { font-size: 12px; color: var(--text-secondary); }
.reader-footer { display: flex; align-items: center; justify-content: space-between; gap: 10px; width: 100%; flex-wrap: wrap; }
.reader-footer-hint { font-size: 11.5px; color: var(--text-tertiary); }
@media (max-width: 720px) {
  .epub-layout.has-toc { grid-template-columns: 1fr; }
  .epub-toc { max-height: 22vh; }
}
</style>
