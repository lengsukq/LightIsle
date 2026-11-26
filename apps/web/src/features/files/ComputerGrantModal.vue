<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { Folder, Trash2, Users } from "lucide-vue-next";
import { apiFetch } from "../../api/apiClient.ts";
import { readApiFailure } from "../../api/apiFailure.ts";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import { requestConfirm } from "../../composables/useConfirmDialog.ts";
import AppleSelect from "../../components/ui/AppleSelect.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import IsleModal from "../../components/ui/IsleModal.vue";

export interface ComputerMember {
  id: number;
  username: string;
  role: string;
}

type GrantReply = { mode: string; folders: { path: string }[] };

const props = defineProps<{
  open: boolean;
  currentPath: string;
  members: ComputerMember[];
}>();

const emit = defineEmits<{
  (e: "close"): void;
}>();

const selected = ref("");
const grantMode = ref("none");
const folders = ref<string[]>([]);
const saving = ref(false);
const grantLoading = ref(false);
const grantReady = ref(false);
const grantNotice = ref("");
const grantError = ref("");
let grantGeneration = 0;

const memberOptions = computed(() =>
  props.members.map((u) => ({ value: String(u.id), label: u.username })),
);
const modes = [
  { value: "none", label: "无权限" },
  { value: "folders", label: "指定文件夹" },
  { value: "all", label: "整台电脑" },
];

async function requestJson<T>(url: string, method = "GET", json?: unknown): Promise<T> {
  const response = await apiFetch(url, { method, ...(json === undefined ? {} : { json }) });
  if (!response.ok) throw await readApiFailure(response);
  return (await response.json()) as T;
}

async function loadGrant() {
  if (!selected.value) return;
  const member = selected.value;
  const generation = ++grantGeneration;
  grantMode.value = "none";
  folders.value = [];
  grantLoading.value = true;
  grantReady.value = false;
  grantNotice.value = "";
  grantError.value = "";
  try {
    const grant = await requestJson<GrantReply>(`/api/v2/computer-files/grants/${member}`);
    if (generation !== grantGeneration || selected.value !== member) return;
    grantMode.value = grant.mode;
    folders.value = grant.folders.map((f) => f.path);
    grantReady.value = true;
  } catch (e) {
    if (generation === grantGeneration) grantError.value = describeUserFacingError(e);
  } finally {
    if (generation === grantGeneration && selected.value === member) grantLoading.value = false;
  }
}

async function saveGrant() {
  if (!selected.value || saving.value || grantLoading.value || !grantReady.value) return;
  const member = selected.value;
  const generation = grantGeneration;
  const nextMode = grantMode.value;
  const paths = [...folders.value];
  if (nextMode === "folders" && paths.length === 0) {
    grantError.value = "请先浏览并添加至少一个文件夹。";
    return;
  }
  if (
    nextMode === "all" &&
    !(await requestConfirm({
      title: "授权整台电脑",
      message: "该成员可以查看和下载 Mac 允许轻屿读取的所有文件，包括其他成员的私人文件。确认授权？",
    }))
  ) {
    return;
  }
  if (
    generation !== grantGeneration ||
    selected.value !== member ||
    !grantReady.value ||
    grantLoading.value ||
    grantMode.value !== nextMode ||
    folders.value.join("\0") !== paths.join("\0")
  ) {
    return;
  }
  saving.value = true;
  grantError.value = "";
  grantNotice.value = "";
  try {
    await requestJson(`/api/v2/computer-files/grants/${member}`, "PUT", { mode: nextMode, paths });
    grantNotice.value = "已保存该成员的电脑文件权限。";
  } catch (e) {
    grantError.value = `授权未保存：${describeUserFacingError(e)}`;
  } finally {
    saving.value = false;
  }
}

watch(
  () => props.open,
  (isOpen) => {
    if (!isOpen) return;
    grantError.value = "";
    grantNotice.value = "";
    if (selected.value) void loadGrant();
  },
);
</script>

<template>
  <IsleModal
    :open="open"
    title="家庭成员只读访问授权"
    description="整机权限可能包含私人资料，推荐按需选择「指定文件夹」并添加当前正在浏览的目录。"
    size="md"
    @close="emit('close')"
  >
    <template #icon><Users :size="16" /></template>

    <IsleEmpty
      v-if="!members.length"
      compact
      :icon="Users"
      title="暂无普通家庭成员"
      description="仅普通成员需要分配电脑文件只读权限；管理员默认可浏览宿主 Mac 允许访问的目录。"
    />
    <div v-else class="computer-grants-body">
      <div class="computer-grant-controls">
        <label class="computer-grant-field">
          <span>选择家庭成员</span>
          <AppleSelect v-model="selected" :options="memberOptions" placeholder="选择家庭成员" block :disabled="saving" @change="loadGrant" />
        </label>
        <label class="computer-grant-field">
          <span>授权范围</span>
          <AppleSelect v-model="grantMode" :options="modes" block :disabled="!selected || !grantReady || grantLoading || saving" />
        </label>
      </div>

      <div v-if="selected && !grantReady && !grantLoading" class="computer-grant-retry">
        <IsleButton variant="glass" size="sm" @click="loadGrant">重新读取权限</IsleButton>
      </div>

      <div v-if="grantMode === 'folders' && selected" class="computer-folders-box">
        <div class="computer-current-target">
          <div class="computer-current-target-info">
            <span class="computer-target-hint">当前正在浏览的目录可直接加入授权列表：</span>
            <code class="computer-folder-code">{{ currentPath || "未选定子目录" }}</code>
          </div>
          <IsleButton variant="tonal" size="sm" :disabled="!currentPath || folders.includes(currentPath)" @click="folders.push(currentPath)">
            添加当前目录
          </IsleButton>
        </div>

        <div v-if="folders.length" class="computer-grant-list">
          <div v-for="folder in folders" :key="folder" class="computer-grant-row">
            <Folder :size="14" class="computer-grant-folder-icon" aria-hidden="true" />
            <code class="computer-folder-code">{{ folder }}</code>
            <IsleButton variant="ghost" size="sm" aria-label="移除该授权目录" @click="folders = folders.filter((p) => p !== folder)">
              <template #icon><Trash2 :size="13" /></template>
              移除
            </IsleButton>
          </div>
        </div>
        <p v-else class="computer-grant-empty-note">尚未添加文件夹；请先关闭此弹窗打开目标目录，再回来添加。</p>
      </div>

      <IsleBanner v-if="grantError" type="error" compact role="alert" :message="grantError" />
      <IsleBanner v-if="grantNotice" type="success" compact role="status" :message="grantNotice" />
    </div>

    <template #footer>
      <IsleButton variant="glass" @click="emit('close')">关闭</IsleButton>
      <IsleButton
        v-if="members.length"
        variant="primary"
        :loading="saving"
        :disabled="!selected || !grantReady || saving || grantLoading"
        @click="saveGrant"
      >
        {{ saving ? "正在保存…" : grantLoading ? "正在读取权限…" : "保存权限" }}
      </IsleButton>
    </template>
  </IsleModal>
</template>

<style scoped>
.computer-grants-body,
.computer-folders-box {
  display: flex;
  flex-direction: column;
  gap: 12px;
}
.computer-grant-controls {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 10px;
}
.computer-grant-field {
  display: flex;
  flex-direction: column;
  gap: 5px;
  min-width: 0;
}
.computer-grant-field > span {
  font-size: 12px;
  font-weight: 600;
  color: var(--text-secondary);
}
.computer-grant-retry {
  display: flex;
  justify-content: flex-start;
}
.computer-current-target {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  flex-wrap: wrap;
  padding: 10px 12px;
  border-radius: 12px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
}
.computer-current-target-info {
  flex: 1 1 200px;
  min-width: 0;
  display: grid;
  gap: 3px;
}
.computer-target-hint {
  font-size: 12px;
  color: var(--text-secondary);
}
.computer-folder-code {
  flex: 1;
  min-width: 0;
  font-size: 12px;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  color: var(--text-primary);
  overflow-wrap: anywhere;
}
.computer-grant-list {
  display: flex;
  flex-direction: column;
  border: 1px solid var(--fluid-card-border);
  border-radius: 12px;
  background: var(--fluid-card-item-fill);
  overflow: hidden;
}
.computer-grant-row {
  display: flex;
  align-items: center;
  gap: 8px;
  min-height: 42px;
  padding: 6px 10px 6px 12px;
  border-bottom: 1px solid var(--fluid-divider, var(--fluid-card-border));
}
.computer-grant-row:last-child {
  border-bottom: 0;
}
.computer-grant-folder-icon {
  color: var(--accent-primary);
  flex-shrink: 0;
}
.computer-grant-empty-note {
  margin: 0;
  font-size: 12px;
  color: var(--text-tertiary);
}
@media (max-width: 640px) {
  .computer-grant-controls {
    grid-template-columns: minmax(0, 1fr);
  }
}
</style>
