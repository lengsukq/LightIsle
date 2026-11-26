<script setup lang="ts">
import { computed, inject, nextTick, onMounted, onUnmounted, ref, watch } from "vue";
import {
  ArrowDown, ArrowUp, BookOpen, Check, CheckSquare, ChevronLeft, ChevronRight, Clock, Copy, CopyCheck,
  Download, Eye, File, FileArchive, FileAudio, FileCode2, FileImage, FileText, FileVideo,
  Folder, FolderInput, FolderOpen, FolderPlus, FolderUp, HardDrive, Images, Inbox, LayoutGrid, List, Monitor,
  RefreshCcw, Star, Trash2, UploadCloud, X,
} from "lucide-vue-next";
import { FILES_VIEW_CTX } from "../../contexts/shellContexts.ts";
import { FILE_EXTRAS_CTX } from "./fileExtrasContext.ts";
import {
  FILE_SEARCH_KIND_OPTIONS,
  folderLabelOfPath,
  highlightSearchSegments,
  parentDirOfPath,
  scrollRevealedFileIntoView,
} from "./fileSearchUtils.ts";
import { trashPresentationState } from "./filePageState.ts";
import { hasActiveModalLayer } from "../../utils/modalStack.ts";
import { formatDateTime } from "../../utils/dateTimeFormat.ts";
import type { SharedFileEntry } from "./useFileShares.ts";
import FilePinsBar from "./FilePinsBar.vue";
import FileSearchControls from "./FileSearchControls.vue";
import FileSearchStatusBar from "./FileSearchStatusBar.vue";
import AppleSelect from "../../components/ui/AppleSelect.vue";
import IsleActionMenu from "../../components/ui/IsleActionMenu.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleHelpButton from "../../components/ui/IsleHelpButton.vue";
import IslePageHeader from "../../components/ui/IslePageHeader.vue";

type FileVisualKind = "folder" | "image" | "video" | "audio" | "pdf" | "archive" | "code" | "doc" | "file";

const FILE_SORT_OPTIONS = [
  { value: "name:asc", label: "名称 ↑" },
  { value: "name:desc", label: "名称 ↓" },
  { value: "mtime:desc", label: "修改时间 ↓" },
  { value: "mtime:asc", label: "修改时间 ↑" },
  { value: "size:desc", label: "大小 ↓" },
  { value: "size:asc", label: "大小 ↑" },
];

const FILE_ICON_MAP = {
  folder: Folder,
  image: FileImage,
  video: FileVideo,
  audio: FileAudio,
  pdf: FileText,
  archive: FileArchive,
  code: FileCode2,
  doc: FileText,
  file: File,
} as const;

const ctx = inject(FILES_VIEW_CTX);
if (!ctx) throw new Error("FilesView requires FILES_VIEW_CTX");
const extras = inject(FILE_EXTRAS_CTX, null);

const {
  active, user, filesPath, currentFolderCanWrite, fileDirectoryLoaded, sharedRootName,
  fileEntries, fileNextCursor, fileSortKey, fileSortDirection, failedThumbnails,
  fileSearch, lastExecutedQuery, fileSearchKind, fileSearchScope, searchFolderBase,
  searchViaSpotlight, searchingFiles, searchTruncated, recentSearches,
  revealedFilePath, revealingFilePath, checkedFiles, filesLoading, extracting, filesError,
  fileViewMode, createFolderOpen, newFolderName, fileActionBusy, fileOperationNotice,
  trashTarget, showDuplicatesModal, selectedFilesAllWritable, selectedPathsFallback, pathSegments,
  showingTrash, trashItems, trashRetention, trashRetentionError, trashLoading, trashBusy,
  trashError, trashNotice, selectedUpload, uploadPercent, uploadStage, uploadCurrent,
  uploadTotal, uploadFileName, uploadSize, uploadTransferred, uploadDropActive,
  uploadAutoRenameConflicts, uploadCompleted, uploadResult, uploadFailure, uploadBusy,
  uploadContinuation, canContinueUploads, bytes, setFileViewMode, loadFiles, runFileSearch,
  selectSearchKind, setSearchScope, applyRecentSearch, deleteRecentSearch, clearRecentSearches,
  clearFileSearch, revealEntryFolder, extractZip, loadTrash, openTrash, restoreTrash,
  purgeTrashItem, chooseUploadFiles, startUpload, dragOverUpload, dragLeaveUpload, dropUpload,
  cancelCurrentUpload, continueIncompleteUploads, closeUploadActivity, thumbnailKey,
  thumbnailEligible, fileThumbnailURL, markThumbnailFailure, canWriteEntry,
  operateFile, operateBatchMove, previewFile, goUp, makeFolder, batchTrash, downloadFile,
  batchDownloadSelected, selectFallbackPaths, copySelectedPaths, openShareDialog,
  jumpToSettingsGroup,
} = ctx;

const newFolderInputRef = ref<HTMLInputElement | null>(null);
const lastCheckedFileIndex = ref<number | null>(null);
const paginatingFiles = ref(false);
const viewSwitching = ref(false);
let viewSwitchTimer: number | null = null;

const fileSortValue = computed({
  get: () => `${fileSortKey.value}:${fileSortDirection.value}`,
  set: (val: string) => {
    const [key, dir] = val.split(":");
    if ((key === "name" || key === "mtime" || key === "size") && (dir === "asc" || dir === "desc")) {
      fileSortKey.value = key;
      fileSortDirection.value = dir;
      void loadFiles(filesPath.value);
    }
  },
});

const fileSearchKindLabel = computed(
  () => FILE_SEARCH_KIND_OPTIONS.find((k) => k.value === fileSearchKind.value)?.label ?? "",
);
const fileSearchFolderLabel = computed(
  () => folderLabelOfPath(searchFolderBase.value, sharedRootName.value || "共享根目录"),
);
const allVisibleFilesChecked = computed(() => {
  const slice = fileEntries.value.slice(0, 50);
  return slice.length > 0 && slice.every((item) => checkedFiles.value.includes(item.path));
});
const trashPresentation = computed(() =>
  trashPresentationState({ loading: trashLoading.value, error: trashError.value, entries: trashItems.value }),
);
const uploadCardVisible = computed(
  () => uploadBusy.value || uploadStage.value === "done" || uploadStage.value === "error" || uploadStage.value === "cancelled",
);

function classifyFileKind(entry: SharedFileEntry): FileVisualKind {
  if (entry.type === "folder") return "folder";
  const dot = entry.name.lastIndexOf(".");
  const ext = dot >= 0 ? entry.name.slice(dot + 1).toLowerCase() : "";
  if (/^(jpe?g|png|gif|webp|heic|heif|bmp|svg|raw|cr2|nef|arw|dng|avif|tiff?)$/.test(ext)) return "image";
  if (/^(mp4|webm|m4v|mov|mkv|avi|ts|mts|3gp|flv|wmv)$/.test(ext)) return "video";
  if (/^(mp3|m4a|flac|wav|ogg|aac|alac|wma|opus)$/.test(ext)) return "audio";
  if (ext === "pdf") return "pdf";
  if (/^(zip|tar|gz|tgz|bz2|xz|7z|rar|dmg|iso|pkg)$/.test(ext)) return "archive";
  if (/^(ts|tsx|js|jsx|mjs|cjs|vue|py|go|rs|swift|java|kt|c|cc|cpp|h|hpp|cs|rb|php|sh|zsh|bash|json|ya?ml|toml|xml|css|scss|html|sql|ini|conf|env)$/.test(ext)) return "code";
  if (/^(txt|md|markdown|doc|docx|rtf|pages|odt|csv|xls|xlsx|numbers|ppt|pptx|key|epub)$/.test(ext)) return "doc";
  return "file";
}

function fileIconComponent(entry: SharedFileEntry) {
  return FILE_ICON_MAP[classifyFileKind(entry)];
}

function fileExtBadge(entry: SharedFileEntry): string {
  if (entry.type === "folder") return "";
  const dot = entry.name.lastIndexOf(".");
  if (dot <= 0 || dot === entry.name.length - 1) return "";
  const ext = entry.name.slice(dot + 1).toUpperCase();
  return ext.length <= 5 ? ext : ext.slice(0, 4);
}

function toggleSelectAllFiles() {
  const slice = fileEntries.value.slice(0, 50).map((item) => item.path);
  const deselecting = allVisibleFilesChecked.value;
  checkedFiles.value = deselecting ? [] : slice;
  if (!deselecting && fileEntries.value.length > 50) {
    fileOperationNotice.value = `单次批量操作最多勾选前 50 项，当前目录剩余 ${fileEntries.value.length - 50} 项未包含在内。`;
  }
}

function toggleColumnSort(key: "name" | "mtime" | "size") {
  if (filesLoading.value || searchingFiles.value) return;
  if (fileSortKey.value === key) {
    fileSortDirection.value = fileSortDirection.value === "asc" ? "desc" : "asc";
  } else {
    fileSortKey.value = key;
    fileSortDirection.value = key === "name" ? "asc" : "desc";
  }
  void loadFiles(filesPath.value);
}

async function loadMoreFiles() {
  if (filesLoading.value) return;
  paginatingFiles.value = true;
  try {
    await loadFiles(filesPath.value, true);
  } finally {
    paginatingFiles.value = false;
  }
}

async function revealFileFolder(entry: SharedFileEntry) {
  const revealed = await revealEntryFolder(entry);
  if (!revealed) return;
  await nextTick();
  requestAnimationFrame(() => scrollRevealedFileIntoView(revealed));
}

async function submitCreateFolder() {
  if (await makeFolder()) createFolderOpen.value = false;
}

function openFileContextMenu(event: MouseEvent) {
  const row = event.currentTarget as HTMLElement | null;
  const trigger = row?.querySelector<HTMLButtonElement>(".isle-action-trigger");
  if (!trigger) return;
  if (trigger.getAttribute("aria-expanded") !== "true") {
    trigger.click();
  }
}

function onFileCheckboxClick(entry: SharedFileEntry, index: number, event: MouseEvent) {
  if (event.shiftKey && lastCheckedFileIndex.value !== null && lastCheckedFileIndex.value !== index) {
    const start = Math.min(lastCheckedFileIndex.value, index);
    const end = Math.max(lastCheckedFileIndex.value, index);
    const targetChecked = !checkedFiles.value.includes(entry.path);
    const next = new Set(checkedFiles.value);
    let capped = false;
    for (let i = start; i <= end; i += 1) {
      const candidate = fileEntries.value[i];
      if (!candidate) continue;
      if (targetChecked) {
        if (next.size < 50) next.add(candidate.path);
        else capped = true;
      } else {
        next.delete(candidate.path);
      }
    }
    checkedFiles.value = Array.from(next);
    if (capped) {
      fileOperationNotice.value = "单次批量操作最多勾选 50 项，超出部分未自动勾选。";
    }
    event.preventDefault();
  }
  lastCheckedFileIndex.value = index;
}

function handleKeydown(event: KeyboardEvent) {
  if (event.defaultPrevented || hasActiveModalLayer() || !user.value) return;
  const target = event.target as HTMLElement | null;
  if (target?.closest("input, textarea, select, [contenteditable='true']")) return;
  if (active.value === "files" && !showingTrash.value && !filesLoading.value) {
    if (event.key === "Escape") {
      if (checkedFiles.value.length > 0) {
        event.preventDefault();
        checkedFiles.value = [];
        return;
      }
      if (searchingFiles.value) {
        event.preventDefault();
        void clearFileSearch();
        return;
      }
    }
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "a" && fileEntries.value.length > 0) {
      event.preventDefault();
      toggleSelectAllFiles();
    }
  }
}

function openEntryPreview(entry: SharedFileEntry) {
  if (extras) {
    void extras.openFileWithReaders(entry);
  } else {
    void previewFile(entry);
  }
}

function togglePinCurrentFolder() {
  if (!extras || !filesPath.value || filesPath.value === ".") return;
  const label = filesPath.value.split("/").pop() || filesPath.value;
  void extras.togglePin({ path: filesPath.value, name: label });
}

watch(
  () => [active.value, fileDirectoryLoaded.value] as const,
  ([page, loaded]) => {
    if (page === "files" && loaded && extras && !extras.pinsLoaded.value && !extras.pinsLoading.value) {
      void extras.loadPins();
    }
  },
  { immediate: true },
);

watch(createFolderOpen, (openState) => {
  if (openState) void nextTick(() => newFolderInputRef.value?.focus());
});
watch(filesPath, () => {
  lastCheckedFileIndex.value = null;
});
watch(fileViewMode, () => {
  viewSwitching.value = true;
  if (viewSwitchTimer !== null) window.clearTimeout(viewSwitchTimer);
  viewSwitchTimer = window.setTimeout(() => {
    viewSwitching.value = false;
    viewSwitchTimer = null;
  }, 160);
});

onMounted(() => {
  window.addEventListener("keydown", handleKeydown);
});
onUnmounted(() => {
  selectedUpload.value = null;
  if (viewSwitchTimer !== null) {
    window.clearTimeout(viewSwitchTimer);
    viewSwitchTimer = null;
  }
  window.removeEventListener("keydown", handleKeydown);
});
</script>

<template>
  <div v-if="user" class="content isle-tab-pane">
    <IslePageHeader
      :title="'私人文件' + (sharedRootName ? ' · ' + sharedRootName : '')"
      :subtitle="showingTrash ? '正在浏览内部回收站，支持恢复或手动清理文件' : '支持整面板直接拖放上传、列头排序与区间多选'"
    >
      <template #title-extra>
        <IsleHelpButton
          title="文件操作与上传说明"
          :items="[
            { title: '断点续传与同名保护', body: '支持整面板直接拖放上传，单文件上限 32 GiB，中断后自动续传且默认不覆盖同名文件。' },
            { title: '高效多选与快捷键', body: '支持按住 Shift 连续区间多选、⌘A / Ctrl+A 全选当前前 50 项，以及右键呼出文件操作菜单。' },
          ]"
        />
      </template>
      <template #actions>
        <IsleButton variant="glass" size="sm" :disabled="showingTrash ? trashLoading : filesLoading" @click="showingTrash ? loadTrash() : loadFiles()">
          <template #icon><RefreshCcw :size="14" :class="{ spinning: (showingTrash && trashLoading) || (!showingTrash && filesLoading) }" /></template>
          刷新
        </IsleButton>
        <IsleButton :class="{ 'files-header-desktop-only': !showingTrash }" :variant="showingTrash ? 'tonal' : 'glass'" size="sm" :selected="showingTrash" @click="openTrash">
          <template #icon><Trash2 :size="14" /></template>
          {{ showingTrash ? "退出回收站" : "回收站" }}
        </IsleButton>
        <IsleButton v-if="!showingTrash" class="files-header-desktop-only" variant="glass" size="sm" @click="showDuplicatesModal = true">
          <template #icon><CopyCheck :size="14" /></template>
          空间整理
        </IsleButton>
        <IsleButton v-if="currentFolderCanWrite && !showingTrash" variant="tonal" size="sm" :selected="createFolderOpen" @click="createFolderOpen = !createFolderOpen">
          <template #icon><FolderPlus :size="15" /></template>
          新建文件夹
        </IsleButton>
        <IsleButton v-if="currentFolderCanWrite && !showingTrash" variant="primary" size="sm" :disabled="uploadBusy || filesLoading" @click="chooseUploadFiles">
          <template #icon><UploadCloud :size="15" /></template>
          {{ uploadBusy ? "正在上传" : "上传文件" }}
        </IsleButton>
        <IsleActionMenu aria-label="更多文件工具">
          <button
            v-if="currentFolderCanWrite && !showingTrash"
            type="button"
            role="menuitemcheckbox"
            :aria-checked="uploadAutoRenameConflicts ? 'true' : 'false'"
            :disabled="uploadBusy"
            title="上传遇到同名文件时自动附加序号改名，绝不覆盖原文件"
            @click="uploadAutoRenameConflicts = !uploadAutoRenameConflicts"
          >
            <Check v-if="uploadAutoRenameConflicts" :size="15" class="files-menu-check" />
            <span v-else class="files-menu-check-spacer" aria-hidden="true"></span>
            <span>同名自动改名</span>
            <span class="files-menu-state">{{ uploadAutoRenameConflicts ? "开" : "关" }}</span>
          </button>
          <button v-if="!showingTrash" type="button" role="menuitem" class="files-menu-mobile-only" @click="openTrash">
            <Trash2 :size="15" /> 回收站
          </button>
          <button v-if="!showingTrash" type="button" role="menuitem" class="files-menu-mobile-only" @click="showDuplicatesModal = true">
            <CopyCheck :size="15" /> 空间整理
          </button>
          <button v-if="extras" type="button" role="menuitem" @click="extras.openCollectManageModal()">
            <Inbox :size="15" /> 文件收集管理
          </button>
          <button type="button" role="menuitem" @click="jumpToSettingsGroup('files')">
            <Monitor :size="15" /> WebDAV 挂载向导
          </button>
        </IsleActionMenu>
        <input :ref="(el) => { selectedUpload = el as HTMLInputElement | null; }" type="file" class="visually-hidden" multiple @change="startUpload" />
      </template>
    </IslePageHeader>

    <section class="files-panel" :class="{ 'files-panel-dropping': uploadDropActive, 'is-searching': searchingFiles }" @dragover="dragOverUpload" @dragleave="dragLeaveUpload" @drop="dropUpload">
      <div v-if="uploadDropActive && currentFolderCanWrite && !showingTrash && !uploadBusy" class="files-drop-mask" aria-hidden="true">
        <UploadCloud :size="34" :stroke-width="1.8" />
        <strong>松开鼠标，上传至当前目录</strong>
        <small>{{ filesPath === '.' ? '共享根目录' : filesPath }} · 自动断点续传且不覆盖同名文件</small>
      </div>

      <Transition name="files-fade" mode="out-in">
        <div v-if="showingTrash" key="trash-head" class="trash-mode-banner">
          <div class="trash-mode-info">
            <Trash2 :size="16" />
            <strong>当前位置：内部回收站</strong>
            <span v-if="trashPresentation === 'items'">共 {{ trashItems.length }} 项</span>
          </div>
          <IsleButton variant="tonal" size="sm" @click="openTrash">
            <template #icon><ChevronLeft :size="14" /></template>返回文件列表
          </IsleButton>
        </div>

        <div v-else key="files-head" class="files-toolbar">
          <div class="files-toolbar-row">
            <div class="file-crumbs" aria-label="当前位置">
              <button v-if="filesPath !== '.'" type="button" class="file-up-pill" title="返回上一级目录" @click="goUp">
                <ChevronLeft :size="14" /><span>上级</span>
              </button>
              <button v-for="(segment, index) in pathSegments" :key="segment.path" type="button" @click="loadFiles(segment.path)">
                <ChevronRight v-if="index" :size="14" /><span>{{ segment.name }}</span>
              </button>
            </div>
            <div class="files-toolbar-meta">
              <span v-if="fileDirectoryLoaded && !filesLoading" class="files-count-badge">{{ fileEntries.length }} 项</span>
            </div>
          </div>

          <div class="files-toolbar-row file-actions">
            <FileSearchControls
              :query="fileSearch"
              :spotlight="searchViaSpotlight"
              :searching="searchingFiles"
              :recent-searches="recentSearches"
              @update:query="fileSearch = $event"
              @update:spotlight="searchViaSpotlight = $event"
              @search="runFileSearch"
              @clear="clearFileSearch"
              @select-history="applyRecentSearch"
              @delete-history="deleteRecentSearch"
              @clear-history="clearRecentSearches"
            />
            <div class="files-toolbar-controls">
              <button
                v-if="extras"
                type="button"
                class="files-insight-btn"
                title="快速筛选大文件"
                @click="extras.openInsightsModal('large')"
              >
                <HardDrive :size="14" /><span>大文件</span>
              </button>
              <button
                v-if="extras"
                type="button"
                class="files-insight-btn"
                title="查看近期新增和修改的文件"
                @click="extras.openInsightsModal('recent')"
              >
                <Clock :size="14" /><span>近期新增</span>
              </button>
              <div v-if="!searchingFiles" class="file-sort-control">
                <AppleSelect v-model="fileSortValue" :options="FILE_SORT_OPTIONS" :disabled="filesLoading" size="sm" aria-label="排序方式" />
              </div>
              <div class="file-view-toggle" role="group" aria-label="视图模式">
                <button type="button" :class="{ chosen: fileViewMode === 'list' }" title="列表视图" aria-label="列表视图" @click="setFileViewMode('list')"><List :size="15" /></button>
                <button type="button" :class="{ chosen: fileViewMode === 'grid' }" title="网格视图" aria-label="网格视图" @click="setFileViewMode('grid')"><LayoutGrid :size="15" /></button>
              </div>
            </div>
          </div>
        </div>
      </Transition>

      <FilePinsBar
        v-if="!showingTrash && extras"
        :pins="extras.pins.value"
        :loading="extras.pinsLoading.value"
        :error="extras.pinsError.value"
        :current-path="filesPath"
        :toggling-path="extras.togglingPinPath.value"
        :is-current-pinned="extras.isPinned(filesPath)"
        @open="extras.openPinItem($event)"
        @remove="extras.removePin($event)"
        @pin-current="togglePinCurrentFolder"
      />

      <Transition name="files-collapse">
        <div v-if="!showingTrash && currentFolderCanWrite && createFolderOpen" class="files-collapse-shell">
          <div class="files-collapse-inner">
            <form class="create-folder-form" @submit.prevent="submitCreateFolder" @keydown.esc.stop="createFolderOpen = false">
              <FolderPlus :size="18" />
              <input ref="newFolderInputRef" v-model="newFolderName" :disabled="fileActionBusy" maxlength="150" placeholder="输入新建文件夹名称，按回车创建" aria-label="新建文件夹名称" />
              <button :disabled="!newFolderName.trim() || fileActionBusy" type="submit">{{ fileActionBusy ? "创建中…" : "创建" }}</button>
              <button type="button" class="create-folder-cancel" :disabled="fileActionBusy" @click="createFolderOpen = false">取消</button>
            </form>
          </div>
        </div>
      </Transition>

      <textarea v-if="selectedPathsFallback && checkedFiles.length" class="file-selected-paths" :value="selectedPathsFallback" readonly aria-label="待手动复制的文件相对路径" rows="3" @focus="selectFallbackPaths"></textarea>

      <Transition name="files-collapse">
        <div v-if="uploadCardVisible" class="files-collapse-shell">
          <div class="files-collapse-inner">
            <section class="upload-activity-card" role="status" aria-live="polite">
              <div class="upload-activity-top">
                <div class="upload-activity-heading">
                  <span class="upload-activity-mark"><UploadCloud :size="17" /></span>
                  <div>
                    <strong>{{ uploadStage === 'done' ? '全部上传完成' : uploadStage === 'error' ? '上传遇到问题' : uploadStage === 'cancelled' ? '已取消上传' : uploadStage === 'hashing' ? '正在校验文件' : '正在上传文件' }}</strong>
                    <small>{{ uploadResult || uploadFileName }} <template v-if="uploadBusy">· 第 {{ uploadCurrent }} / {{ uploadTotal }} 个</template></small>
                  </div>
                </div>
                <div class="upload-activity-actions">
                  <strong v-if="uploadBusy">{{ uploadPercent }}%</strong>
                  <button v-if="uploadBusy" type="button" @click="cancelCurrentUpload">取消</button>
                  <button v-if="canContinueUploads" type="button" @click="continueIncompleteUploads">继续未完成文件（{{ uploadContinuation?.files.length }}）</button>
                  <button v-if="!uploadBusy" type="button" @click="closeUploadActivity">关闭</button>
                </div>
              </div>
              <div v-if="uploadBusy" class="upload-track" role="progressbar" :aria-valuenow="uploadPercent" aria-valuemin="0" aria-valuemax="100" :aria-label="uploadStage === 'hashing' ? '文件完整性校验进度' : '文件上传进度'">
                <div :style="{ width: uploadPercent + '%' }"></div>
              </div>
              <p v-if="uploadBusy" class="upload-activity-caption">{{ uploadStage === 'hashing' ? '校验文件内容，确保中断后不会错误续传' : bytes(uploadTransferred) + ' / ' + bytes(uploadSize) + ' 已上传' }} · {{ uploadCompleted }} 个文件已完成</p>
              <p v-else-if="uploadStage === 'error' || uploadStage === 'cancelled'" class="upload-activity-caption upload-activity-error">{{ uploadFailure }}</p>
              <p v-else-if="uploadStage === 'done'" class="upload-activity-caption">文件已保存到上传时选择的目录。</p>
            </section>
          </div>
        </div>
      </Transition>

      <Transition name="files-collapse">
        <div v-if="searchingFiles" class="files-collapse-shell">
          <div class="files-collapse-inner">
            <FileSearchStatusBar
              :query="lastExecutedQuery || fileSearch"
              :spotlight="searchViaSpotlight"
              :kind="fileSearchKind"
              :scope="fileSearchScope"
              :folder-base="searchFolderBase"
              :root-name="sharedRootName"
              :result-count="fileEntries.length"
              :truncated="searchTruncated"
              :loading="filesLoading"
              @select-kind="selectSearchKind"
              @select-scope="setSearchScope"
              @clear="clearFileSearch"
            />
          </div>
        </div>
      </Transition>

      <p v-if="!showingTrash && !filesLoading && !filesError && fileDirectoryLoaded && !currentFolderCanWrite" class="footnote files-inline-note">当前目录为只读，可浏览和下载文件。</p>
      <div v-if="!showingTrash && filesError" class="error-notice files-inline-error" role="alert">{{ filesError }}</div>
      <p v-if="!showingTrash && fileOperationNotice" class="footnote files-inline-note" role="status">{{ fileOperationNotice }}</p>
      <button v-if="searchingFiles && filesError && !filesLoading" type="button" class="refresh files-retry-btn" @click="runFileSearch">重试搜索</button>
      <div v-if="showingTrash" class="trash-list">
        <div v-if="trashPresentation === 'loading'" class="files-empty" role="status">正在读取回收站…</div>
        <div v-else-if="trashPresentation === 'error'" class="files-empty" role="alert">
          <span>{{ trashError }}</span><button type="button" class="refresh" :disabled="trashLoading" @click="loadTrash">重试读取回收站</button>
        </div>
        <div v-else-if="trashPresentation === 'empty'" class="files-empty">回收站是空的</div>
        <p v-if="trashNotice" class="footnote" role="status">{{ trashNotice }}</p>
        <p v-if="trashRetention" class="footnote">旧版轻屿回收站的自动清理已停用；其中的文件会保留，可在此恢复或手动处理。</p>
        <p v-else-if="trashRetentionError" class="footnote" role="status">{{ trashRetentionError }}</p>
        <div v-for="entry in (trashPresentation === 'items' ? trashItems : [])" :key="entry.id" class="file-entry">
          <div class="file-name"><strong>{{ entry.name }}</strong><small>原路径：{{ entry.originalPath }} · {{ formatDateTime(entry.deletedAt) }}</small></div>
          <div class="file-entry-actions">
            <IsleButton variant="tonal" size="sm" :disabled="trashBusy" @click="restoreTrash(entry)">恢复</IsleButton>
            <IsleButton v-if="user.role === 'admin' || entry.originalPath.startsWith('Users/')" variant="danger" size="sm" :disabled="trashBusy" @click="purgeTrashItem(entry)">永久删除</IsleButton>
          </div>
        </div>
      </div>
      <div v-if="!showingTrash && !filesLoading && fileEntries.length && fileViewMode === 'list'" class="file-list-head" role="row">
        <input type="checkbox" class="file-checkbox" :checked="allVisibleFilesChecked" aria-label="全选当前列表前 50 项" title="全选 / 取消全选（前 50 项）" @change="toggleSelectAllFiles" />
        <button type="button" class="file-col-sort file-col-name" :disabled="searchingFiles" @click="toggleColumnSort('name')">
          <span>名称</span>
          <template v-if="!searchingFiles && fileSortKey === 'name'">
            <ArrowUp v-if="fileSortDirection === 'asc'" :size="13" />
            <ArrowDown v-else :size="13" />
          </template>
        </button>
        <button type="button" class="file-col-sort file-col-size" :disabled="searchingFiles" @click="toggleColumnSort('size')">
          <span>大小</span>
          <template v-if="!searchingFiles && fileSortKey === 'size'">
            <ArrowUp v-if="fileSortDirection === 'asc'" :size="13" />
            <ArrowDown v-else :size="13" />
          </template>
        </button>
        <button type="button" class="file-col-sort file-col-mtime" :disabled="searchingFiles" @click="toggleColumnSort('mtime')">
          <span>修改时间</span>
          <template v-if="!searchingFiles && fileSortKey === 'mtime'">
            <ArrowUp v-if="fileSortDirection === 'asc'" :size="13" />
            <ArrowDown v-else :size="13" />
          </template>
        </button>
        <span class="file-col-actions">操作</span>
      </div>
      <div v-if="!showingTrash && filesLoading && !fileEntries.length" class="files-empty">{{ searchingFiles ? "正在搜索授权目录…" : "正在读取目录…" }}</div>
      <div v-else-if="!showingTrash && !fileEntries.length" class="files-empty">
        <Folder :size="30" />
        <span v-if="filesError">{{ searchingFiles ? "搜索失败，请查看上方原因并重试。" : "目录读取失败，请查看上方原因并重试。" }}</span>
        <span v-else-if="searchingFiles && fileSearchKind">在「{{ fileSearchKindLabel }}」类型下未找到匹配「{{ lastExecutedQuery || fileSearch }}」的结果</span>
        <span v-else-if="searchingFiles && fileSearchScope === 'folder' && searchFolderBase !== '.'">当前目录「{{ fileSearchFolderLabel }}」内未找到匹配「{{ lastExecutedQuery || fileSearch }}」的结果</span>
        <span v-else-if="searchingFiles">整个授权存储中未找到匹配「{{ lastExecutedQuery || fileSearch }}」的结果</span>
        <template v-else>
          <strong>此文件夹目前是空的</strong>
          <small v-if="currentFolderCanWrite" class="files-empty-hint">可直接将文件或图片拖入此处上传，支持 32 GiB 断点续传</small>
        </template>
        <div v-if="searchingFiles && !filesError" class="files-empty-actions">
          <button v-if="fileSearchKind" type="button" class="account-action" @click="selectSearchKind('')">切换到全部类型</button>
          <button v-if="fileSearchScope === 'folder' && searchFolderBase !== '.'" type="button" class="account-action" @click="setSearchScope('all')">扩大到当前整盘</button>
          <button type="button" class="account-action" @click="clearFileSearch">返回原目录</button>
        </div>
        <div v-else-if="!filesError && currentFolderCanWrite" class="files-empty-actions">
          <IsleButton variant="primary" size="sm" :disabled="uploadBusy || filesLoading" @click="chooseUploadFiles">
            <template #icon><UploadCloud :size="14" /></template>上传文件
          </IsleButton>
          <IsleButton variant="tonal" size="sm" @click="createFolderOpen = true">
            <template #icon><FolderPlus :size="14" /></template>新建文件夹
          </IsleButton>
        </div>
        <button v-if="filesError && !searchingFiles && !filesLoading" type="button" class="refresh" @click="loadFiles(filesPath)">重试读取目录</button>
      </div>
      <TransitionGroup
        name="isle-list"
        tag="div"
        class="file-entries-container"
        :class="{
          'file-grid-mode': fileViewMode === 'grid' && !showingTrash,
          'has-selection': checkedFiles.length > 0,
          'is-view-switching': viewSwitching,
        }"
        :css="!showingTrash && !paginatingFiles && fileEntries.length <= 120"
      >
        <div
          v-for="(entry, idx) in showingTrash ? [] : fileEntries"
          :key="entry.path"
          :data-file-path="entry.path"
          class="file-entry"
          :class="{ 'file-entry--revealed': revealedFilePath === entry.path, 'file-entry--checked': checkedFiles.includes(entry.path) }"
          @contextmenu.prevent="openFileContextMenu($event)"
        >
          <input type="checkbox" :value="entry.path" v-model="checkedFiles" :disabled="checkedFiles.length >= 50 && !checkedFiles.includes(entry.path)" :aria-label="'选择 ' + entry.name + (canWriteEntry(entry) ? '' : '（只读，可选择）')" class="file-checkbox" @click="onFileCheckboxClick(entry, idx, $event)" />
          <button type="button" class="file-open" @click="entry.type === 'folder' ? loadFiles(entry.path) : openEntryPreview(entry)" :title="entry.name">
            <span class="file-icon" :class="[entry.type, 'kind-' + classifyFileKind(entry)]">
              <img
                v-if="entry.type !== 'folder' && thumbnailEligible(entry) && !failedThumbnails.has(thumbnailKey(entry))"
                :src="fileThumbnailURL(entry)"
                :alt="entry.name + ' 缩略图'"
                loading="lazy"
                decoding="async"
                class="file-thumbnail"
                @error="markThumbnailFailure(entry)"
              />
              <template v-else>
                <component :is="fileIconComponent(entry)" :size="fileViewMode === 'grid' ? 32 : 18" :stroke-width="1.8" />
                <span v-if="fileViewMode === 'grid' && fileExtBadge(entry)" class="file-grid-ext">{{ fileExtBadge(entry) }}</span>
              </template>
            </span>
            <span class="file-name">
              <strong><template v-if="searchingFiles && lastExecutedQuery"><template v-for="(seg, sIdx) in highlightSearchSegments(entry.name, lastExecutedQuery)" :key="sIdx"><mark v-if="seg.match" class="file-search-hit">{{ seg.text }}</mark><template v-else>{{ seg.text }}</template></template></template><template v-else>{{ entry.name }}</template></strong>
              <small class="file-mobile-meta">{{ entry.type === "folder" ? "文件夹" : bytes(entry.size) }} · {{ formatDateTime(entry.modified) }}<template v-if="searchingFiles"> · <template v-for="(seg, pIdx) in highlightSearchSegments(parentDirOfPath(entry.path) === '.' ? '根目录' : parentDirOfPath(entry.path), lastExecutedQuery)" :key="pIdx"><mark v-if="seg.match" class="file-search-hit">{{ seg.text }}</mark><template v-else>{{ seg.text }}</template></template></template></small>
              <small v-if="searchingFiles" class="file-desktop-path">位置：<template v-for="(seg, pIdx) in highlightSearchSegments(parentDirOfPath(entry.path) === '.' ? '根目录' : parentDirOfPath(entry.path), lastExecutedQuery)" :key="pIdx"><mark v-if="seg.match" class="file-search-hit">{{ seg.text }}</mark><template v-else>{{ seg.text }}</template></template></small>
            </span>
            <span class="file-meta-cols">
              <span class="file-size-col">{{ entry.type === "folder" ? "—" : bytes(entry.size) }}</span>
              <span class="file-mtime-col">{{ formatDateTime(entry.modified) }}</span>
            </span>
          </button>
          <div class="file-entry-actions">
            <button v-if="searchingFiles" type="button" class="file-reveal-btn" :disabled="revealingFilePath === entry.path" title="打开所在目录并定位" :aria-label="'打开所在目录：' + entry.name" @click.stop="revealFileFolder(entry)"><FolderOpen :size="15" /><span>打开目录</span></button>
            <button
              v-if="fileViewMode === 'list' && extras"
              type="button"
              class="file-pin-btn"
              :class="{ 'is-pinned': extras.isPinned(entry.path) }"
              :disabled="extras.togglingPinPath.value === entry.path"
              :title="extras.isPinned(entry.path) ? '取消置顶' : '置顶到常用'"
              :aria-label="(extras.isPinned(entry.path) ? '取消置顶 ' : '置顶 ') + entry.name"
              @click.stop="extras.togglePin(entry)"
            >
              <Star :size="15" :fill="extras.isPinned(entry.path) ? 'currentColor' : 'none'" />
            </button>
            <button v-if="fileViewMode === 'list' && entry.type === 'file'" type="button" @click="openEntryPreview(entry)" title="预览" :aria-label="'预览 ' + entry.name"><Images :size="16" /></button>
            <button v-if="fileViewMode === 'list'" type="button" @click="downloadFile(entry)" :title="entry.type === 'folder' ? '下载文件夹 ZIP（最多 2 GiB / 2000 项）' : '下载'" :aria-label="'下载 ' + entry.name"><Download :size="16" /></button>
            <IsleActionMenu size="md" :aria-label="'更多文件操作：' + entry.name">
              <button v-if="fileViewMode === 'grid' && entry.type === 'file'" type="button" role="menuitem" @click="openEntryPreview(entry)"><Eye :size="14" /> 预览</button>
              <button v-if="fileViewMode === 'grid'" type="button" role="menuitem" @click="downloadFile(entry)"><Download :size="14" /> {{ entry.type === "folder" ? "下载 ZIP" : "下载" }}</button>
              <button v-if="extras" type="button" role="menuitem" @click="extras.togglePin(entry)"><Star :size="14" :fill="extras.isPinned(entry.path) ? 'currentColor' : 'none'" /> {{ extras.isPinned(entry.path) ? "取消常用置顶" : "置顶到常用" }}</button>
              <button v-if="searchingFiles" type="button" role="menuitem" @click="revealFileFolder(entry)">打开所在目录</button>
              <button v-if="extras && entry.type === 'file' && /\.(cbz|epub|zip)$/i.test(entry.name)" type="button" role="menuitem" @click="extras.openAsArchiveReader(entry)"><BookOpen :size="14" /> 漫画 / 电子书阅读</button>
              <button v-if="canWriteEntry(entry) && entry.type === 'file' && /\.zip$/i.test(entry.name)" type="button" role="menuitem" :disabled="extracting" @click="extractZip(entry)">{{ extracting ? "正在解压…" : "解压到同名文件夹" }}</button>
              <button v-if="canWriteEntry(entry)" type="button" role="menuitem" @click="operateFile(entry, 'rename')">重命名</button>
              <button v-if="canWriteEntry(entry)" type="button" role="menuitem" @click="operateFile(entry, 'move')">移动到…</button>
              <button type="button" role="menuitem" @click="operateFile(entry, 'copy')">复制到…</button>
              <button v-if="extras && canWriteEntry(entry) && entry.type === 'folder'" type="button" role="menuitem" @click="extras.openCollectCreateModal(entry)"><FolderUp :size="14" /> 创建收集链接（亲友投递）</button>
              <button type="button" role="menuitem" @click="openShareDialog(entry)">创建分享链接</button>
              <button v-if="canWriteEntry(entry)" type="button" role="menuitem" class="danger" @click="trashTarget = entry">移到回收站</button>
            </IsleActionMenu>
          </div>
        </div>
      </TransitionGroup>
      <div v-if="!showingTrash && fileNextCursor" class="gallery-load">
        <button type="button" :disabled="filesLoading" @click="loadMoreFiles">{{ filesLoading ? "加载中…" : "加载更多文件" }}</button>
      </div>
      <Teleport to="body">
        <Transition name="isle-batch-bar">
          <div v-if="active === 'files' && checkedFiles.length && !showingTrash" class="file-batch-bar" role="toolbar" aria-label="文件批量操作">
            <span class="file-batch-count">已选 {{ checkedFiles.length }} 项<small v-if="checkedFiles.length >= 50 && fileEntries.length > 50">（已满 50，余 {{ fileEntries.length - 50 }}）</small><small v-else>（上限 50）</small></span>
            <div class="file-batch-actions">
              <button type="button" @click="toggleSelectAllFiles"><CheckSquare :size="13" /> {{ allVisibleFilesChecked ? "取消全选" : "全选前 50" }}</button>
              <button type="button" @click="batchDownloadSelected"><Download :size="13" /> 批量下载</button>
              <button v-if="selectedFilesAllWritable" type="button" @click="operateBatchMove"><FolderInput :size="13" /> 移动…</button>
              <button type="button" @click="copySelectedPaths"><Copy :size="13" /> 复制路径</button>
              <button v-if="selectedFilesAllWritable" type="button" class="batch-danger" @click="batchTrash" :disabled="checkedFiles.length > 50"><Trash2 :size="13" /> 移入回收站</button>
              <span v-else class="footnote files-batch-note">含只读项</span>
              <button type="button" class="batch-dismiss" @click="checkedFiles = []"><X :size="13" /> 取消</button>
            </div>
          </div>
        </Transition>
      </Teleport>
    </section>
  </div>
</template>

<style scoped>
.files-inline-note { margin: 8px 16px; }
.files-inline-error { margin: 8px 14px; }
.files-retry-btn { margin: 6px 14px; }
.files-batch-note { margin: 0; }
.files-empty strong { font-size: 14px; font-weight: 650; color: var(--text-primary); }
.files-empty-hint { font-size: 12px; color: var(--text-tertiary); }
.files-menu-check { color: var(--accent-primary); flex-shrink: 0; }
.files-menu-check-spacer { width: 15px; height: 15px; flex-shrink: 0; }
.files-menu-state {
  margin-left: auto; font-size: 11px; font-weight: 600; padding: 1px 6px;
  border-radius: 999px; background: color-mix(in srgb, var(--text-primary) 7%, transparent); color: var(--text-secondary);
}
.files-insight-btn {
  display: inline-flex; align-items: center; gap: 5px; min-height: 32px; padding: 5px 10px;
  border-radius: 9px; border: 1px solid var(--fluid-card-border); background: var(--fluid-card-item-fill);
  color: var(--text-secondary); font-size: 12px; font-weight: 600; cursor: pointer; white-space: nowrap;
}
.files-insight-btn:hover { background: var(--fluid-card-hover); border-color: var(--fluid-card-border-strong); color: var(--text-primary); }
.file-pin-btn.is-pinned { color: var(--accent-primary); }

/* Colored File Type Icon Tokens */
.file-entry .file-icon { position: relative; overflow: hidden; transition: transform 200ms var(--motion-spring, cubic-bezier(0.22, 1, 0.36, 1)); }
.file-entry .file-icon.kind-folder { background: color-mix(in srgb, var(--accent-primary) 13%, transparent); color: var(--accent-primary); }
.file-entry .file-icon.kind-image { background: rgba(217, 72, 123, 0.11); color: #d9487b; }
.file-entry .file-icon.kind-video { background: rgba(217, 107, 39, 0.11); color: #d96b27; }
.file-entry .file-icon.kind-audio { background: rgba(124, 77, 255, 0.11); color: #7c4dff; }
.file-entry .file-icon.kind-pdf { background: rgba(201, 59, 59, 0.11); color: #c93b3b; }
.file-entry .file-icon.kind-archive { background: rgba(180, 105, 14, 0.12); color: #b4690e; }
.file-entry .file-icon.kind-code { background: rgba(37, 99, 235, 0.11); color: #2563eb; }
.file-entry .file-icon.kind-doc { background: rgba(2, 132, 199, 0.11); color: #0284c7; }
.file-entry .file-icon.kind-file { background: color-mix(in srgb, var(--text-primary) 7%, transparent); color: var(--text-secondary); }
:global([data-theme="dark"]) .file-entry .file-icon.kind-image { color: #f07aa4; background: rgba(240, 122, 164, 0.15); }
:global([data-theme="dark"]) .file-entry .file-icon.kind-video { color: #f2965a; background: rgba(242, 150, 90, 0.15); }
:global([data-theme="dark"]) .file-entry .file-icon.kind-audio { color: #a78bfa; background: rgba(167, 139, 250, 0.16); }
:global([data-theme="dark"]) .file-entry .file-icon.kind-pdf { color: #f27474; background: rgba(242, 116, 116, 0.15); }
:global([data-theme="dark"]) .file-entry .file-icon.kind-archive { color: #eab354; background: rgba(234, 179, 84, 0.16); }
:global([data-theme="dark"]) .file-entry .file-icon.kind-code { color: #60a5fa; background: rgba(96, 165, 250, 0.16); }
:global([data-theme="dark"]) .file-entry .file-icon.kind-doc { color: #38bdf8; background: rgba(56, 189, 248, 0.15); }

.file-grid-ext {
  position: absolute; bottom: 8px; right: 8px; padding: 2px 6px; border-radius: 6px;
  font-size: 10px; font-weight: 700; letter-spacing: 0.04em;
  background: color-mix(in srgb, var(--surface-elevated, #ffffff) 82%, transparent);
  border: 1px solid var(--fluid-card-border); color: currentColor;
}

/* Smooth Collapse, Fade & List Transitions */
.files-collapse-shell { display: grid; grid-template-rows: 1fr; }
.files-collapse-inner { min-height: 0; overflow: hidden; }
.files-collapse-enter-active, .files-collapse-leave-active { transition: grid-template-rows 220ms var(--motion-spring, cubic-bezier(0.22, 1, 0.36, 1)), opacity 170ms ease; }
.files-collapse-enter-from, .files-collapse-leave-to { grid-template-rows: 0fr; opacity: 0; }
.files-fade-enter-active, .files-fade-leave-active { transition: opacity 150ms ease; }
.files-fade-enter-from, .files-fade-leave-to { opacity: 0; }
.isle-list-enter-active { transition: opacity 180ms ease, transform 200ms var(--motion-spring, cubic-bezier(0.22, 1, 0.36, 1)); }
.isle-list-leave-active { transition: opacity 120ms ease; }
.isle-list-enter-from { opacity: 0; transform: translate3d(0, 6px, 0); }
.isle-list-leave-to { opacity: 0; }
.isle-list-move { transition: transform 200ms var(--motion-spring, cubic-bezier(0.22, 1, 0.36, 1)); }
.file-entries-container { transition: opacity 150ms ease; }
.file-entries-container.is-view-switching { opacity: 0.65; }

@media (prefers-reduced-motion: reduce) {
  .file-entry .file-icon, .files-collapse-enter-active, .files-collapse-leave-active,
  .files-fade-enter-active, .files-fade-leave-active, .isle-list-enter-active,
  .isle-list-leave-active, .isle-list-move, .file-entries-container { transition: none; }
}
</style>
