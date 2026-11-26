<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { Download, FileSpreadsheet, FileText, Pencil } from "lucide-vue-next";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import IsleModal from "../../components/ui/IsleModal.vue";
import { readApiFailure } from "../../api/apiFailure.ts";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import { formatBinaryBytes } from "../../utils/format.ts";
import type { SharedFileEntry } from "./useFileShares.ts";
import {
  computeSheetMaxColCount,
  fileExtensionLower,
  OFFICE_MAX_PREVIEW_BYTES,
  parseCsvRows,
} from "./fileReaderSupport.ts";

interface SheetPreview {
  name: string;
  rows: string[][];
  truncated: boolean;
}

const MAX_SHEET_ROWS = 2000;

const props = defineProps<{
  file: SharedFileEntry | null;
  canWrite: boolean;
  scopedApiPath: (path: string) => string;
  rootFetch: (endpoint: string, init?: RequestInit) => Promise<Response>;
  isAbortError: (error: unknown) => boolean;
}>();

const emit = defineEmits<{
  close: [];
  download: [file: SharedFileEntry];
  editAsText: [file: SharedFileEntry];
}>();

const loading = ref(false);
const error = ref("");
const docxHtml = ref("");
const docxNotices = ref<string[]>([]);
const sheets = ref<SheetPreview[]>([]);
const activeSheetIndex = ref(0);

let loadSeq = 0;

const fileExt = computed(() => (props.file ? fileExtensionLower(props.file.name) : ""));
const isSpreadsheet = computed(() => fileExt.value === ".xlsx" || fileExt.value === ".csv");
const isTooLarge = computed(() => Boolean(props.file && props.file.size > OFFICE_MAX_PREVIEW_BYTES));
const activeSheet = computed(() => sheets.value[activeSheetIndex.value] ?? null);
const activeSheetColCount = computed(() =>
  activeSheet.value ? computeSheetMaxColCount(activeSheet.value.rows) : 0,
);

function formatCellValue(cell: unknown): string {
  if (cell === null || cell === undefined) return "";
  if (cell instanceof Date) return cell.toLocaleString();
  if (typeof cell === "boolean") return cell ? "TRUE" : "FALSE";
  return String(cell);
}

async function loadOfficePreview() {
  const target = props.file;
  if (!target) return;
  const seq = ++loadSeq;
  error.value = "";
  docxHtml.value = "";
  docxNotices.value = [];
  sheets.value = [];
  activeSheetIndex.value = 0;

  if (target.size > OFFICE_MAX_PREVIEW_BYTES) {
    loading.value = false;
    return;
  }

  loading.value = true;
  try {
    const response = await props.rootFetch(
      props.scopedApiPath("/api/v2/files/content") + "?path=" + encodeURIComponent(target.path),
      { credentials: "same-origin", cache: "no-store" },
    );
    if (!response.ok) throw await readApiFailure(response);

    const ext = fileExtensionLower(target.name);
    if (ext === ".docx") {
      const arrayBuffer = await response.arrayBuffer();
      if (seq !== loadSeq) return;
      if (arrayBuffer.byteLength > OFFICE_MAX_PREVIEW_BYTES) {
        error.value = "文档实际体积超过 20 MiB，请下载原件使用本地应用查看。";
        return;
      }
      const [mammothMod, domPurifyMod] = await Promise.all([
        import("mammoth"),
        import("dompurify"),
      ]);
      if (seq !== loadSeq) return;
      const mammoth = (mammothMod.default ?? mammothMod) as typeof import("mammoth");
      const DOMPurify = domPurifyMod.default;
      const converted = await mammoth.convertToHtml({ arrayBuffer });
      if (seq !== loadSeq) return;
      docxHtml.value = DOMPurify.sanitize(converted.value, {
        USE_PROFILES: { html: true },
        FORBID_TAGS: ["script", "style", "iframe", "object", "embed", "form"],
        FORBID_ATTR: ["onerror", "onload", "onclick"],
      });
      docxNotices.value = converted.messages
        .filter((m) => m.type === "warning")
        .slice(0, 3)
        .map((m) => m.message);
    } else if (ext === ".xlsx") {
      const blob = await response.blob();
      if (seq !== loadSeq) return;
      if (blob.size > OFFICE_MAX_PREVIEW_BYTES) {
        error.value = "表格实际体积超过 20 MiB，请下载原件使用本地应用查看。";
        return;
      }
      const xlsxMod = await import("read-excel-file/browser");
      if (seq !== loadSeq) return;
      const readXlsxFile = xlsxMod.default;
      const parsedSheets = await readXlsxFile(blob);
      if (seq !== loadSeq) return;
      sheets.value = parsedSheets.map((s, idx) => {
        const allRows = Array.isArray(s.data) ? s.data : [];
        const truncated = allRows.length > MAX_SHEET_ROWS;
        const rows = allRows.slice(0, MAX_SHEET_ROWS).map((row) =>
          Array.isArray(row) ? row.map((cell) => formatCellValue(cell)) : [],
        );
        return {
          name: s.sheet || `工作表 ${idx + 1}`,
          rows,
          truncated,
        };
      });
    } else if (ext === ".csv") {
      const text = await response.text();
      if (seq !== loadSeq) return;
      const parsed = parseCsvRows(text, MAX_SHEET_ROWS);
      sheets.value = [{ name: target.name, rows: parsed.rows, truncated: parsed.truncated }];
    }
  } catch (err) {
    if (seq !== loadSeq || props.isAbortError(err)) return;
    error.value = "文档预览失败：" + describeUserFacingError(err);
  } finally {
    if (seq === loadSeq) loading.value = false;
  }
}

watch(
  () => props.file?.path,
  (path) => {
    if (path) void loadOfficePreview();
    else {
      loadSeq += 1;
      docxHtml.value = "";
      sheets.value = [];
      error.value = "";
    }
  },
  { immediate: true },
);
</script>

<template>
  <IsleModal
    :open="Boolean(file)"
    :title="file?.name || '文档预览'"
    size="wide"
    role="dialog"
    aria-label="Office 文档只读预览"
    @close="emit('close')"
  >
    <template #icon>
      <FileSpreadsheet v-if="isSpreadsheet" :size="17" />
      <FileText v-else :size="17" />
    </template>

    <div v-if="file" class="office-shell">
      <div class="office-bar">
        <div class="office-bar-meta">
          <span class="office-pill">纯前端只读预览</span>
          <span class="office-pill">{{ formatBinaryBytes(file.size) }}</span>
        </div>
        <div class="office-bar-actions">
          <IsleButton
            v-if="fileExt === '.csv' && canWrite"
            type="button"
            variant="tonal"
            size="sm"
            @click="emit('editAsText', file)"
          >
            <template #icon><Pencil :size="13" /></template>
            以纯文本编辑
          </IsleButton>
          <IsleButton type="button" variant="primary" size="sm" @click="emit('download', file)">
            <template #icon><Download :size="13" /></template>
            下载原件
          </IsleButton>
        </div>
      </div>

      <IsleEmpty
        v-if="isTooLarge"
        compact
        :icon="isSpreadsheet ? FileSpreadsheet : FileText"
        title="文件超过 20 MiB，请下载原件查看"
        :description="`当前文件大小为 ${formatBinaryBytes(file.size)}。为避免浏览器内存占用过高，超过 20 MiB 的 Office 文档不进行网页解析，请直接下载后使用本地应用打开。`"
      >
        <template #action>
          <IsleButton variant="primary" size="sm" @click="emit('download', file)">
            <template #icon><Download :size="14" /></template>
            立即下载原件
          </IsleButton>
        </template>
      </IsleEmpty>

      <IsleBanner v-else-if="error" type="error" compact :message="error">
        <template #action>
          <IsleButton variant="tonal" size="sm" @click="emit('download', file)">下载原件</IsleButton>
        </template>
      </IsleBanner>

      <div v-else-if="loading" class="office-loading" role="status">
        正在按需加载解析组件并渲染文档…
      </div>

      <template v-else-if="fileExt === '.docx'">
        <div v-if="docxHtml" class="office-docx-sheet" v-html="docxHtml"></div>
        <IsleEmpty v-else compact :icon="FileText" title="文档正文为空" description="未检测到可展示的文字段落，可下载原件查看完整排版。" />
        <p v-if="docxNotices.length" class="office-footnote">提示：复杂页眉、批注或宏对象仅展示主体内容，完整排版请下载原件。</p>
      </template>

      <template v-else-if="isSpreadsheet">
        <div v-if="sheets.length > 1" class="office-sheet-tabs" role="tablist" aria-label="工作表切换">
          <button
            v-for="(sheet, idx) in sheets"
            :key="sheet.name + idx"
            type="button"
            role="tab"
            :aria-selected="activeSheetIndex === idx ? 'true' : 'false'"
            class="office-sheet-tab"
            :class="{ 'is-active': activeSheetIndex === idx }"
            @click="activeSheetIndex = idx"
          >
            {{ sheet.name }}
          </button>
        </div>

        <IsleBanner
          v-if="activeSheet?.truncated"
          type="info"
          compact
          message="当前工作表超过 2,000 行，仅预览前 2,000 行，完整数据请下载原件查看。"
        />

        <div v-if="activeSheet && activeSheet.rows.length" class="office-table-wrap">
          <table class="office-table">
            <thead>
              <tr>
                <th class="office-row-num">#</th>
                <th v-for="colIdx in activeSheetColCount" :key="colIdx">{{ activeSheet.rows[0]?.[colIdx - 1] || `列 ${colIdx}` }}</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="(row, rIdx) in activeSheet.rows.slice(1)" :key="rIdx">
                <td class="office-row-num">{{ rIdx + 2 }}</td>
                <td v-for="colIdx in activeSheetColCount" :key="colIdx">{{ row[colIdx - 1] ?? "" }}</td>
              </tr>
            </tbody>
          </table>
        </div>
        <IsleEmpty v-else compact :icon="FileSpreadsheet" title="当前工作表为空" description="此工作表没有可预览的数据行。" />
      </template>
    </div>

    <template #footer>
      <div class="office-footer">
        <IsleButton variant="glass" @click="emit('close')">关闭</IsleButton>
      </div>
    </template>
  </IsleModal>
</template>

<style scoped>
.office-shell {
  display: grid;
  gap: 10px;
}
.office-bar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  flex-wrap: wrap;
}
.office-bar-meta,
.office-bar-actions {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}
.office-pill {
  font-size: 11.5px;
  font-weight: 600;
  padding: 3px 9px;
  border-radius: 999px;
  background: var(--fluid-card-item-fill);
  border: 1px solid var(--fluid-card-border);
  color: var(--text-secondary);
}
.office-loading {
  padding: 44px 16px;
  text-align: center;
  font-size: 13px;
  color: var(--text-secondary);
}
.office-docx-sheet {
  max-height: 62vh;
  overflow-y: auto;
  padding: 22px 26px;
  border-radius: 13px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-top);
  color: var(--text-primary);
  font-size: 14px;
  line-height: 1.75;
  word-break: break-word;
}
.office-footnote {
  margin: 0;
  font-size: 11.5px;
  color: var(--text-tertiary);
}
.office-sheet-tabs {
  display: flex;
  align-items: center;
  gap: 6px;
  overflow-x: auto;
  padding-bottom: 2px;
}
.office-sheet-tab {
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
  color: var(--text-secondary);
  border-radius: 9px;
  padding: 5px 11px;
  font-size: 12px;
  font-weight: 600;
  white-space: nowrap;
  cursor: pointer;
}
.office-sheet-tab.is-active {
  background: color-mix(in srgb, var(--accent-primary) 13%, var(--fluid-card-top));
  border-color: color-mix(in srgb, var(--accent-primary) 46%, var(--fluid-card-border));
  color: var(--accent-primary);
}
.office-table-wrap {
  max-height: 60vh;
  overflow: auto;
  border-radius: 12px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-top);
}
.office-table {
  width: 100%;
  border-collapse: collapse;
  font-size: 12.5px;
  font-variant-numeric: tabular-nums;
}
.office-table th,
.office-table td {
  padding: 7px 11px;
  border-bottom: 1px solid var(--fluid-divider);
  border-right: 1px solid var(--fluid-divider);
  text-align: left;
  white-space: nowrap;
  max-width: 320px;
  overflow: hidden;
  text-overflow: ellipsis;
}
.office-table thead th {
  position: sticky;
  top: 0;
  z-index: 1;
  background: var(--fluid-card-item-fill);
  font-weight: 650;
  color: var(--text-primary);
}
.office-row-num {
  width: 44px;
  text-align: right;
  color: var(--text-tertiary);
  background: var(--fluid-card-item-fill);
}
.office-footer {
  display: flex;
  justify-content: flex-end;
  width: 100%;
}
</style>
