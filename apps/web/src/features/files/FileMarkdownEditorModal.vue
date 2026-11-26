<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from "vue";
import {
  AlertTriangle, Check, Columns2, Copy, Download, Eye, FileText, Pencil,
  RefreshCcw, Save,
} from "lucide-vue-next";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleModal from "../../components/ui/IsleModal.vue";
import { readApiFailure } from "../../api/apiFailure.ts";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import { requestConfirm } from "../../composables/useConfirmDialog.ts";
import { copyTextToClipboard } from "../../utils/clipboard.ts";
import { formatDateTime } from "../../utils/dateTimeFormat.ts";
import { formatBinaryBytes } from "../../utils/format.ts";
import type { SharedFileEntry } from "./useFileShares.ts";
import {
  isMarkdownFile,
  parseTextJsonWithMtimeToken,
  renderMarkdownToRawHtml,
  TEXT_EDIT_MAX_BYTES,
} from "./fileReaderSupport.ts";

interface TextFileResponse extends Record<string, unknown> {
  path: string;
  name: string;
  content: string;
  size: number;
  mtimeToken?: string;
  mtimeUnixNano: number;
  modified: string;
  canWrite: boolean;
}

interface TextConflictInfo {
  message: string;
  currentMtimeToken: string;
  currentMtimeUnixNano: number;
  currentSize: number;
}

const props = defineProps<{
  file: SharedFileEntry | null;
  scopedApiPath: (path: string) => string;
  rootFetch: (endpoint: string, init?: RequestInit) => Promise<Response>;
  isAbortError: (error: unknown) => boolean;
}>();

const emit = defineEmits<{
  close: [];
  saved: [path: string];
  download: [file: SharedFileEntry];
}>();

const loading = ref(false);
const loadError = ref("");
const saving = ref(false);
const saveError = ref("");
const savedNotice = ref("");
const canWrite = ref(false);
const mtimeToken = ref("");
const mtimeUnixNano = ref(0);
const modifiedAt = ref("");
const savedContent = ref("");
const draft = ref("");
const viewMode = ref<"preview" | "edit" | "split">("preview");
const sanitizedMarkdownHtml = ref("");
const conflict = ref<TextConflictInfo | null>(null);
const copiedDraftStatus = ref("");

let loadSeq = 0;
let domPurifyPromise: Promise<{ sanitize: (dirty: string, cfg?: Record<string, unknown>) => string }> | null = null;

async function getDomPurify() {
  if (!domPurifyPromise) {
    domPurifyPromise = import("dompurify").then((mod) => mod.default);
  }
  return domPurifyPromise;
}

const isMarkdown = computed(() => Boolean(props.file && isMarkdownFile(props.file.name)));
const isDirty = computed(() => !loading.value && !loadError.value && draft.value !== savedContent.value);
const draftBytes = computed(() => new TextEncoder().encode(draft.value).length);
const overSizeLimit = computed(() => draftBytes.value > TEXT_EDIT_MAX_BYTES);
const canSave = computed(
  () => Boolean(props.file && canWrite.value && isDirty.value && !saving.value && !loading.value && !overSizeLimit.value),
);

async function refreshSanitizedPreview() {
  if (!isMarkdown.value) {
    sanitizedMarkdownHtml.value = "";
    return;
  }
  const rawHtml = renderMarkdownToRawHtml(draft.value);
  const DOMPurify = await getDomPurify();
  sanitizedMarkdownHtml.value = DOMPurify.sanitize(rawHtml, {
    USE_PROFILES: { html: true },
    FORBID_TAGS: ["script", "style", "iframe", "object", "embed", "form", "input"],
    FORBID_ATTR: ["onerror", "onload", "onclick", "onmouseover"],
  });
}

watch(
  [draft, isMarkdown, viewMode],
  () => {
    if (isMarkdown.value && (viewMode.value === "preview" || viewMode.value === "split")) {
      void refreshSanitizedPreview();
    }
  },
);

async function loadTextFile() {
  const target = props.file;
  if (!target) return;
  const seq = ++loadSeq;
  loading.value = true;
  loadError.value = "";
  saveError.value = "";
  savedNotice.value = "";
  conflict.value = null;
  copiedDraftStatus.value = "";
  viewMode.value = isMarkdownFile(target.name) ? "preview" : "edit";
  try {
    const response = await props.rootFetch(
      props.scopedApiPath("/api/v2/files/text") + "?path=" + encodeURIComponent(target.path),
      { credentials: "same-origin", cache: "no-store" },
    );
    if (!response.ok) throw await readApiFailure(response);
    const rawText = await response.text();
    const { data, mtimeToken: extractedToken } = parseTextJsonWithMtimeToken<TextFileResponse>(rawText);
    if (seq !== loadSeq) return;
    savedContent.value = data.content ?? "";
    draft.value = data.content ?? "";
    mtimeToken.value = extractedToken;
    mtimeUnixNano.value = data.mtimeUnixNano ?? 0;
    modifiedAt.value = data.modified ?? "";
    canWrite.value = data.canWrite === true;
    if (isMarkdownFile(target.name)) {
      await refreshSanitizedPreview();
    }
  } catch (err) {
    if (seq !== loadSeq || props.isAbortError(err)) return;
    loadError.value = "读取文本失败：" + describeUserFacingError(err);
  } finally {
    if (seq === loadSeq) loading.value = false;
  }
}

watch(
  () => props.file?.path,
  (path) => {
    if (path) {
      void loadTextFile();
    } else {
      loadSeq += 1;
      savedContent.value = "";
      draft.value = "";
      mtimeToken.value = "";
      mtimeUnixNano.value = 0;
      sanitizedMarkdownHtml.value = "";
      loadError.value = "";
      saveError.value = "";
      savedNotice.value = "";
      conflict.value = null;
    }
  },
  { immediate: true },
);

async function saveTextFile(forceOverwrite = false) {
  const target = props.file;
  if (!target || !canWrite.value || saving.value || overSizeLimit.value) return;
  saving.value = true;
  saveError.value = "";
  savedNotice.value = "";
  try {
    const response = await props.rootFetch(props.scopedApiPath("/api/v2/files/text"), {
      method: "PUT",
      credentials: "same-origin",
      headers: {
        "Content-Type": "application/json",
        "X-LightIsle-Request": "1",
      },
      body: JSON.stringify({
        path: target.path,
        content: draft.value,
        expectedMtimeToken: forceOverwrite ? "" : mtimeToken.value,
        expectedMtimeUnixNano: forceOverwrite ? 0 : mtimeUnixNano.value,
      }),
    });

    if (response.status === 409) {
      const raw409 = await response.clone().text().catch(() => "");
      let parsed409: {
        data: { error?: string; message?: string; currentMtimeToken?: string; currentMtimeUnixNano?: number; currentSize?: number };
        mtimeToken: string;
      } | null = null;
      try {
        parsed409 = parseTextJsonWithMtimeToken<{
          error?: string;
          message?: string;
          currentMtimeToken?: string;
          currentMtimeUnixNano?: number;
          currentSize?: number;
        }>(raw409, "currentMtimeToken", "currentMtimeUnixNano");
      } catch {
        parsed409 = null;
      }
      if (parsed409?.data.error === "file_modified_conflict") {
        conflict.value = {
          message:
            parsed409.data.message ||
            "文件在磁盘上已被其他设备或 Finder 修改，本次保存已中止，您的当前草稿已完整保留。",
          currentMtimeToken: parsed409.mtimeToken,
          currentMtimeUnixNano: Number(parsed409.data.currentMtimeUnixNano ?? 0),
          currentSize: Number(parsed409.data.currentSize ?? 0),
        };
        return;
      }
    }

    if (!response.ok) throw await readApiFailure(response);
    const rawSaved = await response.text();
    const { data, mtimeToken: savedToken } = parseTextJsonWithMtimeToken<{
      saved: boolean;
      size: number;
      mtimeToken?: string;
      mtimeUnixNano: number;
      modified: string;
    }>(rawSaved);
    savedContent.value = draft.value;
    mtimeToken.value = savedToken;
    mtimeUnixNano.value = data.mtimeUnixNano ?? 0;
    modifiedAt.value = data.modified;
    conflict.value = null;
    savedNotice.value = `已保存（${formatDateTime(data.modified) || "刚刚"}）`;
    emit("saved", target.path);
  } catch (err) {
    if (!props.isAbortError(err)) {
      saveError.value = "保存失败：" + describeUserFacingError(err);
    }
  } finally {
    saving.value = false;
  }
}

async function copyDraftToClipboard() {
  if (await copyTextToClipboard(draft.value)) {
    copiedDraftStatus.value = "已复制草稿到剪贴板";
  } else {
    copiedDraftStatus.value = "请手动全选文本框内容复制";
  }
}

async function reloadLatestFromDisk() {
  if (isDirty.value) {
    const ok = await requestConfirm({
      title: "加载磁盘最新版本？",
      message: "加载磁盘最新版本会替换编辑器中的未保存草稿，建议先点击「复制当前草稿」。确定继续？",
      confirmText: "加载最新版本",
      variant: "danger",
    });
    if (!ok) return;
  }
  await loadTextFile();
}

async function forceOverwriteWithDraft() {
  if (!conflict.value) return;
  const ok = await requestConfirm({
    title: "覆盖磁盘上的最新更改？",
    message: "将以您当前的编辑器草稿覆盖磁盘上的文件版本。请确认已核对他人或 Finder 的更改。",
    confirmText: "确认覆盖保存",
    variant: "danger",
  });
  if (!ok) return;
  await saveTextFile(true);
}

async function requestClose() {
  if (saving.value) return;
  if (isDirty.value) {
    const ok = await requestConfirm({
      title: "放弃未保存的更改？",
      message: "当前文档还有未保存的修改，关闭后草稿将丢失。",
      confirmText: "放弃并关闭",
      variant: "danger",
    });
    if (!ok) return;
  }
  emit("close");
}

function handleKeydown(event: KeyboardEvent) {
  if (!props.file) return;
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "s") {
    event.preventDefault();
    if (canSave.value) void saveTextFile();
  }
}

onMounted(() => window.addEventListener("keydown", handleKeydown));
onUnmounted(() => window.removeEventListener("keydown", handleKeydown));
</script>

<template>
  <IsleModal
    :open="Boolean(file)"
    :title="file?.name || '文本编辑'"
    size="wide"
    role="dialog"
    aria-label="在线文本与 Markdown 编辑器"
    :close-on-backdrop="!saving"
    :close-on-esc="!saving"
    :show-close="!saving"
    @close="requestClose"
  >
    <template #icon><FileText :size="17" /></template>

    <div v-if="file" class="md-editor-shell">
      <div class="md-toolbar">
        <div class="md-toolbar-left">
          <div v-if="isMarkdown" class="md-mode-tabs" role="tablist" aria-label="Markdown 视图模式">
            <button
              type="button"
              role="tab"
              :aria-selected="viewMode === 'preview' ? 'true' : 'false'"
              class="md-mode-btn"
              :class="{ 'is-active': viewMode === 'preview' }"
              @click="viewMode = 'preview'"
            >
              <Eye :size="13" /> 预览
            </button>
            <button
              type="button"
              role="tab"
              :aria-selected="viewMode === 'edit' ? 'true' : 'false'"
              class="md-mode-btn"
              :class="{ 'is-active': viewMode === 'edit' }"
              @click="viewMode = 'edit'"
            >
              <Pencil :size="13" /> {{ canWrite ? "编辑" : "源码" }}
            </button>
            <button
              type="button"
              role="tab"
              :aria-selected="viewMode === 'split' ? 'true' : 'false'"
              class="md-mode-btn md-split-only"
              :class="{ 'is-active': viewMode === 'split' }"
              @click="viewMode = 'split'"
            >
              <Columns2 :size="13" /> 分栏
            </button>
          </div>
          <span v-if="!loading && !loadError" class="md-meta-pill" :class="{ 'is-dirty': isDirty }">
            {{ !canWrite ? "只读" : isDirty ? "未保存草稿" : savedNotice || "已同步" }}
          </span>
          <span v-if="!loading && !loadError" class="md-size-pill" :class="{ 'is-over': overSizeLimit }">
            {{ formatBinaryBytes(draftBytes) }} / 2 MiB
          </span>
        </div>

        <div class="md-toolbar-right">
          <IsleButton type="button" variant="glass" size="sm" @click="emit('download', file)">
            <template #icon><Download :size="13" /></template>
            下载
          </IsleButton>
          <IsleButton
            v-if="canWrite && !loadError"
            type="button"
            variant="primary"
            size="sm"
            :loading="saving"
            :disabled="!canSave"
            title="保存更改 (⌘S / Ctrl+S)"
            @click="saveTextFile()"
          >
            <template #icon>
              <Check v-if="!isDirty && savedNotice" :size="13" />
              <Save v-else :size="13" />
            </template>
            {{ saving ? "保存中…" : "保存" }}
          </IsleButton>
        </div>
      </div>

      <div v-if="conflict" class="md-conflict-card" role="alert">
        <div class="md-conflict-head">
          <AlertTriangle :size="16" />
          <strong>保存冲突：磁盘版本已被更新，当前草稿已完整保留</strong>
        </div>
        <p>{{ conflict.message }}</p>
        <div class="md-conflict-actions">
          <IsleButton type="button" variant="tonal" size="sm" @click="copyDraftToClipboard">
            <template #icon><Copy :size="13" /></template>
            {{ copiedDraftStatus || "复制当前草稿" }}
          </IsleButton>
          <IsleButton type="button" variant="glass" size="sm" @click="reloadLatestFromDisk">
            <template #icon><RefreshCcw :size="13" /></template>
            刷新磁盘最新版
          </IsleButton>
          <IsleButton type="button" variant="danger" size="sm" :loading="saving" @click="forceOverwriteWithDraft">
            覆盖保存我的草稿
          </IsleButton>
        </div>
      </div>

      <IsleBanner v-if="overSizeLimit" type="warning" compact message="文本体积已超过 2 MiB 上限，请精简后再保存。" />
      <IsleBanner v-if="saveError" type="error" compact :message="saveError" />
      <IsleBanner v-if="loadError" type="error" compact :message="loadError">
        <template #action>
          <IsleButton variant="tonal" size="sm" @click="emit('download', file)">下载原件</IsleButton>
        </template>
      </IsleBanner>

      <div v-if="loading" class="md-loading" role="status">正在加载文档内容…</div>
      <div
        v-else-if="!loadError"
        class="md-stage"
        :class="{ 'is-split': isMarkdown && viewMode === 'split' }"
      >
        <textarea
          v-if="!isMarkdown || viewMode === 'edit' || viewMode === 'split'"
          v-model="draft"
          :readonly="!canWrite"
          spellcheck="false"
          aria-label="文档内容编辑区"
          class="md-textarea"
          placeholder="输入文档内容…（按 ⌘S / Ctrl+S 快速保存）"
        ></textarea>

        <article
          v-if="isMarkdown && (viewMode === 'preview' || viewMode === 'split')"
          class="md-preview-surface"
          aria-label="Markdown 安全渲染预览"
          v-html="sanitizedMarkdownHtml"
        ></article>
      </div>
    </div>

    <template #footer>
      <div class="md-footer">
        <small v-if="modifiedAt" class="md-footer-meta">上次修改：{{ formatDateTime(modifiedAt) }} · 支持 ⌘S / Ctrl+S 保存</small>
        <IsleButton variant="glass" :disabled="saving" @click="requestClose">关闭</IsleButton>
      </div>
    </template>
  </IsleModal>
</template>

<style scoped>
.md-editor-shell {
  display: grid;
  gap: 10px;
}
.md-toolbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  flex-wrap: wrap;
}
.md-toolbar-left,
.md-toolbar-right {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}
.md-mode-tabs {
  display: inline-flex;
  align-items: center;
  gap: 3px;
  padding: 3px;
  border-radius: 10px;
  background: var(--fluid-card-item-fill);
  border: 1px solid var(--fluid-card-border);
}
.md-mode-btn {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  padding: 5px 10px;
  border: 0;
  border-radius: 7px;
  background: transparent;
  color: var(--text-secondary);
  font-size: 12px;
  font-weight: 600;
  cursor: pointer;
}
.md-mode-btn.is-active {
  background: var(--fluid-card-top);
  color: var(--text-primary);
  box-shadow: var(--fluid-item-card-shadow);
}
.md-meta-pill,
.md-size-pill {
  font-size: 11.5px;
  font-weight: 600;
  padding: 3px 9px;
  border-radius: 999px;
  background: var(--fluid-card-item-fill);
  border: 1px solid var(--fluid-card-border);
  color: var(--text-secondary);
  font-variant-numeric: tabular-nums;
}
.md-meta-pill.is-dirty {
  color: var(--warning);
  border-color: color-mix(in srgb, var(--warning) 42%, var(--fluid-card-border));
  background: color-mix(in srgb, var(--warning) 10%, var(--fluid-card-top));
}
.md-size-pill.is-over {
  color: var(--error);
  border-color: color-mix(in srgb, var(--error) 45%, var(--fluid-card-border));
}
.md-conflict-card {
  display: grid;
  gap: 8px;
  padding: 12px 14px;
  border-radius: 12px;
  border: 1px solid color-mix(in srgb, var(--warning) 50%, var(--fluid-card-border));
  background: color-mix(in srgb, var(--warning) 10%, var(--fluid-card-item-top));
}
.md-conflict-head {
  display: inline-flex;
  align-items: center;
  gap: 7px;
  color: var(--warning);
  font-size: 13px;
}
.md-conflict-card p {
  margin: 0;
  font-size: 12.5px;
  color: var(--text-primary);
  line-height: 1.5;
}
.md-conflict-actions {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}
.md-loading {
  padding: 40px 16px;
  text-align: center;
  font-size: 13px;
  color: var(--text-secondary);
}
.md-stage {
  display: grid;
  grid-template-columns: 1fr;
  gap: 12px;
  min-height: 54vh;
  max-height: 64vh;
}
.md-stage.is-split {
  grid-template-columns: repeat(2, minmax(0, 1fr));
}
.md-textarea {
  box-sizing: border-box;
  width: 100%;
  min-height: 54vh;
  max-height: 64vh;
  resize: none;
  padding: 14px 16px;
  border-radius: 12px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-top);
  color: var(--text-primary);
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
  font-size: 13px;
  line-height: 1.65;
  outline: none;
}
.md-textarea:focus {
  border-color: var(--accent-primary);
  box-shadow: 0 0 0 3px color-mix(in srgb, var(--accent-primary) 15%, transparent);
}
.md-preview-surface {
  overflow-y: auto;
  min-height: 54vh;
  max-height: 64vh;
  padding: 16px 20px;
  border-radius: 12px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-top);
  color: var(--text-primary);
  font-size: 14px;
  line-height: 1.75;
  word-break: break-word;
}
.md-footer {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  width: 100%;
  flex-wrap: wrap;
}
.md-footer-meta {
  font-size: 11.5px;
  color: var(--text-tertiary);
}
@media (max-width: 760px) {
  .md-split-only {
    display: none;
  }
  .md-stage.is-split {
    grid-template-columns: 1fr;
  }
}
</style>
