<script setup lang="ts">
import { computed, ref } from "vue";
import { AlertTriangle, ChevronDown, ChevronRight, FileText, Folder, Pin, Star, X } from "lucide-vue-next";
import { pinDisplayLabel, type FilePin } from "./filePinsAndInsights.ts";

const STORAGE_KEY = "lightisle:file-pins-collapsed";

const props = defineProps<{
  pins: FilePin[];
  loading: boolean;
  error: string;
  currentPath: string;
  togglingPath: string;
  isCurrentPinned: boolean;
}>();

const emit = defineEmits<{
  open: [pin: FilePin];
  remove: [path: string];
  pinCurrent: [];
}>();

function readCollapsedInitial(): boolean {
  try {
    return typeof localStorage !== "undefined" && localStorage.getItem(STORAGE_KEY) === "1";
  } catch {
    return false;
  }
}

const collapsed = ref(readCollapsedInitial());

function toggleCollapsed() {
  collapsed.value = !collapsed.value;
  try {
    localStorage.setItem(STORAGE_KEY, collapsed.value ? "1" : "0");
  } catch {
    // Ignore storage quota / privacy mode errors.
  }
}

const canPinCurrentFolder = computed(() => Boolean(props.currentPath && props.currentPath !== "."));
const showBar = computed(() => props.pins.length > 0 || Boolean(props.error) || canPinCurrentFolder.value);
</script>

<template>
  <section v-if="showBar" class="pins-bar" aria-label="常用置顶快捷栏">
    <div class="pins-bar-head">
      <button
        type="button"
        class="pins-toggle-btn"
        :aria-expanded="!collapsed ? 'true' : 'false'"
        @click="toggleCollapsed"
      >
        <ChevronDown v-if="!collapsed" :size="14" />
        <ChevronRight v-else :size="14" />
        <Pin :size="13" class="pins-head-icon" />
        <span>常用置顶</span>
        <span class="pins-count">{{ pins.length }}</span>
      </button>

      <div class="pins-bar-actions">
        <button
          v-if="canPinCurrentFolder"
          type="button"
          class="pins-current-btn"
          :class="{ 'is-pinned': isCurrentPinned }"
          :disabled="togglingPath === currentPath"
          :title="isCurrentPinned ? '取消置顶当前目录' : '将当前目录置顶到常用'"
          @click="emit('pinCurrent')"
        >
          <Star :size="13" :fill="isCurrentPinned ? 'currentColor' : 'none'" />
          <span>{{ isCurrentPinned ? "已置顶当前目录" : "置顶当前目录" }}</span>
        </button>
      </div>
    </div>

    <p v-if="error" class="pins-error" role="alert">{{ error }}</p>

    <div v-if="!collapsed && pins.length" class="pins-pills" role="list">
      <div
        v-for="pin in pins"
        :key="pin.path"
        class="pin-capsule"
        :class="{ 'is-missing': !pin.exists, 'is-active': pin.kind === 'folder' && pin.path === currentPath }"
        role="listitem"
      >
        <button
          type="button"
          class="pin-capsule-main"
          :disabled="!pin.exists"
          :title="pin.exists ? `${pin.kind === 'folder' ? '打开目录' : '预览文件'}：${pin.path}` : `目标已移动或删除：${pin.path}`"
          @click="emit('open', pin)"
        >
          <AlertTriangle v-if="!pin.exists" :size="13" class="pin-icon-missing" />
          <Folder v-else-if="pin.kind === 'folder'" :size="13" class="pin-icon-folder" />
          <FileText v-else :size="13" class="pin-icon-file" />
          <span class="pin-label">{{ pinDisplayLabel(pin) }}</span>
          <span v-if="!pin.exists" class="pin-missing-tag">已失效</span>
        </button>
        <button
          type="button"
          class="pin-remove-btn"
          :disabled="togglingPath === pin.path"
          :aria-label="'移除置顶：' + pinDisplayLabel(pin)"
          title="移除置顶"
          @click.stop="emit('remove', pin.path)"
        >
          <X :size="12" />
        </button>
      </div>
    </div>
  </section>
</template>

<style scoped>
.pins-bar {
  display: grid;
  gap: 8px;
  padding: 8px 16px;
  border-bottom: 1px solid var(--fluid-divider);
  background: color-mix(in srgb, var(--fluid-card-item-top) 65%, transparent);
}
.pins-bar-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  flex-wrap: wrap;
}
.pins-toggle-btn {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  border: 0;
  background: transparent;
  padding: 2px 4px;
  margin: -2px -4px;
  border-radius: 7px;
  color: var(--text-secondary);
  font-size: 12px;
  font-weight: 650;
  cursor: pointer;
}
.pins-toggle-btn:hover {
  color: var(--text-primary);
  background: color-mix(in srgb, var(--text-primary) 5%, transparent);
}
.pins-head-icon {
  color: var(--accent-primary);
}
.pins-count {
  font-size: 11px;
  padding: 0 6px;
  border-radius: 999px;
  background: var(--fluid-card-top);
  border: 1px solid var(--fluid-card-border);
  color: var(--text-tertiary);
  font-variant-numeric: tabular-nums;
}
.pins-bar-actions {
  display: inline-flex;
  align-items: center;
  gap: 6px;
}
.pins-current-btn {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-top);
  color: var(--text-secondary);
  padding: 3px 9px;
  border-radius: 999px;
  font-size: 11.5px;
  font-weight: 600;
  cursor: pointer;
  transition: background-color 140ms ease, color 140ms ease, border-color 140ms ease;
}
.pins-current-btn:hover:not(:disabled) {
  color: var(--text-primary);
  border-color: var(--fluid-card-border-strong);
}
.pins-current-btn.is-pinned {
  color: var(--accent-primary);
  border-color: color-mix(in srgb, var(--accent-primary) 42%, var(--fluid-card-border));
  background: color-mix(in srgb, var(--accent-primary) 10%, var(--fluid-card-top));
}
.pins-error {
  margin: 0;
  font-size: 12px;
  color: var(--error);
}
.pins-pills {
  display: flex;
  align-items: center;
  gap: 6px;
  flex-wrap: wrap;
}
.pin-capsule {
  display: inline-flex;
  align-items: center;
  max-width: 240px;
  border-radius: 999px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-top);
  box-shadow: var(--fluid-item-card-shadow);
  overflow: hidden;
  transition: border-color 140ms ease, background-color 140ms ease;
}
.pin-capsule:hover {
  border-color: var(--fluid-card-border-strong);
}
.pin-capsule.is-active {
  border-color: color-mix(in srgb, var(--accent-primary) 45%, var(--fluid-card-border));
  background: color-mix(in srgb, var(--accent-primary) 9%, var(--fluid-card-top));
}
.pin-capsule.is-missing {
  border-color: color-mix(in srgb, var(--warning) 45%, var(--fluid-card-border));
  background: color-mix(in srgb, var(--warning) 8%, var(--fluid-card-top));
}
.pin-capsule-main {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  min-width: 0;
  border: 0;
  background: transparent;
  padding: 4px 6px 4px 10px;
  color: var(--text-primary);
  font-size: 12px;
  font-weight: 580;
  cursor: pointer;
}
.pin-capsule-main:disabled {
  cursor: not-allowed;
  opacity: 0.75;
}
.pin-icon-folder {
  color: var(--accent-primary);
  flex-shrink: 0;
}
.pin-icon-file {
  color: var(--text-secondary);
  flex-shrink: 0;
}
.pin-icon-missing {
  color: var(--warning);
  flex-shrink: 0;
}
.pin-label {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.pin-missing-tag {
  font-size: 10px;
  font-weight: 650;
  padding: 1px 5px;
  border-radius: 999px;
  background: color-mix(in srgb, var(--warning) 18%, transparent);
  color: var(--warning);
  flex-shrink: 0;
}
.pin-remove-btn {
  display: grid;
  place-items: center;
  width: 24px;
  height: 24px;
  border: 0;
  background: transparent;
  color: var(--text-tertiary);
  cursor: pointer;
  flex-shrink: 0;
}
.pin-remove-btn:hover:not(:disabled) {
  color: var(--text-primary);
  background: color-mix(in srgb, var(--text-primary) 7%, transparent);
}
@media (prefers-reduced-motion: reduce) {
  .pins-current-btn, .pin-capsule { transition: none; }
}
</style>
