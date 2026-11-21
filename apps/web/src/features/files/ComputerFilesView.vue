<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { Folder, FileText, Film, Images, HardDrive, Monitor, RefreshCcw, ChevronLeft, ChevronRight, Eye, Download } from "lucide-vue-next";
import { apiFetch } from "../../api/apiClient.ts";
import { readApiFailure } from "../../api/apiFailure.ts";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import { formatBinaryBytes as formatBytes } from "../../utils/format.ts";
import { requestConfirm } from "../../composables/useConfirmDialog.ts";
import { useFileMediaLightbox } from "../../composables/useFileMediaLightbox.ts";
import type { BatchAsset } from "../photos/usePhotoBatchActions.ts";
import type { SharedFileEntry } from "./useFileShares.ts";
import AppleSelect from "../../components/ui/AppleSelect.vue";
import IsleModal from "../../components/ui/IsleModal.vue";
import IsleCard from "../../components/ui/IsleCard.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import IsleHelpButton from "../../components/ui/IsleHelpButton.vue";
import IslePageHeader from "../../components/ui/IslePageHeader.vue";
import IsleSearchInput from "../../components/ui/IsleSearchInput.vue";
import PhotoViewerModal from "../photos/PhotoViewerModal.vue";

const props = defineProps<{ admin: boolean }>();
type Entry = { name: string; path: string; type: "file" | "folder"; size: number };
type Member = { id: number; username: string; role: string };
type Grant = { mode: string; folders: { path: string }[] };

const enabled = ref(false), mode = ref("none"), path = ref(""), entries = ref<Entry[]>([]);
const filterQuery = ref("");
const busy = ref(false), error = ref(""), preview = ref<Entry | null>(null);
const previewText = ref(""), previewError = ref("");
const nextCursor = ref("");
const history = ref<string[]>([]);
let browseGeneration = 0;
let grantGeneration = 0;
const members = ref<Member[]>([]), selected = ref(""), grantMode = ref("none"), folders = ref<string[]>([]), saving = ref(false), grantLoading = ref(false), grantReady = ref(false);
const browsing = ref(false), grantNotice = ref("");
const memberOptions = computed(() => members.value.map(u => ({ value: String(u.id), label: u.username })));
const modes = [{ value: "none", label: "无权限" }, { value: "folders", label: "指定文件夹" }, { value: "all", label: "整台电脑" }];
const canOpen = computed(() => enabled.value && mode.value !== "none");
const fileUrl = (action: string, p: string) => `/api/v2/computer-files/${action}?path=${encodeURIComponent(p)}`;

const mediaAssets = ref<BatchAsset[]>([]);
const mediaSelected = ref<BatchAsset | null>(null);
const mediaEntriesByPath = new Map<string, Entry>();
const mediaIndex = computed(() => {
  const cur = mediaSelected.value;
  if (!cur) return -1;
  return mediaAssets.value.findIndex(item => item.path === cur.path);
});

function isImageFile(name: string) {
  return /\.(jpe?g|png|gif|webp|avif|bmp|heic|heif)$/i.test(name);
}
function isVideoFile(name: string) {
  return /\.(mp4|webm|m4v|mov|mkv|avi|mpe?g|m2?ts|3gp|wmv|flv)$/i.test(name);
}
function isTextFile(name: string) {
  return /\.(txt|md|json|log|csv|ya?ml|xml|toml|ini|conf|properties|css|js|tsx?|jsx|vue|html?|dart|go|swift|kt|java|py|sh|sql|srt|vtt)$/i.test(name);
}
function canPreview(name: string) {
  return isImageFile(name) || isVideoFile(name) || isTextFile(name) || /\.pdf$/i.test(name);
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
    return found ? ({ ...found, modified: "" } as SharedFileEntry) : null;
  },
  downloadFile: (entry) => triggerFileDownload(entry),
  previewEndpoint: "/api/v2/computer-files/preview",
  thumbnailEndpoint: "/api/v2/computer-files/thumbnail",
});

async function openPreview(entry: Entry) {
  if (isImageFile(entry.name) || isVideoFile(entry.name)) {
    preview.value = null;
    const siblings = entries.value.filter(item => item.type === "file" && (isImageFile(item.name) || isVideoFile(item.name)));
    if (!siblings.some(item => item.path === entry.path)) siblings.push(entry);
    mediaEntriesByPath.clear();
    const mapped: BatchAsset[] = siblings.map((item, idx) => {
      mediaEntriesByPath.set(item.path, item);
      return {
        id: -(idx + 1),
        path: item.path,
        name: item.name,
        type: isVideoFile(item.name) ? "video" : "photo",
        size: item.size,
        takenAt: 0,
        favorite: false,
        canWrite: false,
      };
    });
    mediaAssets.value = mapped;
    mediaSelected.value = mapped.find(item => item.path === entry.path) ?? mapped[0] ?? null;
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
      if (gen === browseGeneration && preview.value?.path === entry.path) {
        previewText.value = text;
      }
    } catch (e) {
      if (gen === browseGeneration && preview.value?.path === entry.path) {
        previewError.value = describeUserFacingError(e);
      }
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
    acc = acc ? `${acc}/${part}` : (isAbs ? `/${part}` : part);
    crumbs.push({ label: part, path: acc });
  }
  return crumbs;
});

const filteredEntries = computed(() => {
  const q = filterQuery.value.trim().toLowerCase();
  if (!q) return entries.value;
  return entries.value.filter(item => item.name.toLowerCase().includes(q));
});

async function request<T>(url: string, method = "GET", json?: unknown): Promise<T> {
  const response = await apiFetch(url, { method, ...(json === undefined ? {} : { json }) });
  if (!response.ok) throw await readApiFailure(response);
  return await response.json() as T;
}

async function loadStatus() {
  busy.value = true; error.value = "";
  try {
    const result = await request<{ enabled: boolean; mode: string }>("/api/v2/computer-files/status");
    enabled.value = result.enabled; mode.value = result.mode;
    if (canOpen.value) { history.value = []; await browse(""); }
    if (props.admin && enabled.value) {
      const data = await request<{ users: Member[] }>("/api/v2/users");
      members.value = data.users.filter(u => u.role === "member");
    }
  } catch (e) { error.value = describeUserFacingError(e); } finally { busy.value = false; }
}

async function browse(next: string, cursor = "", push = false) {
  const generation = ++browseGeneration;
  browsing.value = true;
  error.value = ""; preview.value = null; closeMediaViewer();
  if (!cursor) filterQuery.value = "";
  try {
    const result = await request<{ path: string; entries: Entry[]; nextCursor?: string }>(`/api/v2/computer-files?path=${encodeURIComponent(next)}&cursor=${encodeURIComponent(cursor)}`);
    if (generation !== browseGeneration) return;
    if (push) history.value.push(path.value);
    path.value = result.path; entries.value = cursor ? [...entries.value, ...result.entries] : result.entries; nextCursor.value = result.nextCursor ?? "";
  } catch (e) { if (generation === browseGeneration) error.value = `无法读取此目录：${describeUserFacingError(e)}。请检查磁盘连接及 Mac 的文件和隐私权限。`; }
  finally { if (generation === browseGeneration) browsing.value = false; }
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
    const link = document.createElement("a"); link.href = target; link.download = `${entry.name}.zip`; link.click();
  } catch (e) { error.value = `无法打包文件夹：${describeUserFacingError(e)}。超过 2 GiB、2,000 项或 16 层时请分批下载；含符号链接或特殊文件时请单独下载普通文件。`; }
}

async function loadGrant() {
  if (!selected.value) return;
  const member = selected.value, generation = ++grantGeneration; grantMode.value = "none"; folders.value = []; grantLoading.value = true; grantReady.value = false; grantNotice.value = "";
  try {
    const grant = await request<Grant>(`/api/v2/computer-files/grants/${member}`);
    if (generation !== grantGeneration || selected.value !== member) return;
    grantMode.value = grant.mode; folders.value = grant.folders.map(f => f.path); grantReady.value = true;
  } catch (e) { if (generation === grantGeneration) error.value = describeUserFacingError(e); }
  finally { if (generation === grantGeneration && selected.value === member) grantLoading.value = false; }
}

async function saveGrant() {
  if (!selected.value || saving.value || grantLoading.value || !grantReady.value) return;
  const member = selected.value, generation = grantGeneration, mode = grantMode.value, paths = [...folders.value];
  if (mode === "folders" && paths.length === 0) { error.value = "请先浏览并添加至少一个文件夹。"; return; }
  if (mode === "all" && !await requestConfirm({ title: "授权整台电脑", message: "该成员可以查看和下载 Mac 允许轻屿读取的所有文件，包括其他成员的私人文件。确认授权？" })) return;
  if (generation !== grantGeneration || selected.value !== member || !grantReady.value || grantLoading.value || grantMode.value !== mode || folders.value.join("\0") !== paths.join("\0")) return;
  saving.value = true; error.value = ""; grantNotice.value = "";
  try {
    await request(`/api/v2/computer-files/grants/${member}`, "PUT", { mode, paths });
    grantNotice.value = "已保存该成员的电脑文件权限。";
  }
  catch (e) { error.value = `授权未保存：${describeUserFacingError(e)}`; } finally { saving.value = false; }
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
              { title: '打包与权限建议', body: '文件夹 ZIP 打包上限为 2 GiB / 2,000 项；为成员分配权限时建议按需勾选「指定文件夹」，避免整机授权暴露私人资料。' },
            ]"
          />
        </template>
        <template #actions>
          <IsleButton variant="glass" size="sm" :loading="busy" @click="loadStatus">
            <template #icon><RefreshCcw :size="14" /></template>
            刷新状态
          </IsleButton>
        </template>
      </IslePageHeader>

      <IsleBanner v-if="error" type="error" compact role="alert" :message="error" />

      <IsleEmpty
        v-if="!enabled && !busy"
        card
        :icon="Monitor"
        title="电脑文件访问未开启"
        description="请先在 Mac 的轻屿管理端「设置 → 账号与安全」中开启「允许访问电脑文件」。"
      />
      <IsleEmpty
        v-else-if="enabled && !canOpen"
        card
        :icon="HardDrive"
        title="暂无访问权限"
        description="请联系管理员授权电脑文件或指定文件夹。"
      />

      <div v-if="canOpen" class="settings-stack">
        <IsleCard title="只读目录浏览" :subtitle="path || '宿主 Mac 已授权目录'">
          <template #icon><Folder :size="18" /></template>
          <template #actions>
            <div class="computer-toolbar">
              <IsleSearchInput
                v-model="filterQuery"
                placeholder="筛选当前目录名称…"
                aria-label="筛选当前目录文件名称"
              />
              <IsleButton variant="glass" size="sm" :disabled="!history.length" @click="goUp">
                <template #icon><ChevronLeft :size="14" /></template>
                上级
              </IsleButton>
              <IsleButton variant="glass" size="sm" :loading="browsing" @click="browse(path)">
                <template #icon><RefreshCcw :size="14" /></template>
                刷新
              </IsleButton>
            </div>
          </template>

          <div class="computer-crumbs-bar">
            <div class="file-crumbs" aria-label="电脑文件路径">
              <button
                v-for="(crumb, idx) in pathCrumbs"
                :key="crumb.path + ':' + idx"
                type="button"
                @click="crumb.path !== path && browse(crumb.path, '', true)"
              >
                <ChevronRight v-if="idx" :size="13" />
                <span>{{ crumb.label }}</span>
              </button>
            </div>
            <span class="files-count-badge">{{ filteredEntries.length }} 项</span>
          </div>

          <IsleEmpty
            v-if="filteredEntries.length === 0"
            compact
            :description="filterQuery.trim() ? '当前目录下没有匹配该关键词的项目。' : '此文件夹为空，或没有可显示的普通文件。'"
          />
          <div v-else class="computer-list">
            <div v-for="entry in filteredEntries" :key="entry.path" class="account-row computer-row">
              <button
                class="computer-name"
                type="button"
                @click="entry.type === 'folder' ? browse(entry.path, '', true) : canPreview(entry.name) ? openPreview(entry) : null"
              >
                <span class="file-icon" :class="entry.type">
                  <Folder v-if="entry.type === 'folder'" :size="17" />
                  <Film v-else-if="isVideoFile(entry.name)" :size="16" />
                  <Images v-else-if="isImageFile(entry.name)" :size="16" />
                  <FileText v-else :size="16" />
                </span>
                <span class="computer-entry-title">
                  <strong>{{ entry.name }}</strong>
                  <small>{{ entry.type === 'folder' ? '文件夹' : formatBytes(entry.size) }}</small>
                </span>
              </button>
              <div class="computer-entry-actions">
                <span class="computer-entry-size">{{ entry.type === 'folder' ? '文件夹' : formatBytes(entry.size) }}</span>
                <template v-if="entry.type === 'file'">
                  <IsleButton v-if="canPreview(entry.name)" variant="glass" size="sm" @click="openPreview(entry)">
                    <template #icon><Eye :size="13" /></template>预览
                  </IsleButton>
                  <a class="computer-download-link" :href="fileUrl('content', entry.path)" download>
                    <Download :size="13" /> 下载
                  </a>
                </template>
                <IsleButton v-else variant="tonal" size="sm" @click="downloadFolder(entry)">
                  <template #icon><Download :size="13" /></template>打包下载
                </IsleButton>
              </div>
            </div>
          </div>
          <div v-if="nextCursor" class="gallery-load" style="margin-top: 8px">
            <IsleButton variant="glass" size="sm" @click="browse(path, nextCursor)">加载更多</IsleButton>
          </div>
        </IsleCard>

        <IsleCard
          v-if="admin"
          title="家庭成员只读访问授权"
          subtitle="整机权限可能包含私人资料，推荐按需选择「指定文件夹」并添加上方浏览目录。"
        >
          <template #icon><Monitor :size="18" /></template>
          <div class="computer-grants-body">
            <div class="computer-toolbar">
              <AppleSelect v-model="selected" :options="memberOptions" placeholder="选择家庭成员" :disabled="saving" @change="loadGrant" />
              <AppleSelect v-model="grantMode" :options="modes" :disabled="!selected || !grantReady || grantLoading || saving" />
              <IsleButton v-if="selected && !grantReady && !grantLoading" variant="glass" size="sm" @click="loadGrant">
                重新读取权限
              </IsleButton>
              <IsleButton variant="primary" size="sm" :loading="saving" :disabled="!selected || !grantReady || saving || grantLoading" style="margin-left: auto" @click="saveGrant">
                {{ saving ? "正在保存…" : grantLoading ? "正在读取权限…" : "保存权限" }}
              </IsleButton>
            </div>
            <div v-if="grantMode === 'folders' && selected" class="computer-folders-box">
              <div class="computer-toolbar" style="justify-content: space-between">
                <span class="footnote" style="margin: 0">在上方打开目标文件夹后，可一键将当前路径加入该成员授权列表：</span>
                <IsleButton variant="tonal" size="sm" :disabled="!path || folders.includes(path)" @click="folders.push(path)">
                  添加当前目录 ({{ path || '未选定子目录' }})
                </IsleButton>
              </div>
              <div v-if="folders.length" class="computer-list">
                <div v-for="folder in folders" :key="folder" class="account-row computer-row">
                  <code class="computer-folder-code">{{ folder }}</code>
                  <IsleButton variant="danger" size="sm" @click="folders = folders.filter(p => p !== folder)">移除</IsleButton>
                </div>
              </div>
            </div>
            <IsleBanner v-if="grantNotice" type="success" compact role="status" :message="grantNotice" />
          </div>
        </IsleCard>
      </div>
    </div>

    <PhotoViewerModal v-bind="mediaModalProps" v-on="mediaModalEvents" />

    <IsleModal
      :open="Boolean(preview)"
      :title="preview?.name || ''"
      size="wide"
      role="dialog"
      aria-label="文件预览"
      @close="preview = null"
    >
      <template #header-actions>
        <a v-if="preview" class="computer-download-link" :href="fileUrl('content', preview.path)" download>
          <Download :size="13" /> 下载
        </a>
      </template>
      <IsleBanner v-if="previewError" type="error" compact :message="previewError" />
      <pre v-else-if="preview && isTextFile(preview.name)" class="preview-text">{{ previewText }}</pre>
      <iframe v-else-if="preview && /\.pdf$/i.test(preview.name)" class="computer-preview-frame" :src="fileUrl('preview', preview.path)" title="PDF 只读预览" />
    </IsleModal>
  </div>
</template>

<style scoped>
.computer-files-inner {
  max-width: 1120px;
  margin: 0 auto;
  width: 100%;
  display: flex;
  flex-direction: column;
  gap: 14px;
}
.computer-toolbar {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}
.computer-crumbs-bar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  padding-bottom: 10px;
  margin-bottom: 10px;
  border-bottom: 1px solid var(--fluid-divider, var(--fluid-card-border));
}
.computer-list {
  display: flex;
  flex-direction: column;
  border: 1px solid var(--fluid-card-border);
  border-radius: 12px;
  background: var(--fluid-card-item-fill);
  overflow: hidden;
}
.computer-row {
  margin: 0;
  min-height: 46px;
  padding: 8px 12px;
  border: 0;
  border-bottom: 1px solid var(--fluid-divider, var(--fluid-card-border));
  border-radius: 0;
  background: transparent;
  box-shadow: none;
  transition: background-color 0.15s ease;
}
.computer-row:last-child {
  border-bottom: 0;
}
.computer-row:hover {
  background: var(--fluid-card-hover);
}
.computer-name {
  flex: 1;
  min-width: 0;
  display: flex;
  align-items: center;
  gap: 10px;
  text-align: left;
  border: 0;
  background: transparent;
  color: var(--text-primary);
  padding: 0;
  cursor: pointer;
  font-size: 13.5px;
}
.computer-entry-title {
  display: flex;
  flex-direction: column;
  min-width: 0;
}
.computer-entry-title strong {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.computer-entry-title small {
  display: none;
  font-size: 11.5px;
  color: var(--text-tertiary);
}
.computer-entry-size {
  font-size: 12px;
  color: var(--text-tertiary);
  font-variant-numeric: tabular-nums;
  margin-right: 6px;
}
@media (max-width: 680px) {
  .computer-entry-size { display: none; }
  .computer-entry-title small { display: block; }
}
.computer-folder-code {
  font-size: 12px;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  overflow-wrap: anywhere;
}
.computer-entry-actions {
  display: flex;
  align-items: center;
  gap: 6px;
  flex-wrap: wrap;
}
.computer-download-link {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  min-height: 30px;
  padding: 4px 11px;
  border-radius: 9999px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-fill);
  color: var(--text-primary);
  font-size: 12px;
  font-weight: 550;
  text-decoration: none;
  transition: background-color 0.15s ease, border-color 0.15s ease;
}
.computer-download-link:hover {
  background: var(--fluid-card-hover);
  border-color: var(--fluid-card-border-strong, var(--accent-primary));
}
.computer-grants-body,
.computer-folders-box {
  display: flex;
  flex-direction: column;
  gap: 10px;
}
.computer-preview-frame {
  width: 100%;
  height: min(72vh, 660px);
  border: 1px solid var(--fluid-card-border);
  border-radius: 10px;
  background: white;
}
@media (prefers-reduced-motion: reduce) {
  .computer-row,
  .computer-download-link {
    transition: none;
  }
}
</style>
