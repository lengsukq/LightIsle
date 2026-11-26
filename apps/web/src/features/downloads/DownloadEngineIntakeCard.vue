<script setup lang="ts">
import { computed, onUnmounted, ref, watch } from "vue";
import {
  ArrowDownToLine, Check, Copy, Film, Folder, Globe, Link2, SlidersHorizontal, Terminal,
} from "lucide-vue-next";
import { TIMINGS_MS } from "../../constants/timings.ts";
import { copyTextToClipboard } from "../../utils/clipboard.ts";
import AppleSelect from "../../components/ui/AppleSelect.vue";
import IsleBadge from "../../components/ui/IsleBadge.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleCard from "../../components/ui/IsleCard.vue";
import IsleDisclosure from "../../components/ui/IsleDisclosure.vue";
import {
  DOWNLOAD_ENGINE_MODES,
  resolveEngineAvailability,
  YTDLP_FORMAT_OPTIONS,
  YTDLP_INSTALL_COMMAND,
  type DownloadEngine,
  type DownloadStatus,
  type VideoQualityFormat,
} from "./downloadCenterTransport.ts";

const props = defineProps<{
  status: DownloadStatus;
  selectedEngine: DownloadEngine;
  url: string;
  destination: string;
  maxGB: string;
  videoFormat: VideoQualityFormat;
  allowPlaylist: boolean;
  playlistMaxItems: number;
  advancedOpen: boolean;
  creating: boolean;
}>();

const emit = defineEmits<{
  "update:selectedEngine": [value: DownloadEngine];
  "update:url": [value: string];
  "update:destination": [value: string];
  "update:maxGB": [value: string];
  "update:videoFormat": [value: VideoQualityFormat];
  "update:allowPlaylist": [value: boolean];
  "update:playlistMaxItems": [value: number];
  "update:advancedOpen": [value: boolean];
  "open-folder-picker": [];
  submit: [];
}>();

const copiedInstallCmd = ref(false);
const playlistMaxDraft = ref(String(props.playlistMaxItems));
let copyTimer: number | undefined;

watch(
  () => props.playlistMaxItems,
  (next) => {
    if (playlistMaxDraft.value.trim() !== String(next)) {
      playlistMaxDraft.value = String(next);
    }
  },
);

function onPlaylistMaxInput(event: Event) {
  playlistMaxDraft.value = (event.target as HTMLInputElement).value;
}

function normalizePlaylistMaxItems() {
  const raw = playlistMaxDraft.value.trim();
  const parsed = raw ? Number.parseInt(raw, 10) : Number.NaN;
  const normalized = Number.isFinite(parsed) ? Math.max(1, Math.min(20, parsed)) : 10;
  playlistMaxDraft.value = String(normalized);
  if (normalized !== props.playlistMaxItems) {
    emit("update:playlistMaxItems", normalized);
  }
}

function handleSubmit() {
  if (props.selectedEngine === "ytdlp" && props.allowPlaylist) {
    normalizePlaylistMaxItems();
  }
  emit("submit");
}

const availability = computed(() => resolveEngineAvailability(props.status));

const currentModeMeta = computed(
  () => DOWNLOAD_ENGINE_MODES.find((m) => m.id === props.selectedEngine) ?? DOWNLOAD_ENGINE_MODES[0],
);

const currentEngineReady = computed(() => {
  if (props.selectedEngine === "ytdlp") return availability.value.ytdlp;
  if (props.selectedEngine === "webarchive") return availability.value.webarchive;
  return availability.value.aria2;
});

const selectedDestOption = computed(() => props.destination.trim() || ".");
const destinationSelectOptions = computed(() => {
  const current = selectedDestOption.value;
  const opts = [
    { value: ".", label: "保存至：共享根目录 (.)" },
    { value: "Downloads", label: "保存至：Downloads" },
  ];
  if (current !== "." && current !== "Downloads") {
    opts.push({ value: current, label: `保存至：${current}` });
  }
  opts.push({ value: "__browse__", label: "浏览共享目录…" });
  return opts;
});

const advancedSummary = computed(() => {
  const parts: string[] = [];
  if (props.maxGB.trim()) parts.push(`单文件上限 ${props.maxGB.trim()} GiB`);
  if (selectedDestOption.value !== "." && selectedDestOption.value !== "Downloads") {
    parts.push(`自定义目录：${selectedDestOption.value}`);
  }
  return parts.length ? parts.join(" · ") : "可配置单文件上限（GiB）与自定义相对路径";
});

function onDestinationSelect(val: string | number | boolean | null) {
  if (typeof val !== "string") return;
  if (val === "__browse__") {
    emit("open-folder-picker");
    return;
  }
  emit("update:destination", val);
}

function engineStatusText(id: DownloadEngine): string {
  if (id === "aria2") {
    return availability.value.aria2
      ? availability.value.aria2Version ? `v${availability.value.aria2Version}` : "已就绪"
      : "未安装";
  }
  if (id === "ytdlp") {
    return availability.value.ytdlp
      ? availability.value.ytdlpVersion ? `v${availability.value.ytdlpVersion}` : "已就绪"
      : "未安装";
  }
  return availability.value.webarchive ? "内置就绪" : "未就绪";
}

function isEngineReady(id: DownloadEngine): boolean {
  if (id === "aria2") return availability.value.aria2;
  if (id === "ytdlp") return availability.value.ytdlp;
  return availability.value.webarchive;
}

async function copyInstallCommand() {
  if (await copyTextToClipboard(YTDLP_INSTALL_COMMAND)) {
    copiedInstallCmd.value = true;
    if (copyTimer !== undefined) clearTimeout(copyTimer);
    copyTimer = window.setTimeout(() => { copiedInstallCmd.value = false; }, TIMINGS_MS.COPIED_FEEDBACK);
  }
}

onUnmounted(() => {
  if (copyTimer !== undefined) clearTimeout(copyTimer);
});
</script>

<template>
  <IsleCard aria-label="新建下载或归档任务" padding="md">
    <div class="dl-engine-tabs" role="tablist" aria-label="选择下载或归档模式">
      <button
        v-for="mode in DOWNLOAD_ENGINE_MODES"
        :key="mode.id"
        type="button"
        role="tab"
        class="dl-engine-tab"
        :class="{ 'is-active': selectedEngine === mode.id, 'is-missing': !isEngineReady(mode.id) }"
        :aria-selected="selectedEngine === mode.id"
        @click="emit('update:selectedEngine', mode.id)"
      >
        <ArrowDownToLine v-if="mode.id === 'aria2'" :size="14" aria-hidden="true" />
        <Film v-else-if="mode.id === 'ytdlp'" :size="14" aria-hidden="true" />
        <Globe v-else :size="14" aria-hidden="true" />
        <span class="dl-engine-tab-label">{{ mode.label }}</span>
        <IsleBadge :variant="isEngineReady(mode.id) ? 'online' : 'warning'" size="sm">
          {{ engineStatusText(mode.id) }}
        </IsleBadge>
      </button>
    </div>

    <div v-if="selectedEngine === 'ytdlp' && !availability.ytdlp" class="dl-install-guide" role="note">
      <div class="dl-install-copy">
        <strong>宿主 Mac 尚未安装 yt-dlp</strong>
        <p>
          在 Mac 终端运行下方命令安装后，点击右上角「刷新队列」即可免重启启用视频归档；网页离线保存与常规下载不受影响。
        </p>
      </div>
      <div class="dl-install-cmd-row">
        <code class="dl-install-cmd"><Terminal :size="13" aria-hidden="true" /> {{ YTDLP_INSTALL_COMMAND }}</code>
        <IsleButton variant="tonal" size="sm" @click="copyInstallCommand">
          <template #icon><Check v-if="copiedInstallCmd" :size="13" /><Copy v-else :size="13" /></template>
          {{ copiedInstallCmd ? "已复制命令" : "复制安装命令" }}
        </IsleButton>
      </div>
    </div>

    <IsleBanner
      v-else-if="availability.anyAvailable && selectedEngine === 'aria2' && !availability.aria2"
      type="warning"
      compact
      role="note"
      message="常规/磁力下载依赖宿主 Mac 上的 aria2 组件，请先在 Mac 端「设置 → 工具 → 外部依赖」安装；你仍可切换到「网页离线保存」或「视频归档」。"
    />

    <IsleBanner
      v-else-if="availability.anyAvailable && selectedEngine === 'webarchive' && !availability.webarchive"
      type="warning"
      compact
      role="note"
      message="当前宿主服务版本暂未开启网页离线保存，请升级或重启轻屿 Mac 服务后重试。"
    />

    <form class="download-intake-form" @submit.prevent="handleSubmit">
      <div class="download-quick-bar">
        <label class="download-url-box">
          <Link2 :size="15" class="download-url-icon" aria-hidden="true" />
          <input
            :value="url"
            type="text"
            :placeholder="currentModeMeta.placeholder"
            aria-label="任务链接"
            required
            @input="emit('update:url', ($event.target as HTMLInputElement).value)"
          />
        </label>
        <div class="download-dest-select">
          <AppleSelect
            :model-value="selectedDestOption"
            :options="destinationSelectOptions"
            size="md"
            block
            aria-label="保存位置"
            @update:model-value="onDestinationSelect"
          />
        </div>
        <IsleButton
          type="submit"
          variant="primary"
          size="md"
          :loading="creating"
          :disabled="!currentEngineReady"
        >
          <template #icon><ArrowDownToLine :size="15" aria-hidden="true" /></template>
          {{ creating ? "正在创建…" : currentModeMeta.submitLabel }}
        </IsleButton>
      </div>

      <div v-if="selectedEngine === 'ytdlp'" class="dl-ytdlp-options-row">
        <div class="dl-ytdlp-format">
          <span class="dl-inline-label">视频画质</span>
          <AppleSelect
            :model-value="videoFormat"
            :options="[...YTDLP_FORMAT_OPTIONS]"
            size="sm"
            aria-label="视频画质档位"
            @update:model-value="emit('update:videoFormat', $event as VideoQualityFormat)"
          />
        </div>
        <label class="dl-playlist-toggle">
          <input
            type="checkbox"
            :checked="allowPlaylist"
            @change="emit('update:allowPlaylist', ($event.target as HTMLInputElement).checked)"
          />
          <span>允许抓取播放列表</span>
        </label>
        <label v-if="allowPlaylist" class="dl-playlist-max">
          <span>上限（集，最多 20）</span>
          <input
            type="number"
            min="1"
            max="20"
            step="1"
            :value="playlistMaxDraft"
            @input="onPlaylistMaxInput"
            @blur="normalizePlaylistMaxItems"
          />
        </label>
      </div>

      <IsleDisclosure
        :model-value="advancedOpen"
        variant="inline"
        title="高级选项"
        :subtitle="advancedSummary"
        @update:model-value="emit('update:advancedOpen', $event)"
      >
        <template #icon><SlidersHorizontal :size="14" /></template>
        <template #meta>
          <IsleBadge v-if="maxGB.trim()" variant="accent" size="sm">上限 {{ maxGB.trim() }} GiB</IsleBadge>
        </template>
        <div class="download-advanced-grid">
          <label class="download-adv-field">
            <span>单文件上限（GiB，选填）</span>
            <input
              :value="maxGB"
              type="number"
              min="0.1"
              max="1024"
              step="0.1"
              placeholder="留空使用服务端上限"
              @input="emit('update:maxGB', ($event.target as HTMLInputElement).value)"
            />
          </label>
          <div class="download-adv-field">
            <span>自定义保存相对路径</span>
            <div class="download-adv-dest-row">
              <input
                :value="destination"
                type="text"
                aria-label="自定义保存位置"
                placeholder="例如 Downloads 或 .（根目录）"
                @input="emit('update:destination', ($event.target as HTMLInputElement).value)"
              />
              <IsleButton variant="glass" size="sm" @click="emit('open-folder-picker')">
                <template #icon><Folder :size="14" aria-hidden="true" /></template>浏览…
              </IsleButton>
            </div>
          </div>
        </div>
      </IsleDisclosure>
    </form>
  </IsleCard>
</template>

<style scoped>
.dl-engine-tabs { display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 12px; }
.dl-engine-tab {
  display: inline-flex; align-items: center; gap: 7px; padding: 7px 12px; border-radius: 11px;
  border: 1px solid var(--fluid-card-border); background: var(--fluid-card-item-fill);
  color: var(--text-secondary); font: inherit; font-size: 12.5px; font-weight: 600; cursor: pointer;
  transition: background-color 0.15s ease, border-color 0.15s ease, color 0.15s ease;
}
.dl-engine-tab:hover { background: var(--fluid-card-hover); color: var(--text-primary); }
.dl-engine-tab.is-active {
  background: color-mix(in srgb, var(--accent-primary) 11%, var(--fluid-card-top));
  border-color: color-mix(in srgb, var(--accent-primary) 42%, var(--fluid-card-border));
  color: var(--text-primary);
}
.dl-engine-tab-label { white-space: nowrap; }
.dl-install-guide {
  margin-bottom: 12px; padding: 11px 13px; border-radius: 12px;
  border: 1px solid color-mix(in srgb, var(--warning, #d9912b) 34%, var(--fluid-card-border));
  background: color-mix(in srgb, var(--warning, #d9912b) 8%, var(--fluid-card-item-top));
  display: flex; flex-direction: column; gap: 8px;
}
.dl-install-copy strong { font-size: 13px; color: var(--text-primary); }
.dl-install-copy p { margin: 3px 0 0; font-size: 12px; color: var(--text-secondary); line-height: 1.45; }
.dl-install-cmd-row { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.dl-install-cmd {
  display: inline-flex; align-items: center; gap: 6px; padding: 5px 10px; border-radius: 8px;
  background: var(--surface-elevated); border: 1px solid var(--fluid-card-border);
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; color: var(--text-primary);
}
.download-intake-form { display: flex; flex-direction: column; gap: 8px; }
.download-quick-bar { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.download-url-box {
  flex: 1 1 280px; min-width: 0; display: flex; align-items: center; gap: 8px; min-height: 38px; padding: 0 12px;
  border-radius: 10px; border: 1px solid var(--fluid-card-border); background: var(--fluid-card-item-fill);
}
.download-url-box:focus-within {
  background: var(--fluid-card-top); border-color: var(--accent-primary);
  box-shadow: 0 0 0 3px color-mix(in srgb, var(--accent-primary) 16%, transparent);
}
.download-url-icon { color: var(--text-tertiary); flex-shrink: 0; }
.download-url-box input {
  flex: 1; min-width: 0; border: 0; outline: 0; background: transparent;
  color: var(--text-primary); font: inherit; font-size: 13px; padding: 7px 0;
}
.download-dest-select { flex: 0 1 220px; min-width: 175px; }
.dl-ytdlp-options-row {
  display: flex; align-items: center; gap: 14px; flex-wrap: wrap; padding: 8px 10px;
  border-radius: 10px; background: var(--fluid-card-item-fill); border: 1px solid var(--fluid-card-border);
}
.dl-ytdlp-format { display: inline-flex; align-items: center; gap: 8px; }
.dl-inline-label { font-size: 12px; font-weight: 600; color: var(--text-secondary); white-space: nowrap; }
.dl-playlist-toggle { display: inline-flex; align-items: center; gap: 6px; font-size: 12.5px; color: var(--text-primary); cursor: pointer; }
.dl-playlist-max { display: inline-flex; align-items: center; gap: 6px; font-size: 12px; color: var(--text-secondary); }
.dl-playlist-max input {
  width: 64px; height: 28px; padding: 2px 8px; border-radius: 7px;
  border: 1px solid var(--fluid-card-border); background: var(--fluid-card-top); color: var(--text-primary); font: inherit;
}
.download-advanced-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 12px; }
.download-adv-field { display: flex; flex-direction: column; gap: 5px; min-width: 0; }
.download-adv-field > span { font-size: 12px; font-weight: 600; color: var(--text-secondary); }
.download-adv-field input {
  width: 100%; min-height: 34px; padding: 6px 10px; border-radius: 9px;
  border: 1px solid var(--fluid-card-border); background: var(--fluid-card-item-fill);
  color: var(--text-primary); font: inherit; font-size: 12.5px;
}
.download-adv-dest-row { display: flex; align-items: center; gap: 8px; }
.download-adv-dest-row input { flex: 1; min-width: 0; }
@media (max-width: 720px) {
  .download-dest-select { flex: 1 1 180px; }
}
@media (prefers-reduced-motion: reduce) {
  .dl-engine-tab { transition: none; }
}
</style>
