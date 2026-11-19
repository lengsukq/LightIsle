<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { Folder, FileText, HardDrive, Monitor, RefreshCcw, ChevronLeft, Eye, Download } from "lucide-vue-next";
import { apiFetch } from "./apiClient.ts";
import { readApiFailure } from "./apiFailure.ts";
import { describeUserFacingError } from "./userFacingError.ts";
import { requestConfirm } from "./useConfirmDialog.ts";
import AppleSelect from "./AppleSelect.vue";
import IsleModal from "./IsleModal.vue";
import IsleCard from "./IsleCard.vue";
import IsleButton from "./IsleButton.vue";
import IsleBanner from "./IsleBanner.vue";
import IsleEmpty from "./IsleEmpty.vue";
import IsleHelpButton from "./IsleHelpButton.vue";
import IslePageHeader from "./IslePageHeader.vue";

const props = defineProps<{ admin: boolean }>();
type Entry = { name: string; path: string; type: "file" | "folder"; size: number };
type Member = { id: number; username: string; role: string };
type Grant = { mode: string; folders: { path: string }[] };

const enabled = ref(false), mode = ref("none"), path = ref(""), entries = ref<Entry[]>([]);
const busy = ref(false), error = ref(""), preview = ref<Entry | null>(null);
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
  error.value = ""; preview.value = null;
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

function canPreview(name: string) { return /\.(jpe?g|png|gif|webp|txt|md|json|log|mp4|webm|m4v|pdf)$/i.test(name); }

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
      <IslePageHeader title="电脑文件">
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
            刷新
          </IsleButton>
        </template>
      </IslePageHeader>

      <IsleBanner v-if="error" type="error" compact role="alert" :message="error" />

      <IsleEmpty
        v-if="!enabled && !busy"
        card
        :icon="Monitor"
        title="电脑文件访问未开启"
        description="请先在 Mac 的轻屿管理端「设置 → 安全」中开启「允许访问电脑文件」。"
      />
      <IsleEmpty
        v-else-if="enabled && !canOpen"
        card
        :icon="HardDrive"
        title="暂无访问权限"
        description="请联系管理员授权电脑文件或指定文件夹。"
      />

      <div v-if="canOpen" class="settings-stack">
        <IsleCard title="只读目录浏览" :subtitle="path || '已授权的文件夹'">
          <template #icon><Folder :size="18" /></template>
          <template #actions>
            <div class="computer-toolbar">
              <IsleButton variant="glass" size="sm" :disabled="!history.length" @click="goUp">
                <template #icon><ChevronLeft :size="14" /></template>
                返回上级
              </IsleButton>
              <IsleButton variant="glass" size="sm" :loading="browsing" @click="browse(path)">
                <template #icon><RefreshCcw :size="14" /></template>
                刷新目录
              </IsleButton>
            </div>
          </template>

          <IsleEmpty v-if="entries.length === 0" compact description="此文件夹为空，或没有可显示的普通文件。" />
          <div v-else class="computer-list">
            <div v-for="entry in entries" :key="entry.path" class="account-row computer-row">
              <button
                class="computer-name"
                type="button"
                @click="entry.type === 'folder' ? browse(entry.path, '', true) : canPreview(entry.name) ? (preview = entry) : null"
              >
                <span class="file-icon" :class="entry.type">
                  <Folder v-if="entry.type === 'folder'" :size="17" />
                  <FileText v-else :size="16" />
                </span>
                <strong>{{ entry.name }}</strong>
              </button>
              <div class="computer-entry-actions">
                <template v-if="entry.type === 'file'">
                  <IsleButton v-if="canPreview(entry.name)" variant="glass" size="sm" @click="preview = entry">
                    <template #icon><Eye :size="13" /></template>查看
                  </IsleButton>
                  <a class="computer-download-link" :href="fileUrl('content', entry.path)" download>
                    <Download :size="13" /> 下载
                  </a>
                </template>
                <IsleButton v-else variant="tonal" size="sm" @click="downloadFolder(entry)">
                  <template #icon><Download :size="13" /></template>下载文件夹
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
          title="成员访问权限"
          subtitle="整机权限可能包含其他成员的私人文件及敏感资料，请按需授权指定文件夹。"
        >
          <template #icon><Monitor :size="18" /></template>
          <div class="computer-grants-body">
            <div class="computer-toolbar">
              <AppleSelect v-model="selected" :options="memberOptions" placeholder="选择成员" :disabled="saving" @change="loadGrant" />
              <AppleSelect v-model="grantMode" :options="modes" :disabled="!selected || !grantReady || grantLoading || saving" />
              <IsleButton v-if="selected && !grantReady && !grantLoading" variant="glass" size="sm" @click="loadGrant">
                重新读取权限
              </IsleButton>
            </div>
            <div v-if="grantMode === 'folders' && selected" class="computer-folders-box">
              <div class="computer-toolbar">
                <span class="footnote">在上方打开目标文件夹后，可将当前文件夹加入该成员授权：</span>
                <IsleButton variant="tonal" size="sm" :disabled="!path || folders.includes(path)" @click="folders.push(path)">
                  添加当前文件夹
                </IsleButton>
              </div>
              <div v-if="folders.length" class="computer-list">
                <div v-for="folder in folders" :key="folder" class="account-row computer-row">
                  <code class="computer-folder-code">{{ folder }}</code>
                  <IsleButton variant="danger" size="sm" @click="folders = folders.filter(p => p !== folder)">移除</IsleButton>
                </div>
              </div>
            </div>
            <div>
              <IsleButton variant="primary" size="md" :loading="saving" :disabled="!selected || !grantReady || saving || grantLoading" @click="saveGrant">
                {{ saving ? "正在保存…" : grantLoading ? "正在读取权限…" : "保存权限" }}
              </IsleButton>
            </div>
            <IsleBanner v-if="grantNotice" type="success" compact role="status" :message="grantNotice" />
          </div>
        </IsleCard>
      </div>
    </div>

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
      <iframe v-if="preview" class="computer-preview-frame" :src="fileUrl('preview', preview.path)" title="文件只读预览" sandbox="allow-same-origin" />
    </IsleModal>
  </div>
</template>

<style scoped>
.computer-files-inner {
  max-width: 1040px;
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
  min-height: 44px;
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
  display: flex;
  align-items: center;
  gap: 10px;
  text-align: left;
  border: 0;
  background: transparent;
  color: var(--text-primary);
  padding: 0;
  cursor: pointer;
  font-size: 13px;
  overflow-wrap: anywhere;
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
