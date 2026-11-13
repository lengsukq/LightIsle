<script setup lang="ts">
import { computed, nextTick, onMounted, ref, watch } from "vue";
import { ChevronLeft, ChevronRight, Folder, LoaderCircle } from "lucide-vue-next";
import { describeUserFacingError } from "./userFacingError.ts";
import AppleSelect from "./AppleSelect.vue";
import IsleModal from "./IsleModal.vue";
import IsleButton from "./IsleButton.vue";
import IsleBanner from "./IsleBanner.vue";

const conflictOptions = [
  { value: "rename", label: "自动改名，保留原有文件" },
  { value: "skip", label: "跳过，不修改任何文件" },
  { value: "", label: "拒绝操作并提示冲突" },
];

type FolderEntry = { name: string; path: string; type: "file" | "folder"; canWrite?: boolean };
type FolderPage = { entries: FolderEntry[]; nextCursor: string; canWrite: boolean };
type Conflict = "" | "skip" | "rename";

const props = defineProps<{
  item: { name: string; path: string; type: "file" | "folder" };
  action: "copy" | "move";
  listFolders: (path: string, cursor: string) => Promise<FolderPage>;
  perform: (path: string, conflict: Conflict) => Promise<{ finalTo?: string; skipped?: boolean }>;
}>();

const emit = defineEmits<{
  (event: "close"): void;
  (event: "complete", message: string): void;
}>();

const dir = ref(".");
const name = ref(props.item.name);
const nameInputRef = ref<HTMLInputElement | null>(null);
const folders = ref<FolderEntry[]>([]);
const nextCursor = ref("");
const canWrite = ref(false);
const loading = ref(false);
const busy = ref(false);
const error = ref("");
const conflict = ref<Conflict>("rename");
let generation = 0;

onMounted(() => {
  void nextTick(() => {
    const el = nameInputRef.value;
    if (!el) return;
    el.focus();
    const raw = el.value;
    const dot = props.item.type === "folder" ? -1 : raw.lastIndexOf(".");
    const end = dot > 0 ? dot : raw.length;
    el.setSelectionRange(0, end);
  });
});

const breadcrumbs = computed(() => {
  if (dir.value === ".") return [{ label: "共享根目录", path: "." }];
  const parts = dir.value.split("/");
  return [{ label: "共享根目录", path: "." }, ...parts.map((part, i) => ({ label: part, path: parts.slice(0, i + 1).join("/") }))];
});

const destination = computed(() => (dir.value === "." ? name.value : dir.value + "/" + name.value));

const validName = computed(() => {
  const value = name.value.trim();
  return (
    value.length > 0 &&
    value !== "." &&
    value !== ".." &&
    !value.startsWith(".lightisle-") &&
    !value.includes("/") &&
    !value.includes("\\") &&
    !/[\u0000-\u001f]/.test(value)
  );
});

const invalidDescendant = computed(() => props.item.type === "folder" && destination.value.startsWith(props.item.path + "/"));

const canSubmit = computed(
  () =>
    !busy.value &&
    !loading.value &&
    canWrite.value &&
    validName.value &&
    !invalidDescendant.value &&
    (props.action === "copy" || destination.value !== props.item.path)
);

async function loadFolders(more = false) {
  const request = ++generation;
  const path = dir.value;
  loading.value = true;
  error.value = "";
  try {
    const data = await props.listFolders(path, more ? nextCursor.value : "");
    if (request !== generation || path !== dir.value) return;
    const entries = data.entries.filter((item) => item.type === "folder");
    folders.value = more ? [...folders.value, ...entries] : entries;
    nextCursor.value = data.nextCursor;
    canWrite.value = data.canWrite === true;
  } catch (e) {
    if (request === generation) error.value = "读取目标文件夹失败：" + describeUserFacingError(e);
  } finally {
    if (request === generation) loading.value = false;
  }
}

watch(
  dir,
  () => {
    folders.value = [];
    nextCursor.value = "";
    canWrite.value = false;
    void loadFolders();
  },
  { immediate: true }
);

async function submit() {
  if (!canSubmit.value) return;
  busy.value = true;
  error.value = "";
  try {
    const result = await props.perform(destination.value, conflict.value);
    const outcome = result.skipped ? "目标已存在，已跳过" : props.action === "copy" ? "复制完成" : "移动完成";
    emit("complete", outcome + "：" + (result.finalTo || destination.value));
  } catch (e) {
    error.value = "操作失败：" + describeUserFacingError(e);
  } finally {
    busy.value = false;
  }
}
</script>

<template>
  <IsleModal
    :open="true"
    :title="action === 'copy' ? '复制文件' : '移动或重命名'"
    :description="'来源：' + item.path"
    size="md"
    :close-on-backdrop="!busy"
    :close-on-esc="!busy"
    :show-close="!busy"
    @close="emit('close')"
  >
    <div class="file-op-dialog-content">
      <div class="file-operation-crumbs" aria-label="目标位置">
        <button
          v-for="crumb in breadcrumbs"
          :key="crumb.path"
          type="button"
          :disabled="loading || busy || crumb.path === dir"
          @click="dir = crumb.path"
        >
          {{ crumb.label }} <ChevronRight :size="13" />
        </button>
      </div>

      <div class="file-operation-folder-list">
        <p v-if="loading" class="file-operation-feedback"><LoaderCircle :size="15" class="spin-icon" /> 正在读取目录…</p>
        <template v-else>
          <button v-if="dir !== '.'" type="button" class="file-operation-folder" @click="dir = dir.split('/').slice(0, -1).join('/') || '.'">
            <ChevronLeft :size="17" /> 上一级
          </button>
          <button v-for="folder in folders" :key="folder.path" type="button" class="file-operation-folder" @click="dir = folder.path">
            <Folder :size="18" /> <span>{{ folder.name }}</span> <ChevronRight :size="15" />
          </button>
          <p v-if="!folders.length" class="file-operation-feedback">当前没有可浏览的子文件夹。</p>
          <IsleButton v-if="nextCursor" variant="glass" size="sm" class="file-operation-more" @click="loadFolders(true)">
            加载更多文件夹
          </IsleButton>
        </template>
      </div>

      <label class="file-operation-label">
        <span>目标文件名</span>
        <input ref="nameInputRef" v-model="name" autofocus maxlength="240" type="text" autocomplete="off" :disabled="busy" @keydown.enter.prevent="submit" />
      </label>

      <label class="file-operation-label">
        <span>已有同名文件时</span>
        <AppleSelect v-model="conflict" :options="conflictOptions" :disabled="busy" block aria-label="已有同名文件时" />
      </label>

      <p class="file-operation-destination">目标：{{ destination }}</p>

      <IsleBanner v-if="!canWrite && !loading" type="warning" compact message="你没有当前文件夹的写入权限，可浏览其他授权文件夹。" />
      <IsleBanner v-if="!validName" type="warning" compact message="请输入合法文件名，不能含路径分隔符或内部保留名称。" />
      <IsleBanner v-if="invalidDescendant" type="warning" compact message="不能将文件夹复制或移动到它自己的子目录。" />
      <IsleBanner v-if="error" type="error" compact :message="error" />
    </div>

    <template #footer>
      <div class="file-operation-actions">
        <IsleButton variant="glass" :disabled="busy" @click="emit('close')">取消</IsleButton>
        <IsleButton
          variant="primary"
          :disabled="!canSubmit"
          :loading="busy"
          @click="submit"
        >
          {{ action === "copy" ? "确认复制" : "确认移动" }}
        </IsleButton>
      </div>
    </template>
  </IsleModal>
</template>

<style scoped>
.file-op-dialog-content {
  display: flex;
  flex-direction: column;
  gap: 14px;
}

.file-operation-crumbs {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
}

.file-operation-crumbs button {
  display: flex;
  align-items: center;
  gap: 4px;
  font-size: 12px;
  padding: 5px 10px;
  border-radius: var(--radius-xs, 8px);
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
  color: var(--text-primary);
  cursor: pointer;
  transition: background 0.15s ease;
}

.file-operation-crumbs button:hover:not(:disabled) {
  background: var(--fluid-card-hover);
}

.file-operation-crumbs button:disabled {
  opacity: 0.65;
  cursor: default;
}

.file-operation-folder-list {
  border: 1px solid var(--fluid-card-border);
  border-radius: var(--radius-md, 16px);
  padding: 8px;
  min-height: 95px;
  max-height: 195px;
  overflow: auto;
  background: var(--fluid-card-item-fill);
}

.file-operation-folder {
  width: 100%;
  padding: 8px 12px;
  display: flex;
  align-items: center;
  gap: 10px;
  text-align: left;
  border-radius: var(--radius-sm, 10px);
  border: none;
  background: transparent;
  color: var(--text-primary);
  cursor: pointer;
  transition: background 0.15s ease;
  font-size: 13.5px;
}

.file-operation-folder:hover {
  background: var(--fluid-card-hover);
}

.file-operation-folder span {
  flex: 1;
  overflow: hidden;
  text-overflow: ellipsis;
}

.file-operation-feedback {
  padding: 12px;
  color: var(--text-secondary);
  font-size: 13px;
  display: flex;
  align-items: center;
  gap: 8px;
  margin: 0;
}

.file-operation-more {
  margin: 8px auto;
  display: flex;
}

.file-operation-label {
  font-size: 13px;
  font-weight: 600;
  display: grid;
  gap: 6px;
  color: var(--text-primary);
}

.file-operation-label input {
  width: 100%;
  min-width: 0;
  padding: 9px 12px;
  border-radius: var(--radius-sm, 10px);
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-fill);
  color: inherit;
  font-size: 13.5px;
  box-sizing: border-box;
  outline: none;
  transition: border-color 0.15s ease;
}

.file-operation-label input:focus {
  border-color: var(--accent-primary, #2563eb);
}

.file-operation-destination {
  font-size: 12.5px;
  overflow-wrap: anywhere;
  color: var(--text-secondary);
  margin: 0;
}

.file-operation-actions {
  display: flex;
  justify-content: flex-end;
  align-items: center;
  gap: 10px;
}

.spin-icon {
  animation: spin 1s linear infinite;
}

@keyframes spin {
  to {
    transform: rotate(360deg);
  }
}
</style>
