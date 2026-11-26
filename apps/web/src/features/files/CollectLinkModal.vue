<script setup lang="ts">
import { computed, ref, watch } from "vue";
import {
  Check, CheckCircle2, Clock, Copy, Eye, EyeOff, FolderUp, Inbox,
  Lock, RefreshCcw, Shield, Trash2, UploadCloud,
} from "lucide-vue-next";
import AppleSelect from "../../components/ui/AppleSelect.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleDisclosure from "../../components/ui/IsleDisclosure.vue";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import IsleModal from "../../components/ui/IsleModal.vue";
import { formatBinaryBytes, formatUnixDateTime } from "../../utils/format.ts";
import type { SharedFileEntry } from "./useFileShares.ts";
import {
  COLLECT_HOUR_OPTIONS,
  COLLECT_MAX_FILE_SIZE_OPTIONS,
  COLLECT_MAX_TOTAL_SIZE_OPTIONS,
  type CollectLink,
  type CollectLinkDraft,
} from "./fileCollectLinksApi.ts";

const MAX_FILES_PRESETS = [
  { value: 0, label: "不限数量" },
  { value: 20, label: "20 个" },
  { value: 100, label: "100 个" },
  { value: 500, label: "500 个" },
];

const props = defineProps<{
  open: boolean;
  tab: "create" | "list";
  folder: SharedFileEntry | null;
  links: CollectLink[];
  linksLoading: boolean;
  linksError: string;
  creating: boolean;
  createError: string;
  createdUrl: string;
  createdLink: CollectLink | null;
  copiedStatus: string;
  revokingId: string;
}>();

const emit = defineEmits<{
  "update:tab": [tab: "create" | "list"];
  submit: [draft: CollectLinkDraft];
  copy: [inputEl: HTMLInputElement | null];
  revoke: [link: CollectLink];
  refresh: [];
  resetCreated: [];
  close: [];
}>();

const title = ref("");
const hours = ref(72);
const password = ref("");
const showPassword = ref(false);
const maxFiles = ref(0);
const maxFileBytes = ref(0);
const maxTotalBytes = ref(0);
const allowedExtsText = ref("");
const limitsOpen = ref(false);
const linkInputRef = ref<HTMLInputElement | null>(null);

const canCreate = computed(() => Boolean(props.folder && props.folder.type === "folder"));

const selectedDurationLabel = computed(
  () => COLLECT_HOUR_OPTIONS.find((opt) => opt.value === hours.value)?.label ?? `${hours.value} 小时`,
);

const limitsMetaText = computed(() => {
  const parts: string[] = [];
  if (password.value.length > 0) parts.push("需口令");
  if (maxFiles.value > 0) parts.push(`限 ${maxFiles.value} 个`);
  if (maxFileBytes.value > 0) parts.push(`单文件 ≤ ${formatBinaryBytes(maxFileBytes.value)}`);
  if (maxTotalBytes.value > 0) parts.push(`总量 ≤ ${formatBinaryBytes(maxTotalBytes.value)}`);
  if (allowedExtsText.value.trim()) parts.push("限后缀");
  return parts.join(" · ");
});

function initDraftFromFolder() {
  title.value = props.folder?.name ? `${props.folder.name} · 文件收集` : "";
  hours.value = 72;
  password.value = "";
  showPassword.value = false;
  maxFiles.value = 0;
  maxFileBytes.value = 0;
  maxTotalBytes.value = 0;
  allowedExtsText.value = "";
  limitsOpen.value = false;
}

watch(
  () => [props.open, props.folder?.path] as const,
  ([isOpen]) => {
    if (isOpen) initDraftFromFolder();
  },
  { immediate: true },
);

watch(
  () => props.copiedStatus,
  (status) => {
    if (status && status !== "已复制") {
      linkInputRef.value?.select();
    }
  },
);

function onHoursInput(event: Event) {
  const raw = Number((event.target as HTMLInputElement).value);
  hours.value = Number.isFinite(raw) ? Math.max(1, Math.min(720, Math.trunc(raw))) : 24;
}

function onMaxFilesInput(event: Event) {
  const raw = Number((event.target as HTMLInputElement).value);
  maxFiles.value = Number.isFinite(raw) ? Math.max(0, Math.min(10000, Math.trunc(raw))) : 0;
}

function onSubmit() {
  if (!props.folder) return;
  emit("submit", {
    path: props.folder.path,
    hours: hours.value,
    title: title.value,
    password: password.value,
    maxFiles: maxFiles.value,
    maxFileBytes: maxFileBytes.value,
    maxTotalBytes: maxTotalBytes.value,
    allowedExtsText: allowedExtsText.value,
  });
}

function selectLinkText() {
  linkInputRef.value?.select();
}

function onClose() {
  if (!props.creating) emit("close");
}

function linkQuotaSummary(link: CollectLink): string {
  const parts: string[] = [];
  if (link.maxFiles > 0) parts.push(`上限 ${link.maxFiles} 个`);
  if (link.maxFileBytes > 0) parts.push(`单文件 ≤ ${formatBinaryBytes(link.maxFileBytes)}`);
  if (link.maxTotalBytes > 0) parts.push(`总计 ≤ ${formatBinaryBytes(link.maxTotalBytes)}`);
  if (link.allowedExts?.length) parts.push(`仅 ${link.allowedExts.slice(0, 4).join(" ")}`);
  return parts.length ? parts.join(" · ") : "不限文件数与体积";
}
</script>

<template>
  <IsleModal
    :open="open"
    :title="tab === 'create' ? '创建文件收集链接（亲友投递）' : '文件收集链接管理'"
    size="lg"
    role="dialog"
    aria-label="文件收集链接"
    :close-on-backdrop="!creating"
    :close-on-esc="!creating"
    :show-close="!creating"
    @close="onClose"
  >
    <template #icon><FolderUp :size="17" /></template>

    <div class="collect-tabs" role="tablist" aria-label="文件收集模式切换">
      <button
        v-if="canCreate"
        type="button"
        role="tab"
        :aria-selected="tab === 'create' ? 'true' : 'false'"
        class="collect-tab-btn"
        :class="{ 'is-active': tab === 'create' }"
        @click="emit('update:tab', 'create')"
      >
        <UploadCloud :size="14" /> 创建收集链接
      </button>
      <button
        type="button"
        role="tab"
        :aria-selected="tab === 'list' ? 'true' : 'false'"
        class="collect-tab-btn"
        :class="{ 'is-active': tab === 'list' }"
        @click="emit('update:tab', 'list'); emit('refresh')"
      >
        <Inbox :size="14" /> 文件收集管理
        <span v-if="links.length" class="collect-tab-count">{{ links.length }}</span>
      </button>
    </div>

    <div v-if="tab === 'create' && folder" class="collect-pane">
      <div class="collect-target-card">
        <span class="collect-target-icon" aria-hidden="true"><FolderUp :size="18" /></span>
        <div class="collect-target-meta">
          <strong :title="folder.path">{{ folder.name }}</strong>
          <small>仅投递上传（Write-Only）· 亲友免登录上传到「{{ folder.path }}」，绝不可浏览已有文件</small>
        </div>
      </div>

      <form v-if="!createdUrl" class="collect-form" @submit.prevent="onSubmit">
        <label class="collect-field">
          <span class="collect-label">投递箱标题</span>
          <input
            v-model="title"
            type="text"
            maxlength="120"
            :disabled="creating"
            placeholder="例如：春节全家福照片投递"
            class="collect-input"
          />
        </label>

        <div class="collect-field">
          <div class="collect-field-head">
            <span class="collect-label"><Clock :size="14" /> 有效期（1–720 小时）</span>
            <span class="collect-hint">{{ selectedDurationLabel }}后自动关闭投递</span>
          </div>
          <div class="collect-duration-row">
            <div class="collect-chips" role="radiogroup" aria-label="收集链接有效期">
              <button
                v-for="opt in COLLECT_HOUR_OPTIONS"
                :key="opt.value"
                type="button"
                role="radio"
                :aria-checked="hours === opt.value ? 'true' : 'false'"
                class="collect-chip"
                :class="{ 'is-selected': hours === opt.value }"
                :disabled="creating"
                @click="hours = opt.value"
              >
                {{ opt.label }}
              </button>
            </div>
            <label class="collect-custom-hours">
              <input
                :value="hours"
                type="number"
                min="1"
                max="720"
                step="1"
                :disabled="creating"
                aria-label="自定义有效小时数"
                class="collect-num-input"
                @input="onHoursInput"
              />
              <span>小时</span>
            </label>
          </div>
        </div>

        <IsleDisclosure
          v-model="limitsOpen"
          title="口令保护与接收配额上限（选填）"
          subtitle="可设置投递口令、最多文件数、单文件/总容量与允许后缀"
          :icon="Shield"
        >
          <template v-if="limitsMetaText" #meta>
            <span class="collect-badge">{{ limitsMetaText }}</span>
          </template>

          <div class="collect-limits-grid">
            <label class="collect-field">
              <span class="collect-label">投递口令（4–128 字节，留空则免口令）</span>
              <div class="collect-password-wrap">
                <Lock :size="14" class="collect-input-leading" aria-hidden="true" />
                <input
                  v-model="password"
                  :type="showPassword ? 'text' : 'password'"
                  autocomplete="new-password"
                  maxlength="128"
                  :disabled="creating"
                  placeholder="留空则直接打开投递页"
                  class="collect-input collect-input-pwd"
                />
                <button
                  type="button"
                  class="collect-eye-btn"
                  :aria-label="showPassword ? '隐藏口令' : '显示口令'"
                  @click="showPassword = !showPassword"
                >
                  <EyeOff v-if="showPassword" :size="14" />
                  <Eye v-else :size="14" />
                </button>
              </div>
            </label>

            <div class="collect-field">
              <span class="collect-label">最多接收文件数（0 = 不限）</span>
              <div class="collect-preset-row">
                <button
                  v-for="preset in MAX_FILES_PRESETS"
                  :key="preset.value"
                  type="button"
                  class="collect-preset-chip"
                  :class="{ 'is-selected': maxFiles === preset.value }"
                  :disabled="creating"
                  @click="maxFiles = preset.value"
                >
                  {{ preset.label }}
                </button>
                <input
                  :value="maxFiles"
                  type="number"
                  min="0"
                  max="10000"
                  step="1"
                  :disabled="creating"
                  aria-label="自定义最多接收文件数"
                  class="collect-num-input"
                  @input="onMaxFilesInput"
                />
              </div>
            </div>

            <div class="collect-two-col">
              <div class="collect-field">
                <span class="collect-label">单文件体积上限</span>
                <AppleSelect
                  v-model="maxFileBytes"
                  :options="COLLECT_MAX_FILE_SIZE_OPTIONS"
                  :disabled="creating"
                  size="sm"
                  aria-label="单文件体积上限"
                />
              </div>
              <div class="collect-field">
                <span class="collect-label">总接收容量上限</span>
                <AppleSelect
                  v-model="maxTotalBytes"
                  :options="COLLECT_MAX_TOTAL_SIZE_OPTIONS"
                  :disabled="creating"
                  size="sm"
                  aria-label="总接收容量上限"
                />
              </div>
            </div>

            <label class="collect-field">
              <span class="collect-label">限定文件扩展名（选填，逗号或空格分隔）</span>
              <input
                v-model="allowedExtsText"
                type="text"
                :disabled="creating"
                placeholder="例如：.jpg, .png, .heic, .mp4（留空则不限类型）"
                class="collect-input"
              />
            </label>
          </div>
        </IsleDisclosure>

        <IsleBanner v-if="createError" type="error" compact :message="createError" />

        <IsleButton type="submit" variant="primary" :loading="creating" full-width>
          {{ creating ? "正在创建收集链接…" : "生成亲友投递链接" }}
        </IsleButton>
      </form>

      <div v-else class="collect-created-card" role="region" aria-label="已生成的收集链接">
        <div class="collect-created-head">
          <span class="collect-created-badge"><CheckCircle2 :size="15" /> 投递链接已生成</span>
          <div class="collect-created-tags">
            <span>仅上传 · 不可浏览原目录</span>
            <span>有效期 {{ selectedDurationLabel }}</span>
            <span v-if="createdLink?.hasPassword">需口令验证</span>
          </div>
        </div>

        <div class="collect-link-row">
          <input
            ref="linkInputRef"
            :value="createdUrl"
            readonly
            aria-label="文件收集投递链接"
            class="collect-input collect-link-mono"
            @focus="selectLinkText"
            @click="selectLinkText"
          />
          <IsleButton type="button" variant="primary" size="md" @click="emit('copy', linkInputRef)">
            <template #icon>
              <Check v-if="copiedStatus === '已复制'" :size="15" />
              <Copy v-else :size="15" />
            </template>
            {{ copiedStatus === "已复制" ? "已复制" : "复制链接" }}
          </IsleButton>
        </div>

        <p v-if="copiedStatus" class="collect-copy-status" role="status">{{ copiedStatus }} · 发给亲友即可通过浏览器直接上传</p>
        <p v-else class="collect-copy-hint">投递链接仅此时完整显示；可在「文件收集管理」标签中查看已收文件统计或随时撤销。</p>

        <div class="collect-created-actions">
          <IsleButton type="button" variant="tonal" size="sm" @click="emit('resetCreated')">再建一个链接</IsleButton>
          <IsleButton type="button" variant="glass" size="sm" @click="emit('update:tab', 'list')">查看收集管理</IsleButton>
        </div>
      </div>
    </div>

    <div v-else class="collect-pane">
      <div class="collect-list-bar">
        <span class="collect-list-caption">当前共享盘生效中的亲友投递链接（共 {{ links.length }} 条）</span>
        <IsleButton type="button" variant="glass" size="sm" :disabled="linksLoading" @click="emit('refresh')">
          <template #icon><RefreshCcw :size="13" :class="{ spinning: linksLoading }" /></template>
          刷新
        </IsleButton>
      </div>

      <IsleBanner v-if="linksError" type="error" compact :message="linksError" />

      <div v-if="linksLoading && !links.length" class="collect-status-empty" role="status">正在读取文件收集链接…</div>
      <IsleEmpty
        v-else-if="!links.length"
        compact
        :icon="Inbox"
        title="暂无生效中的收集链接"
        description="可在任意可写文件夹的右键或操作菜单中选择「创建收集链接（亲友投递）」。"
      />
      <div v-else class="collect-list">
        <article v-for="item in links" :key="item.id" class="collect-list-item">
          <div class="collect-item-main">
            <div class="collect-item-head">
              <strong :title="item.title">{{ item.title || item.targetPath }}</strong>
              <span v-if="item.hasPassword" class="collect-mini-tag"><Lock :size="11" /> 口令保护</span>
            </div>
            <p class="collect-item-path">目标文件夹：{{ item.targetPath }}</p>
            <div class="collect-item-stats">
              <span class="collect-stat-strong">已收到 {{ item.uploadedFiles }} 个文件 · {{ formatBinaryBytes(item.uploadedBytes) }}</span>
              <span>{{ linkQuotaSummary(item) }}</span>
              <span>到期：{{ formatUnixDateTime(item.expiresAt, "未设置") }}</span>
            </div>
          </div>
          <div class="collect-item-actions">
            <IsleButton
              type="button"
              variant="danger"
              size="sm"
              :loading="revokingId === item.id"
              :disabled="Boolean(revokingId && revokingId !== item.id)"
              @click="emit('revoke', item)"
            >
              <template #icon><Trash2 :size="13" /></template>
              撤销
            </IsleButton>
          </div>
        </article>
      </div>
    </div>

    <template #footer>
      <div class="collect-footer">
        <IsleButton variant="glass" :disabled="creating" @click="onClose">{{ createdUrl ? "完成" : "关闭" }}</IsleButton>
      </div>
    </template>
  </IsleModal>
</template>

<style scoped>
.collect-tabs { display: inline-flex; align-items: center; gap: 4px; padding: 4px; border-radius: 12px; background: var(--fluid-card-item-fill); border: 1px solid var(--fluid-card-border); margin-bottom: 12px; }
.collect-tab-btn { display: inline-flex; align-items: center; gap: 6px; padding: 6px 12px; border: 0; border-radius: 9px; background: transparent; color: var(--text-secondary); font-size: 12.5px; font-weight: 600; cursor: pointer; transition: background-color 150ms ease, color 150ms ease; }
.collect-tab-btn.is-active { background: var(--fluid-card-top); color: var(--text-primary); box-shadow: var(--fluid-item-card-shadow); }
.collect-tab-count { font-size: 11px; padding: 1px 6px; border-radius: 999px; background: color-mix(in srgb, var(--accent-primary) 13%, transparent); color: var(--accent-primary); font-variant-numeric: tabular-nums; }
.collect-pane { display: grid; gap: 12px; }
.collect-target-card { display: flex; align-items: center; gap: 11px; padding: 10px 12px; border-radius: 13px; border: 1px solid var(--fluid-card-border); background: var(--fluid-card-item-fill); }
.collect-target-icon { width: 36px; height: 36px; border-radius: 10px; display: grid; place-items: center; flex-shrink: 0; background: color-mix(in srgb, var(--accent-primary) 13%, transparent); color: var(--accent-primary); }
.collect-target-meta { min-width: 0; display: grid; gap: 2px; }
.collect-target-meta strong { font-size: 13.5px; font-weight: 650; color: var(--text-primary); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.collect-target-meta small { font-size: 11.5px; color: var(--text-secondary); line-height: 1.4; }
.collect-form { display: grid; gap: 13px; }
.collect-field { display: grid; gap: 6px; }
.collect-field-head { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
.collect-label { display: inline-flex; align-items: center; gap: 5px; font-size: 12px; font-weight: 650; color: var(--text-secondary); }
.collect-hint { font-size: 11.5px; color: var(--text-tertiary); }
.collect-input, .collect-num-input { box-sizing: border-box; width: 100%; min-height: 36px; padding: 7px 11px; border: 1px solid var(--fluid-card-border); border-radius: 10px; background: var(--fluid-card-top); color: var(--text-primary); font: inherit; font-size: 13px; outline: none; transition: border-color 150ms ease, box-shadow 150ms ease; }
.collect-input:focus, .collect-num-input:focus { border-color: var(--accent-primary); box-shadow: 0 0 0 3px color-mix(in srgb, var(--accent-primary) 16%, transparent); }
.collect-duration-row { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.collect-chips { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; flex: 1; }
.collect-chip, .collect-preset-chip { min-height: 32px; padding: 5px 10px; border-radius: 10px; border: 1px solid var(--fluid-card-border); background: var(--fluid-card-item-fill); color: var(--text-secondary); font-size: 12px; font-weight: 580; cursor: pointer; white-space: nowrap; }
.collect-chip.is-selected, .collect-preset-chip.is-selected { background: color-mix(in srgb, var(--accent-primary) 13%, var(--fluid-card-top)); border-color: color-mix(in srgb, var(--accent-primary) 46%, var(--fluid-card-border)); color: var(--accent-primary); font-weight: 650; }
.collect-custom-hours { display: inline-flex; align-items: center; gap: 5px; font-size: 12px; color: var(--text-secondary); }
.collect-num-input { width: 78px; min-height: 32px; padding: 4px 8px; font-variant-numeric: tabular-nums; }
.collect-badge { font-size: 11px; font-weight: 600; padding: 2px 8px; border-radius: 999px; color: var(--accent-primary); background: color-mix(in srgb, var(--accent-primary) 11%, transparent); }
.collect-limits-grid { display: grid; gap: 12px; }
.collect-two-col { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; }
.collect-preset-row { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; }
.collect-password-wrap { position: relative; display: flex; align-items: center; }
.collect-input-leading { position: absolute; left: 11px; color: var(--text-tertiary); pointer-events: none; }
.collect-input-pwd { padding-left: 32px; padding-right: 36px; }
.collect-eye-btn { position: absolute; right: 6px; width: 26px; height: 26px; border: 0; border-radius: 7px; background: transparent; color: var(--text-tertiary); display: grid; place-items: center; cursor: pointer; }
.collect-created-card { display: grid; gap: 12px; padding: 14px; border-radius: 14px; border: 1px solid color-mix(in srgb, var(--success) 30%, var(--fluid-card-border)); background: color-mix(in srgb, var(--success) 5%, var(--fluid-card-item-fill)); }
.collect-created-head { display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: 8px; }
.collect-created-badge { display: inline-flex; align-items: center; gap: 5px; font-size: 13px; font-weight: 650; color: var(--success); }
.collect-created-tags { display: flex; flex-wrap: wrap; gap: 5px; }
.collect-created-tags span { font-size: 11px; padding: 2px 8px; border-radius: 999px; background: var(--fluid-card-top); border: 1px solid var(--fluid-card-border); color: var(--text-secondary); }
.collect-link-row { display: flex; align-items: center; gap: 8px; }
.collect-link-mono { flex: 1; min-width: 0; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; }
.collect-copy-status { margin: 0; font-size: 12px; font-weight: 600; color: var(--accent-primary); }
.collect-copy-hint { margin: 0; font-size: 11.5px; color: var(--text-secondary); }
.collect-created-actions { display: flex; gap: 8px; flex-wrap: wrap; }
.collect-list-bar { display: flex; align-items: center; justify-content: space-between; gap: 10px; }
.collect-list-caption { font-size: 12px; color: var(--text-secondary); }
.collect-status-empty { padding: 28px 12px; text-align: center; font-size: 13px; color: var(--text-secondary); }
.collect-list { display: grid; gap: 8px; max-height: 50vh; overflow-y: auto; }
.collect-list-item { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 11px 13px; border-radius: 12px; border: 1px solid var(--fluid-card-border); background: var(--fluid-card-item-fill); }
.collect-item-main { min-width: 0; display: grid; gap: 4px; }
.collect-item-head { display: flex; align-items: center; gap: 7px; flex-wrap: wrap; }
.collect-item-head strong { font-size: 13.5px; color: var(--text-primary); }
.collect-mini-tag { display: inline-flex; align-items: center; gap: 3px; font-size: 11px; font-weight: 600; padding: 1px 7px; border-radius: 999px; background: color-mix(in srgb, var(--accent-primary) 11%, transparent); color: var(--accent-primary); }
.collect-item-path { margin: 0; font-size: 12px; color: var(--text-secondary); word-break: break-all; }
.collect-item-stats { display: flex; align-items: center; flex-wrap: wrap; gap: 6px 12px; font-size: 11.5px; color: var(--text-tertiary); font-variant-numeric: tabular-nums; }
.collect-stat-strong { font-weight: 650; color: var(--text-primary); }
.collect-item-actions { flex-shrink: 0; }
.collect-footer { display: flex; justify-content: flex-end; width: 100%; }
@media (max-width: 560px) {
  .collect-two-col { grid-template-columns: 1fr; }
  .collect-link-row, .collect-list-item { flex-direction: column; align-items: stretch; }
}
@media (prefers-reduced-motion: reduce) {
  .collect-tab-btn, .collect-input, .collect-num-input { transition: none; }
}
</style>
