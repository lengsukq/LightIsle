<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { Check, CheckCircle2, Clock, Copy, Eye, EyeOff, Folder, FolderUp, FileText, Inbox, Lock, Share2, Shield } from "lucide-vue-next";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleDisclosure from "../../components/ui/IsleDisclosure.vue";
import IsleModal from "../../components/ui/IsleModal.vue";
import type { SharedFileEntry } from "./useFileShares.ts";

const DEFAULT_HOUR_OPTIONS = [
  { value: 1, label: "1 小时" },
  { value: 6, label: "6 小时" },
  { value: 24, label: "1 天" },
  { value: 72, label: "3 天" },
  { value: 168, label: "7 天" },
];

const DOWNLOAD_PRESETS = [
  { value: 0, label: "不限次数" },
  { value: 1, label: "1 次" },
  { value: 5, label: "5 次" },
  { value: 20, label: "20 次" },
];

const props = withDefaults(
  defineProps<{
    file: SharedFileEntry | null;
    hours: number;
    password: string;
    maxDownloads: number;
    creating: boolean;
    createdLink: string;
    error: string;
    copied: string;
    hourOptions?: Array<{ value: number; label: string }>;
    canCollect?: boolean;
  }>(),
  {
    hourOptions: undefined,
    canCollect: false,
  },
);

const emit = defineEmits<{
  "update:hours": [value: number];
  "update:password": [value: string];
  "update:maxDownloads": [value: number];
  "link-input": [el: HTMLInputElement | null];
  "open-collect-create": [folder: SharedFileEntry];
  "open-collect-manage": [];
  submit: [];
  copy: [];
  close: [];
}>();

const showPassword = ref(false);
const advancedOpen = ref(false);
const localLinkInput = ref<HTMLInputElement | null>(null);

const resolvedHourOptions = computed(() =>
  props.hourOptions?.length ? props.hourOptions : DEFAULT_HOUR_OPTIONS,
);

const selectedDurationLabel = computed(
  () => resolvedHourOptions.value.find((opt) => opt.value === props.hours)?.label ?? `${props.hours} 小时`,
);

const hasAdvancedOptions = computed(() => props.password.length > 0 || props.maxDownloads > 0);

const advancedMetaText = computed(() => {
  const parts: string[] = [];
  if (props.password.length > 0) parts.push("已设密码");
  if (props.maxDownloads > 0) parts.push(`限 ${props.maxDownloads} 次`);
  return parts.join(" · ");
});

function setLinkInputRef(el: unknown) {
  const input = el instanceof HTMLInputElement ? el : null;
  localLinkInput.value = input;
  emit("link-input", input);
}

function selectLinkText() {
  localLinkInput.value?.select();
}

function onMaxDownloadsInput(event: Event) {
  const raw = Number((event.target as HTMLInputElement).value);
  emit("update:maxDownloads", Number.isFinite(raw) ? Math.max(0, Math.min(100000, Math.trunc(raw))) : 0);
}

function onClose() {
  if (!props.creating) emit("close");
}

watch(
  () => props.file,
  () => {
    showPassword.value = false;
    advancedOpen.value = false;
  },
);

watch(
  () => props.copied,
  (status) => {
    if (status && status !== "已复制") {
      selectLinkText();
    }
  },
);
</script>

<template>
  <IsleModal
    :open="Boolean(file)"
    :title="createdLink ? '分享链接已生成' : '创建限时分享'"
    size="md"
    role="dialog"
    aria-label="文件下载分享"
    :close-on-backdrop="!creating"
    :close-on-esc="!creating"
    :show-close="!creating"
    @close="onClose"
  >
    <template #icon><Share2 :size="17" /></template>

    <div v-if="file" class="share-mode-tabs" role="tablist" aria-label="分享与文件收集模式">
      <button type="button" role="tab" aria-selected="true" class="share-mode-tab is-active">
        <Share2 :size="13" /> 临时下载分享
      </button>
      <button
        v-if="canCollect && file.type === 'folder'"
        type="button"
        role="tab"
        aria-selected="false"
        class="share-mode-tab"
        @click="emit('open-collect-create', file)"
      >
        <FolderUp :size="13" /> 创建收集链接（亲友投递）
      </button>
      <button
        type="button"
        role="tab"
        aria-selected="false"
        class="share-mode-tab"
        @click="emit('open-collect-manage')"
      >
        <Inbox :size="13" /> 文件收集
      </button>
    </div>

    <div v-if="file" class="share-target-card">
      <span class="share-target-icon" :class="file.type === 'folder' ? 'is-folder' : 'is-file'" aria-hidden="true">
        <Folder v-if="file.type === 'folder'" :size="18" />
        <FileText v-else :size="18" />
      </span>
      <div class="share-target-meta">
        <strong :title="file.name">{{ file.name }}</strong>
        <small>{{ file.type === "folder" ? "免登录临时 ZIP 打包下载 · 到期或授权变更后失效" : "免登录临时下载链接 · 到期、变更或撤销后失效" }}</small>
      </div>
    </div>

    <form v-if="!createdLink" class="share-sheet-form" @submit.prevent="emit('submit')">
      <div class="share-field-block">
        <div class="share-field-head">
          <span class="share-field-label"><Clock :size="14" /> 有效期</span>
          <span class="share-field-hint">{{ selectedDurationLabel }}后自动失效</span>
        </div>
        <div class="share-duration-chips" role="radiogroup" aria-label="分享链接有效期">
          <button
            v-for="opt in resolvedHourOptions"
            :key="opt.value"
            type="button"
            role="radio"
            :aria-checked="hours === opt.value ? 'true' : 'false'"
            class="share-duration-chip"
            :class="{ 'is-selected': hours === opt.value }"
            :disabled="creating"
            @click="emit('update:hours', opt.value)"
          >
            {{ opt.label }}
          </button>
        </div>
      </div>

      <IsleDisclosure
        v-model="advancedOpen"
        title="访问保护与次数限制（选填）"
        subtitle="可设置访问密码或限制最多下载次数"
        :icon="Shield"
      >
        <template v-if="hasAdvancedOptions" #meta>
          <span class="share-advanced-badge">{{ advancedMetaText }}</span>
        </template>

        <div class="share-advanced-fields">
          <label class="share-input-label">
            <span>访问密码（至少 4 个字符）</span>
            <div class="share-password-wrap">
              <Lock :size="14" class="share-input-leading" aria-hidden="true" />
              <input
                :value="password"
                :type="showPassword ? 'text' : 'password'"
                autocomplete="new-password"
                maxlength="128"
                :disabled="creating"
                placeholder="不设置密码则留空"
                @input="emit('update:password', ($event.target as HTMLInputElement).value)"
              />
              <button
                type="button"
                class="share-eye-btn"
                :aria-label="showPassword ? '隐藏密码' : '显示密码'"
                :title="showPassword ? '隐藏密码' : '显示密码'"
                @click="showPassword = !showPassword"
              >
                <EyeOff v-if="showPassword" :size="14" />
                <Eye v-else :size="14" />
              </button>
            </div>
          </label>

          <div class="share-input-label">
            <span>最多下载次数（0 = 不限制）</span>
            <div class="share-limit-row">
              <div class="share-limit-presets" role="group" aria-label="常用下载次数限制">
                <button
                  v-for="preset in DOWNLOAD_PRESETS"
                  :key="preset.value"
                  type="button"
                  class="share-preset-chip"
                  :class="{ 'is-selected': maxDownloads === preset.value }"
                  :disabled="creating"
                  @click="emit('update:maxDownloads', preset.value)"
                >
                  {{ preset.label }}
                </button>
              </div>
              <input
                :value="maxDownloads"
                type="number"
                min="0"
                max="100000"
                step="1"
                :disabled="creating"
                aria-label="自定义最多下载次数"
                class="share-limit-input"
                @input="onMaxDownloadsInput"
              />
            </div>
          </div>
        </div>
      </IsleDisclosure>

      <IsleBanner v-if="error" type="error" compact :message="error" />

      <IsleButton type="submit" variant="primary" :loading="creating" full-width>
        {{ creating ? "正在生成…" : "生成分享链接" }}
      </IsleButton>
    </form>

    <div v-else class="share-created-card" role="region" aria-label="已生成的分享链接">
      <div class="share-created-head">
        <span class="share-created-badge"><CheckCircle2 :size="15" /> 链接已就绪</span>
        <div class="share-created-tags">
          <span>有效期 {{ selectedDurationLabel }}</span>
          <span v-if="password">需密码访问</span>
          <span v-if="maxDownloads > 0">限 {{ maxDownloads }} 次下载</span>
        </div>
      </div>

      <div class="share-link-row">
        <input
          :ref="setLinkInputRef"
          :value="createdLink"
          readonly
          aria-label="分享链接"
          class="share-link-input"
          @focus="selectLinkText"
          @click="selectLinkText"
        />
        <IsleButton type="button" variant="primary" size="md" @click="emit('copy')">
          <template #icon>
            <Check v-if="copied === '已复制'" :size="15" />
            <Copy v-else :size="15" />
          </template>
          {{ copied === "已复制" ? "已复制" : "复制链接" }}
        </IsleButton>
      </div>

      <p v-if="copied" class="share-copy-status" role="status">{{ copied }} · 可在「偏好设置 → 文件与存储」中随时撤销</p>
      <p v-else class="share-copy-hint">链接仅此时完整显示；可在「偏好设置 → 文件与存储」中查看与撤销。</p>

      <IsleBanner v-if="error" type="error" compact :message="error" />
    </div>

    <template #footer>
      <div class="share-modal-footer">
        <IsleButton variant="glass" :disabled="creating" @click="onClose">{{ createdLink ? "完成" : "取消" }}</IsleButton>
      </div>
    </template>
  </IsleModal>
</template>

<style scoped>
.share-mode-tabs {
  display: inline-flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 4px;
  padding: 4px;
  margin-bottom: 12px;
  border-radius: 11px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
}
.share-mode-tab {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  padding: 5px 10px;
  border: 0;
  border-radius: 8px;
  background: transparent;
  color: var(--text-secondary);
  font-size: 12px;
  font-weight: 600;
  cursor: pointer;
}
.share-mode-tab:hover {
  color: var(--text-primary);
}
.share-mode-tab.is-active {
  background: var(--fluid-card-top);
  color: var(--text-primary);
  box-shadow: var(--fluid-item-card-shadow);
}
.share-target-card {
  display: flex;
  align-items: center;
  gap: 11px;
  padding: 10px 12px;
  border-radius: 13px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
}
.share-target-icon {
  width: 36px;
  height: 36px;
  border-radius: 10px;
  display: grid;
  place-items: center;
  flex-shrink: 0;
}
.share-target-icon.is-folder {
  background: color-mix(in srgb, var(--accent-primary) 13%, transparent);
  color: var(--accent-primary);
}
.share-target-icon.is-file {
  background: color-mix(in srgb, var(--text-primary) 7%, transparent);
  color: var(--text-secondary);
}
.share-target-meta {
  min-width: 0;
  display: grid;
  gap: 2px;
}
.share-target-meta strong {
  font-size: 13.5px;
  font-weight: 650;
  color: var(--text-primary);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.share-target-meta small {
  font-size: 11.5px;
  color: var(--text-secondary);
  line-height: 1.4;
}

.share-sheet-form {
  display: flex;
  flex-direction: column;
  gap: 14px;
}
.share-field-block {
  display: grid;
  gap: 8px;
}
.share-field-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
}
.share-field-label {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  font-size: 12.5px;
  font-weight: 650;
  color: var(--text-primary);
}
.share-field-hint {
  font-size: 11.5px;
  color: var(--text-tertiary);
}

.share-duration-chips {
  display: grid;
  grid-template-columns: repeat(5, minmax(0, 1fr));
  gap: 6px;
}
.share-duration-chip,
.share-preset-chip {
  min-height: 34px;
  padding: 6px 8px;
  border-radius: 10px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
  color: var(--text-secondary);
  font-size: 12.5px;
  font-weight: 580;
  cursor: pointer;
  white-space: nowrap;
  transition: background-color 150ms ease, border-color 150ms ease, color 150ms ease, transform 180ms var(--motion-spring);
}
.share-duration-chip:hover:not(:disabled),
.share-preset-chip:hover:not(:disabled) {
  background: var(--fluid-card-hover);
  border-color: var(--fluid-card-border-strong);
  color: var(--text-primary);
}
.share-duration-chip.is-selected,
.share-preset-chip.is-selected {
  background: color-mix(in srgb, var(--accent-primary) 13%, var(--fluid-card-top));
  border-color: color-mix(in srgb, var(--accent-primary) 46%, var(--fluid-card-border));
  color: var(--accent-primary);
  font-weight: 650;
}
.share-duration-chip:active:not(:disabled),
.share-preset-chip:active:not(:disabled) {
  transform: scale(0.97);
}

.share-advanced-badge {
  font-size: 11px;
  font-weight: 600;
  padding: 2px 8px;
  border-radius: 999px;
  color: var(--accent-primary);
  background: color-mix(in srgb, var(--accent-primary) 11%, transparent);
}
.share-advanced-fields {
  display: grid;
  gap: 12px;
}
.share-input-label {
  display: grid;
  gap: 6px;
  font-size: 12px;
  font-weight: 600;
  color: var(--text-secondary);
}
.share-password-wrap {
  position: relative;
  display: flex;
  align-items: center;
}
.share-input-leading {
  position: absolute;
  left: 11px;
  color: var(--text-tertiary);
  pointer-events: none;
}
.share-password-wrap input,
.share-limit-input,
.share-link-input {
  box-sizing: border-box;
  width: 100%;
  min-height: 36px;
  border: 1px solid var(--fluid-card-border);
  border-radius: 10px;
  background: var(--fluid-card-top);
  color: var(--text-primary);
  font: inherit;
  font-size: 13px;
  outline: none;
  transition: border-color 150ms ease, box-shadow 150ms ease;
}
.share-password-wrap input {
  padding: 7px 36px 7px 32px;
}
.share-password-wrap input::-ms-reveal,
.share-password-wrap input::-ms-clear {
  display: none;
}
.share-eye-btn {
  position: absolute;
  right: 6px;
  width: 26px;
  height: 26px;
  border: 0;
  border-radius: 7px;
  background: transparent;
  color: var(--text-tertiary);
  display: grid;
  place-items: center;
  cursor: pointer;
}
.share-eye-btn:hover {
  color: var(--text-primary);
  background: color-mix(in srgb, var(--text-primary) 7%, transparent);
}
.share-limit-row {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}
.share-limit-presets {
  display: flex;
  align-items: center;
  gap: 5px;
  flex-wrap: wrap;
}
.share-preset-chip {
  min-height: 30px;
  padding: 4px 10px;
  font-size: 12px;
  border-radius: 999px;
}
.share-limit-input {
  width: 86px;
  min-height: 30px;
  padding: 4px 9px;
  font-variant-numeric: tabular-nums;
}
.share-password-wrap input:focus,
.share-limit-input:focus,
.share-link-input:focus {
  border-color: var(--accent-primary);
  box-shadow: 0 0 0 3px color-mix(in srgb, var(--accent-primary) 16%, transparent);
}

.share-created-card {
  display: grid;
  gap: 12px;
  padding: 14px;
  border-radius: 14px;
  border: 1px solid color-mix(in srgb, var(--success) 30%, var(--fluid-card-border));
  background: color-mix(in srgb, var(--success) 5%, var(--fluid-card-item-fill));
}
.share-created-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 8px;
}
.share-created-badge {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  font-size: 13px;
  font-weight: 650;
  color: var(--success);
}
.share-created-tags {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 5px;
}
.share-created-tags span {
  font-size: 11px;
  font-weight: 580;
  padding: 2px 8px;
  border-radius: 999px;
  background: var(--fluid-card-top);
  border: 1px solid var(--fluid-card-border);
  color: var(--text-secondary);
}
.share-link-row {
  display: flex;
  align-items: center;
  gap: 8px;
}
.share-link-input {
  flex: 1;
  min-width: 0;
  padding: 7px 11px;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 12px;
}
.share-copy-status {
  margin: 0;
  font-size: 12px;
  font-weight: 600;
  color: var(--accent-primary);
}
.share-copy-hint {
  margin: 0;
  font-size: 11.5px;
  color: var(--text-secondary);
}
.share-modal-footer {
  display: flex;
  justify-content: flex-end;
  width: 100%;
}

@media (max-width: 520px) {
  .share-duration-chips {
    grid-template-columns: repeat(3, minmax(0, 1fr));
  }
  .share-link-row {
    flex-direction: column;
    align-items: stretch;
  }
}

@media (prefers-reduced-motion: reduce) {
  .share-duration-chip,
  .share-preset-chip,
  .share-password-wrap input,
  .share-limit-input,
  .share-link-input {
    transition: none;
  }
}
</style>
