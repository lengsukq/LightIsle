<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import {
  ArrowDown, ArrowUp, ChevronLeft, ChevronRight, Download, Eye,
  FileArchive, FileCode2, FileText, Film, Folder, HardDrive, Images,
  Monitor, Music, RefreshCcw, Users,
} from "lucide-vue-next";
import { apiFetch } from "../../api/apiClient.ts";
import { readApiFailure } from "../../api/apiFailure.ts";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import { formatDateTime } from "../../utils/dateTimeFormat.ts";
import { formatBinaryBytes as formatBytes } from "../../utils/format.ts";
import { useFileMediaLightbox } from "../../composables/useFileMediaLightbox.ts";
import type { BatchAsset } from "../photos/usePhotoBatchActions.ts";
import type { SharedFileEntry } from "./useFileShares.ts";
import ComputerGrantModal, { type ComputerMember } from "./ComputerGrantModal.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleCard from "../../components/ui/IsleCard.vue";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import IsleHelpButton from "../../components/ui/IsleHelpButton.vue";
import IsleModal from "../../components/ui/IsleModal.vue";
import IslePageHeader from "../../components/ui/IslePageHeader.vue";
import IsleSearchInput from "../../components/ui/IsleSearchInput.vue";
import PhotoViewerModal from "../photos/PhotoViewerModal.vue";

const props = defineProps<{ admin: boolean }>();

type Entry = {
  name: string;
  path: string;
  type: "file" | "folder";
  size: number;
  modified?: string | number;
};
type SortKey = "none" | "name" | "size" | "meta";

const MAX_THUMBNAIL_BYTES = 64 * 1024 * 1024;
const enabled = ref(false);
const mode = ref("none");
const path = ref("");
const entries = ref<Entry[]>([]);
const filterQuery = ref("");
const sortKey = ref<SortKey>("none");
const sortDir = ref<"asc" | "desc">("asc");
const busy = ref(false);
const error = ref("");
const preview = ref<Entry | null>(null);
const previewText = ref("");
const previewError = ref("");
const nextCursor = ref("");
const history = ref<string[]>([]);
const browsing = ref(false);
const members = ref<ComputerMember[]>([]);
const grantModalOpen = ref(false);
const loadedThumbs = ref(new Set<string>());
const failedThumbs = ref(new Set<string>());
let browseGeneration = 0;

const canOpen = computed(() => enabled.value && mode.value !== "none");
const hasModifiedColumn = computed(() => entries.value.some((e) => Boolean(e.modified)));
const fileUrl = (action: string, p: string) => `/api/v2/computer-files/${action}?path=${encodeURIComponent(p)}`;

const mediaAssets = ref<BatchAsset[]>([]);
const mediaSelected = ref<BatchAsset | null>(null);
const mediaEntriesByPath = new Map<string, Entry>();
const mediaIndex = computed(() => {
  const cur = mediaSelected.value;
  return cur ? mediaAssets.value.findIndex((item) => item.path === cur.path) : -1;
});

const isImageFile = (n: string) => /\.(jpe?g|png|gif|webp|avif|bmp|heic|heif)$/i.test(n);
const isVideoFile = (n: string) => /\.(mp4|webm|m4v|mov|mkv|avi|mpe?g|m2?ts|3gp|wmv|flv)$/i.test(n);
const isAudioFile = (n: string) => /\.(mp3|m4a|flac|wav|ogg|aac|opus)$/i.test(n);
const isArchiveFile = (n: string) => /\.(zip|tar|gz|tgz|bz2|xz|7z|rar|dmg|pkg|iso)$/i.test(n);
const isCodeFile = (n: string) => /\.(json|ya?ml|xml|toml|ini|conf|css|js|tsx?|jsx|vue|html?|dart|go|swift|kt|java|py|sh|sql)$/i.test(n);
const isTextFile = (n: string) => /\.(txt|md|json|log|csv|ya?ml|xml|toml|ini|conf|properties|css|js|tsx?|jsx|vue|html?|dart|go|swift|kt|java|py|sh|sql|srt|vtt)$/i.test(n);
const canPreview = (n: string) => isImageFile(n) || isVideoFile(n) || isTextFile(n) || /\.pdf$/i.test(n);
const isThumbnailEligible = (e: Entry) => e.type === "file" && isImageFile(e.name) && e.size > 0 && e.size <= MAX_THUMBNAIL_BYTES;
const thumbKey = (e: Entry) => `${e.path}:${e.size}`;
const thumbnailUrl = (e: Entry) => `${fileUrl("thumbnail", e.path)}&size=512`;

function onThumbLoad(entry: Entry, event: Event) {
  const img = event.target as HTMLImageElement | null;
  if (img && img.naturalWidth === 0) {
    markThumbFailed(entry);
    return;
  }
  const key = thumbKey(entry);
  if (loadedThumbs.value.has(key)) return;
  const next = new Set(loadedThumbs.value);
  next.add(key);
  loadedThumbs.value = next;
}

function markThumbFailed(entry: Entry) {
  const key = thumbKey(entry);
  if (failedThumbs.value.has(key)) return;
  const next = new Set(failedThumbs.value);
  next.add(key);
  failedThumbs.value = next;
}

function entryKindLabel(entry: Entry): string {
  if (entry.type === "folder") return "文件夹";
  const dot = entry.name.lastIndexOf(".");
  const ext = dot > 0 ? entry.name.slice(dot + 1).toUpperCase() : "";
  if (isImageFile(entry.name)) return ext ? `${ext} 图像` : "图像";
  if (isVideoFile(entry.name)) return ext ? `${ext} 视频` : "视频";
  if (isAudioFile(entry.name)) return ext ? `${ext} 音频` : "音频";
  if (/\.pdf$/i.test(entry.name)) return "PDF 文档";
  if (isArchiveFile(entry.name)) return ext ? `${ext} 归档` : "压缩包";
  if (isCodeFile(entry.name)) return ext ? `${ext} 代码` : "源码";
  if (isTextFile(entry.name)) return ext ? `${ext} 文档` : "文本";
  return ext ? `${ext} 文件` : "普通文件";
}

function showMediaAt(index: number): boolean {
  const target = mediaAssets.value[index];
  if (!target) return false;
  mediaSelected.value = target;
  return true;
}

function closeMediaViewer() {
  mediaSelected.value = null;
  mediaAssets.value = [];
}

function triggerFileDownload(entry: { name: string; path: string }) {
  const link = document.createElement("a");
  link.href = fileUrl("content", entry.path);
  link.download = entry.name;
  link.rel = "noopener";
  document.body.appendChild(link);
  link.click();
  link.remove();
}

const { modalProps: mediaModalProps, modalEvents: mediaModalEvents } = useFileMediaLightbox({
  active: () => Boolean(mediaSelected.value),
  isAdmin: () => props.admin,
  selected: mediaSelected,
  assets: mediaAssets,
  selectedIndex: mediaIndex,
  showAt: showMediaAt,
  close: closeMediaViewer,
  scopedMediaPath: (p) => p,
  fileEntryForMediaAsset: (asset) => {
    if (!asset) return null;
    const found = mediaEntriesByPath.get(asset.path);
    return found ? ({ ...found, modified: found.modified ? String(found.modified) : "" } as SharedFileEntry) : null;
  },
  downloadFile: (entry) => triggerFileDownload(entry),
  previewEndpoint: "/api/v2/computer-files/preview",
  thumbnailEndpoint: "/api/v2/computer-files/thumbnail",
});

async function openPreview(entry: Entry) {
  if (isImageFile(entry.name) || isVideoFile(entry.name)) {
    preview.value = null;
    const siblings = entries.value.filter((item) => item.type === "file" && (isImageFile(item.name) || isVideoFile(item.name)));
    if (!siblings.some((item) => item.path === entry.path)) siblings.push(entry);
    mediaEntriesByPath.clear();
    const mapped: BatchAsset[] = siblings.map((item, idx) => {
      mediaEntriesByPath.set(item.path, item);
      return { id: -(idx + 1), path: item.path, name: item.name, type: isVideoFile(item.name) ? "video" : "photo", size: item.size, takenAt: 0, favorite: false, canWrite: false };
    });
    mediaAssets.value = mapped;
    mediaSelected.value = mapped.find((item) => item.path === entry.path) ?? mapped[0] ?? null;
    return;
  }
  closeMediaViewer();
  preview.value = entry;
  previewText.value = "";
  previewError.value = "";
  if (isTextFile(entry.name)) {
    const gen = browseGeneration;
    try {
      const response = await apiFetch(fileUrl("preview", entry.path));
      if (!response.ok) throw await readApiFailure(response);
      const text = await response.text();
      if (gen === browseGeneration && preview.value?.path === entry.path) previewText.value = text;
    } catch (e) {
      if (gen === browseGeneration && preview.value?.path === entry.path) previewError.value = describeUserFacingError(e);
    }
  }
}

const pathCrumbs = computed(() => {
  const raw = path.value.trim();
  if (!raw) return [{ label: "已授权根目录", path: "" }];
  const normalized = raw.replace(/\/+$/, "");
  if (!normalized || normalized === "/") return [{ label: "/", path: "/" }];
  const isAbs = normalized.startsWith("/");
  const parts = normalized.split("/").filter(Boolean);
  const crumbs: Array<{ label: string; path: string }> = [{ label: "授权起点", path: "" }];
  let acc = "";
  for (const part of parts) {
    acc = acc ? `${acc}/${part}` : isAbs ? `/${part}` : part;
    crumbs.push({ label: part, path: acc });
  }
  return crumbs;
});

function toggleSort(nextKey: Exclude<SortKey, "none">) {
  if (sortKey.value === nextKey) {
    if (sortDir.value === "asc") sortDir.value = "desc";
    else { sortKey.value = "none"; sortDir.value = "asc"; }
  } else {
    sortKey.value = nextKey;
    sortDir.value = nextKey === "size" || nextKey === "meta" ? "desc" : "asc";
  }
}

const filteredEntries = computed(() => {
  const q = filterQuery.value.trim().toLowerCase();
  const base = q ? entries.value.filter((item) => item.name.toLowerCase().includes(q)) : entries.value;
  if (sortKey.value === "none") return base;
  const dir = sortDir.value === "asc" ? 1 : -1;
  return [...base].sort((a, b) => {
    if (a.type !== b.type) return a.type === "folder" ? -1 : 1;
    if (sortKey.value === "size") return (a.size - b.size) * dir || a.name.localeCompare(b.name, "zh-Hans-CN");
    if (sortKey.value === "meta") {
      if (hasModifiedColumn.value) {
        const ta = a.modified ? Date.parse(String(a.modified)) || Number(a.modified) || 0 : 0;
        const tb = b.modified ? Date.parse(String(b.modified)) || Number(b.modified) || 0 : 0;
        if (ta !== tb) return (ta - tb) * dir;
      }
      return entryKindLabel(a).localeCompare(entryKindLabel(b), "zh-Hans-CN") * dir;
    }
    return a.name.localeCompare(b.name, "zh-Hans-CN") * dir;
  });
});

async function request<T>(url: string): Promise<T> {
  const response = await apiFetch(url);
  if (!response.ok) throw await readApiFailure(response);
  return (await response.json()) as T;
}

async function loadMembers() {
  if (!props.admin || !enabled.value) return;
  const data = await request<{ users: ComputerMember[] }>("/api/v2/users");
  members.value = data.users.filter((u) => u.role === "member");
}

async function loadStatus() {
  busy.value = true;
  error.value = "";
  try {
    const result = await request<{ enabled: boolean; mode: string }>("/api/v2/computer-files/status");
    enabled.value = result.enabled;
    mode.value = result.mode;
    if (canOpen.value) { history.value = []; await browse(""); }
    await loadMembers();
  } catch (e) {
    error.value = describeUserFacingError(e);
  } finally {
    busy.value = false;
  }
}

async function browse(next: string, cursor = "", push = false) {
  const generation = ++browseGeneration;
  browsing.value = true;
  error.value = "";
  preview.value = null;
  closeMediaViewer();
  if (!cursor) {
    filterQuery.value = "";
    loadedThumbs.value = new Set();
    failedThumbs.value = new Set();
  }
  try {
    const result = await request<{ path: string; entries: Entry[]; nextCursor?: string }>(
      `/api/v2/computer-files?path=${encodeURIComponent(next)}&cursor=${encodeURIComponent(cursor)}`,
    );
    if (generation !== browseGeneration) return;
    if (push) history.value.push(path.value);
    path.value = result.path;
    entries.value = cursor ? [...entries.value, ...result.entries] : result.entries;
    nextCursor.value = result.nextCursor ?? "";
  } catch (e) {
    if (generation === browseGeneration) {
      error.value = `无法读取此目录：${describeUserFacingError(e)}。请检查磁盘连接及 Mac 的文件和隐私权限。`;
    }
  } finally {
    if (generation === browseGeneration) browsing.value = false;
  }
}

function goUp() {
  if (!history.value.length) return;
  void browse(history.value.pop() ?? "");
}

async function downloadFolder(entry: Entry) {
  error.value = "";
  try {
    const target = fileUrl("archive", entry.path);
    const response = await apiFetch(target, { method: "HEAD" });
    if (!response.ok) throw await readApiFailure(response);
    const link = document.createElement("a");
    link.href = target;
    link.download = `${entry.name}.zip`;
    link.click();
  } catch (e) {
    error.value = `无法打包文件夹：${describeUserFacingError(e)}。超过 2 GiB、2,000 项或 16 层时请分批下载；含符号链接或特殊文件时请单独下载普通文件。`;
  }
}

function openGrantModal() {
  grantModalOpen.value = true;
  if (!members.value.length && enabled.value) {
    void loadMembers().catch((e) => { error.value = describeUserFacingError(e); });
  }
}

onMounted(loadStatus);
</script>

<template>
  <div class="content computer-files">
    <div class="computer-files-inner">
      <IslePageHeader title="电脑文件" subtitle="只读浏览宿主 Mac 已授权目录，原文件全程受保护">
        <template #title-extra>
          <IsleHelpButton
            title="电脑文件只读访问说明"
            :items="[
              { title: '全程只读保护', body: '此页面仅提供宿主 Mac 已授权目录的浏览、预览与下载，不会改动或删除电脑上的任何原文件。' },
              { title: '打包与权限建议', body: '文件夹 ZIP 打包上限为 2 GiB / 2,000 项；管理员可通过右上角「成员授权」按需分配指定文件夹。' },
            ]"
          />
        </template>
        <template #actions>
          <IsleButton v-if="admin && enabled" variant="tonal" size="sm" @click="openGrantModal">
            <template #icon><Users :size="14" /></template>
            成员授权
          </IsleButton>
          <IsleButton variant="glass" size="sm" :loading="busy" @click="loadStatus">
            <template #icon><RefreshCcw :size="14" /></template>
            刷新状态
          </IsleButton>
        </template>
      </IslePageHeader>

      <IsleBanner v-if="error" type="error" compact role="alert" :message="error" />
      <IsleEmpty v-if="!enabled && !busy" card :icon="Monitor" title="电脑文件访问未开启" description="请先在 Mac 的轻屿管理端「设置 → 账号与安全」中开启「允许访问电脑文件」。" />
      <IsleEmpty v-else-if="enabled && !canOpen" card :icon="HardDrive" title="暂无访问权限" description="请联系管理员授权电脑文件或指定文件夹。" />

      <IsleCard v-if="canOpen" title="只读目录浏览" :subtitle="path || '宿主 Mac 已授权目录'">
        <template #icon><Folder :size="18" /></template>
        <template #actions>
          <div class="computer-toolbar">
            <IsleSearchInput v-model="filterQuery" placeholder="筛选当前目录名称…" aria-label="筛选当前目录文件名称" />
            <IsleButton variant="glass" size="sm" :disabled="!history.length" @click="goUp">
              <template #icon><ChevronLeft :size="14" /></template>上级
            </IsleButton>
            <IsleButton variant="glass" size="sm" :loading="browsing" @click="browse(path)">
              <template #icon><RefreshCcw :size="14" /></template>刷新
            </IsleButton>
          </div>
        </template>

        <div class="computer-crumbs-bar">
          <div class="file-crumbs" aria-label="电脑文件路径">
            <button v-for="(crumb, idx) in pathCrumbs" :key="crumb.path + ':' + idx" type="button" @click="crumb.path !== path && browse(crumb.path, '', true)">
              <ChevronRight v-if="idx" :size="13" /><span>{{ crumb.label }}</span>
            </button>
          </div>
          <span class="files-count-badge">{{ filteredEntries.length }} 项</span>
        </div>

        <IsleEmpty v-if="filteredEntries.length === 0" compact :description="filterQuery.trim() ? '当前目录下没有匹配该关键词的项目。' : '此文件夹为空，或没有可显示的普通文件。'" />

        <div v-else class="computer-table">
          <div class="computer-table-head" role="row">
            <button type="button" class="computer-col-btn is-start" @click="toggleSort('name')">
              <span>名称</span>
              <ArrowUp v-if="sortKey === 'name' && sortDir === 'asc'" :size="12" />
              <ArrowDown v-else-if="sortKey === 'name' && sortDir === 'desc'" :size="12" />
            </button>
            <button type="button" class="computer-col-btn is-end" @click="toggleSort('size')">
              <span>大小</span>
              <ArrowUp v-if="sortKey === 'size' && sortDir === 'asc'" :size="12" />
              <ArrowDown v-else-if="sortKey === 'size' && sortDir === 'desc'" :size="12" />
            </button>
            <button type="button" class="computer-col-btn is-end" @click="toggleSort('meta')">
              <span>{{ hasModifiedColumn ? "修改时间" : "类型" }}</span>
              <ArrowUp v-if="sortKey === 'meta' && sortDir === 'asc'" :size="12" />
              <ArrowDown v-else-if="sortKey === 'meta' && sortDir === 'desc'" :size="12" />
            </button>
            <span class="computer-col-label">操作</span>
          </div>

          <div class="computer-list">
            <div v-for="entry in filteredEntries" :key="entry.path" class="computer-row">
              <component
                :is="entry.type === 'folder' || canPreview(entry.name) ? 'button' : 'div'"
                class="computer-name"
                :class="{ 'is-static': entry.type === 'file' && !canPreview(entry.name) }"
                :type="entry.type === 'folder' || canPreview(entry.name) ? 'button' : undefined"
                :title="entry.name"
                @click="entry.type === 'folder' ? browse(entry.path, '', true) : canPreview(entry.name) ? openPreview(entry) : undefined"
              >
                <span class="computer-thumb-box" :class="entry.type">
                  <Folder v-if="entry.type === 'folder'" :size="17" class="computer-thumb-icon" />
                  <Film v-else-if="isVideoFile(entry.name)" :size="16" class="computer-thumb-icon" />
                  <Images v-else-if="isImageFile(entry.name)" :size="16" class="computer-thumb-icon" />
                  <Music v-else-if="isAudioFile(entry.name)" :size="16" class="computer-thumb-icon" />
                  <FileArchive v-else-if="isArchiveFile(entry.name)" :size="16" class="computer-thumb-icon" />
                  <FileCode2 v-else-if="isCodeFile(entry.name)" :size="16" class="computer-thumb-icon" />
                  <FileText v-else :size="16" class="computer-thumb-icon" />
                  <img
                    v-if="isThumbnailEligible(entry) && !failedThumbs.has(thumbKey(entry))"
                    :src="thumbnailUrl(entry)"
                    :alt="entry.name"
                    loading="lazy"
                    decoding="async"
                    class="computer-thumb-img"
                    :class="{ 'is-loaded': loadedThumbs.has(thumbKey(entry)) }"
                    @load="onThumbLoad(entry, $event)"
                    @error="markThumbFailed(entry)"
                  />
                </span>
                <span class="computer-entry-title">
                  <strong>{{ entry.name }}</strong>
                  <small>{{ entry.type === "folder" ? "文件夹" : `${formatBytes(entry.size)} · ${entryKindLabel(entry)}` }}<template v-if="entry.modified"> · {{ formatDateTime(entry.modified) }}</template></small>
                </span>
              </component>

              <span class="computer-cell-size">{{ entry.type === "folder" ? "—" : formatBytes(entry.size) }}</span>
              <span class="computer-cell-meta" :class="{ 'is-tabular': Boolean(entry.modified) }">{{ entry.modified ? formatDateTime(entry.modified) : entryKindLabel(entry) }}</span>

              <div class="computer-entry-actions">
                <template v-if="entry.type === 'file'">
                  <IsleButton v-if="canPreview(entry.name)" variant="glass" size="sm" @click="openPreview(entry)">
                    <template #icon><Eye :size="13" /></template>预览
                  </IsleButton>
                  <a class="computer-download-link" :href="fileUrl('content', entry.path)" download>
                    <Download :size="13" /><span>下载</span>
                  </a>
                </template>
                <IsleButton v-else variant="tonal" size="sm" @click="downloadFolder(entry)">
                  <template #icon><Download :size="13" /></template>打包下载
                </IsleButton>
              </div>
            </div>
          </div>
        </div>

        <div v-if="nextCursor" class="gallery-load computer-load-more">
          <IsleButton variant="glass" size="sm" @click="browse(path, nextCursor)">加载更多</IsleButton>
        </div>
      </IsleCard>
    </div>

    <PhotoViewerModal v-bind="mediaModalProps" v-on="mediaModalEvents" />
    <ComputerGrantModal v-if="admin" :open="grantModalOpen" :current-path="path" :members="members" @close="grantModalOpen = false" />

    <IsleModal :open="Boolean(preview)" :title="preview?.name || ''" size="wide" role="dialog" aria-label="文件预览" @close="preview = null">
      <template #header-actions>
        <a v-if="preview" class="computer-download-link" :href="fileUrl('content', preview.path)" download>
          <Download :size="13" /><span>下载</span>
        </a>
      </template>
      <IsleBanner v-if="previewError" type="error" compact :message="previewError" />
      <pre v-else-if="preview && isTextFile(preview.name)" class="preview-text">{{ previewText }}</pre>
      <iframe v-else-if="preview && /\.pdf$/i.test(preview.name)" class="computer-preview-frame" :src="fileUrl('preview', preview.path)" title="PDF 只读预览" />
    </IsleModal>
  </div>
</template>

<style scoped>
.computer-files-inner { max-width: 1120px; margin: 0 auto; width: 100%; display: flex; flex-direction: column; gap: 14px; }
.computer-toolbar { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.computer-crumbs-bar {
  display: flex; align-items: center; justify-content: space-between; gap: 10px;
  padding-bottom: 10px; margin-bottom: 10px; border-bottom: 1px solid var(--fluid-divider, var(--fluid-card-border));
}
.computer-crumbs-bar .file-crumbs { flex: 1; min-width: 0; }
.computer-crumbs-bar .files-count-badge { white-space: nowrap; flex-shrink: 0; }
.computer-table {
  display: flex; flex-direction: column; border: 1px solid var(--fluid-card-border);
  border-radius: 12px; background: var(--fluid-card-item-fill); overflow: hidden;
}
.computer-table-head, .computer-row {
  display: grid; grid-template-columns: minmax(0, 1fr) 104px 132px 164px; align-items: center; gap: 12px; padding: 0 14px;
}
.computer-table-head {
  min-height: 36px; border-bottom: 1px solid var(--fluid-divider, var(--fluid-card-border));
  background: color-mix(in srgb, var(--fluid-card-top) 55%, transparent); font-size: 11.5px; font-weight: 600; color: var(--text-tertiary); user-select: none;
}
.computer-col-btn {
  display: inline-flex; align-items: center; gap: 4px; border: 0; background: transparent;
  padding: 4px 0; color: var(--text-secondary); font-size: 11.5px; font-weight: 600; cursor: pointer;
}
.computer-col-btn.is-start { justify-self: start; }
.computer-col-btn.is-end { justify-self: end; }
.computer-col-btn:hover { color: var(--text-primary); }
.computer-col-label { justify-self: end; font-size: 11.5px; font-weight: 600; color: var(--text-tertiary); }
.computer-list { display: flex; flex-direction: column; }
.computer-row {
  min-height: 50px; padding-top: 7px; padding-bottom: 7px;
  border-bottom: 1px solid var(--fluid-divider, var(--fluid-card-border)); transition: background-color 0.15s ease;
}
.computer-row:last-child { border-bottom: 0; }
.computer-row:hover, .computer-row:focus-within { background: var(--fluid-card-hover); }
.computer-name {
  min-width: 0; display: flex; align-items: center; gap: 11px; text-align: left;
  border: 0; background: transparent; color: var(--text-primary); padding: 0; cursor: pointer; font-size: 13.5px;
}
.computer-name.is-static { cursor: default; }
.computer-thumb-box {
  position: relative; width: 36px; height: 36px; border-radius: 9px; display: grid; place-items: center; flex-shrink: 0;
  overflow: hidden; border: 1px solid var(--fluid-card-border);
  background: color-mix(in srgb, var(--text-primary) 5%, var(--fluid-card-top)); color: var(--text-secondary);
}
.computer-thumb-box.folder {
  background: color-mix(in srgb, var(--accent-primary) 12%, transparent);
  border-color: color-mix(in srgb, var(--accent-primary) 20%, var(--fluid-card-border)); color: var(--accent-primary);
}
.computer-thumb-img { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; opacity: 0; transition: opacity 0.24s ease; }
.computer-thumb-img.is-loaded { opacity: 1; }
.computer-entry-title { display: flex; flex-direction: column; min-width: 0; }
.computer-entry-title strong { font-weight: 560; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.computer-entry-title small { display: none; font-size: 11.5px; color: var(--text-tertiary); font-variant-numeric: tabular-nums; }
.computer-cell-size, .computer-cell-meta {
  justify-self: end; font-size: 12px; color: var(--text-secondary); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 100%;
}
.computer-cell-size, .computer-cell-meta.is-tabular { font-variant-numeric: tabular-nums; }
.computer-cell-meta { color: var(--text-tertiary); }
.computer-entry-actions { justify-self: end; display: flex; align-items: center; justify-content: flex-end; gap: 6px; flex-wrap: nowrap; transition: opacity 0.16s ease; }
@media (hover: hover) and (pointer: fine) {
  .computer-entry-actions { opacity: 0; pointer-events: none; }
  .computer-row:hover .computer-entry-actions, .computer-row:focus-within .computer-entry-actions { opacity: 1; pointer-events: auto; }
}
@media (hover: none), (pointer: coarse), (max-width: 767px) {
  .computer-entry-actions { opacity: 1; pointer-events: auto; }
}
.computer-download-link {
  display: inline-flex; align-items: center; gap: 5px; min-height: 30px; padding: 4px 11px; border-radius: 9999px;
  border: 1px solid var(--fluid-card-border); background: var(--fluid-card-fill); color: var(--text-primary);
  font-size: 12px; font-weight: 550; text-decoration: none; white-space: nowrap; flex-shrink: 0;
  transition: background-color 0.15s ease, border-color 0.15s ease;
}
.computer-download-link:hover { background: var(--fluid-card-hover); border-color: var(--fluid-card-border-strong, var(--accent-primary)); }
.computer-load-more { margin-top: 8px; }
.computer-preview-frame { width: 100%; height: min(72vh, 660px); border: 1px solid var(--fluid-card-border); border-radius: 10px; background: white; }
@media (max-width: 900px) {
  .computer-table-head, .computer-row { grid-template-columns: minmax(0, 1fr) 92px 152px; }
  .computer-col-btn:nth-child(3), .computer-cell-meta { display: none; }
}
@media (max-width: 767px) {
  .computer-table-head { display: none; }
  .computer-row { grid-template-columns: minmax(0, 1fr) auto; gap: 10px; padding: 8px 12px; }
  .computer-cell-size, .computer-cell-meta { display: none; }
  .computer-entry-title small { display: block; }
}
@media (prefers-reduced-motion: reduce) {
  .computer-row, .computer-thumb-img, .computer-entry-actions, .computer-download-link { transition: none; }
}
</style>
