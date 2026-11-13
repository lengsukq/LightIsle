<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from "vue";
import {
  AudioLines, Check, ChevronDown, ChevronUp, EyeOff, GripHorizontal, ListVideo,
  Maximize2, Minimize2, Pause, PictureInPicture2, Play, RotateCcw, RotateCw,
  Scan, SkipBack, SkipForward, Subtitles, Volume2, VolumeX, X,
} from "lucide-vue-next";
import { formatCinemaClock } from "./cinemaCatalogDisplay.ts";
import { useCinemaDockDrag } from "./useCinemaDockDrag.ts";
import { duration } from "./useCinemaMetadata.ts";
import type { Movie, TranscodeSession } from "./cinemaTypes.ts";

interface SelectChoice {
  value: string | number;
  label: string;
}

const props = defineProps<{
  selected: Movie;
  canDirect: boolean;
  streamUrl: string;
  trackUrl: string;
  caption: string;
  captionSrclang: string;
  captionOptions: SelectChoice[];
  audioTrackOptions: SelectChoice[];
  qualityOptions: SelectChoice[];
  currentQuality: string;
  playbackRate: number;
  playbackRateOptions: SelectChoice[];
  hlsSession: TranscodeSession | null;
  hlsStarting: boolean;
  playError: string;
  isPlaying: boolean;
  volume: number;
  isMuted: boolean;
  fillScreen: boolean;
  isFullscreen: boolean;
  canPictureInPicture: boolean;
  playbackPosition: number;
  playbackDuration: number;
  playbackBuffered?: number;
  seekPreview: number | null;
  autoplayNext: boolean;
  preferLocalDecode: boolean;
  leavingPlayer: boolean;
  showPlayerPlaylist: boolean;
  sameDirectoryFilms: Movie[];
  currentPlaylistIndex: number;
  hasPrevPlaylist: boolean;
  hasNextPlaylist: boolean;
  playlistDirLabel: string;
  directoryLoading: boolean;
  directoryError: string;
  directoryNextCursor: number;
  controlsHidden: boolean;
  setDirectVideoRef: (el: HTMLVideoElement | null) => void;
  setHlsVideoRef: (el: HTMLVideoElement | null) => void;
}>();

const emit = defineEmits<{
  (e: "update:controlsHidden", hidden: boolean): void;
  (e: "update:seekPreview", val: number | null): void;
  (e: "update:showPlayerPlaylist", open: boolean): void;
  (e: "loadedmetadata"): void;
  (e: "timeupdate"): void;
  (e: "buffer-progress"): void;
  (e: "media-state"): void;
  (e: "pause-save"): void;
  (e: "ended"): void;
  (e: "direct-error"): void;
  (e: "hls-error"): void;
  (e: "caption-load"): void;
  (e: "toggle-play"): void;
  (e: "jump", deltaSeconds: number): void;
  (e: "seek", positionSeconds: number): void;
  (e: "set-volume", volume: number): void;
  (e: "toggle-mute"): void;
  (e: "select-caption", value: string): void;
  (e: "select-audio", index: number): void;
  (e: "select-quality", quality: string): void;
  (e: "select-rate", rate: number): void;
  (e: "toggle-autoplay", checked: boolean): void;
  (e: "toggle-local-decode", checked: boolean): void;
  (e: "toggle-fill"): void;
  (e: "toggle-pip"): void;
  (e: "toggle-fullscreen"): void;
  (e: "start-transcode"): void;
  (e: "download"): void;
  (e: "switch-playlist-film", film: Movie): void;
  (e: "prev-playlist"): void;
  (e: "next-playlist"): void;
  (e: "reload-playlist", append: boolean): void;
}>();

type MenuKind = "caption" | "audio" | "quality" | "rate" | null;
const openMenu = ref<MenuKind>(null);
const scrubbing = ref(false);
const localScrub = ref<number | null>(null);
const hoverTime = ref<number | null>(null);
const hoverPct = ref(0);
const stageShellRef = ref<HTMLElement | null>(null);
const dockElRef = ref<HTMLElement | null>(null);
const {
  dockOffset,
  draggingDock,
  dockHovered,
  manuallyCollapsed,
  isDockMoved,
  isDockNearBottom,
  resetDockPosition,
  startDockDrag,
} = useCinemaDockDrag();
let hideTimer: number | undefined;
let singleClickTimer: number | undefined;
let lastMoveRevealAt = 0;

function clearSingleClickTimer() {
  if (singleClickTimer !== undefined) {
    window.clearTimeout(singleClickTimer);
    singleClickTimer = undefined;
  }
}

const effectiveDuration = computed(() =>
  Math.max(
    props.playbackDuration || 0,
    props.selected.durationSeconds || 0,
    props.selected.duration || 0,
  ),
);

const displayPosition = computed(() => {
  const raw = localScrub.value ?? props.seekPreview ?? props.playbackPosition;
  if (effectiveDuration.value > 0) return Math.max(0, Math.min(effectiveDuration.value, raw));
  return Math.max(0, raw);
});

const seekPercent = computed(() => {
  if (effectiveDuration.value <= 0) return 0;
  return Math.max(0, Math.min(100, (displayPosition.value / effectiveDuration.value) * 100));
});

const bufferedPercent = computed(() => {
  if (effectiveDuration.value <= 0) return 0;
  const raw = Math.max(props.playbackBuffered || 0, displayPosition.value);
  return Math.max(seekPercent.value, Math.min(100, (raw / effectiveDuration.value) * 100));
});

const previewBubbleTime = computed(() => (localScrub.value !== null ? localScrub.value : hoverTime.value));
const previewBubblePct = computed(() => (localScrub.value !== null ? seekPercent.value : hoverPct.value));

const volumePercent = computed(() => Math.round((props.isMuted ? 0 : props.volume) * 100));

const captionPillLabel = computed(() => {
  if (props.caption === "off") return "字幕";
  return props.captionOptions.find((o) => String(o.value) === props.caption)?.label ?? "字幕";
});

const qualityPillLabel = computed(() => {
  return props.qualityOptions.find((o) => String(o.value) === props.currentQuality)?.label ?? "原画";
});

const audioPillLabel = computed(() => {
  const active = props.hlsSession?.audioTrack ?? 0;
  return props.audioTrackOptions.find((o) => Number(o.value) === active)?.label ?? "音轨";
});

const ratePillLabel = computed(() => (props.playbackRate === 1 ? "1.0x" : `${props.playbackRate}x`));

function clearHideTimer() {
  if (hideTimer !== undefined) {
    window.clearTimeout(hideTimer);
    hideTimer = undefined;
  }
}

function scheduleAutoHide(delayMs = 2200) {
  clearHideTimer();
  if (
    props. isPlaying &&
    !props.hlsStarting &&
    !props.playError &&
    !props.showPlayerPlaylist &&
    openMenu.value === null &&
    !scrubbing.value &&
    !draggingDock.value &&
    !dockHovered.value
  ) {
    hideTimer = window.setTimeout(() => {
      if (
        props.isPlaying &&
        !props.showPlayerPlaylist &&
        openMenu.value === null &&
        !scrubbing.value &&
        !draggingDock.value &&
        !dockHovered.value &&
        !props.playError
      ) {
        emit("update:controlsHidden", true);
      }
    }, delayMs);
  }
}

function revealChrome(forceUncollapse = false) {
  if (forceUncollapse) manuallyCollapsed.value = false;
  if (manuallyCollapsed.value) return;
  if (props.controlsHidden) emit("update:controlsHidden", false);
  scheduleAutoHide(2200);
}

function collapseDockForSubtitles() {
  openMenu.value = null;
  manuallyCollapsed.value = true;
  clearHideTimer();
  emit("update:controlsHidden", true);
}

function restoreCollapsedDock() {
  manuallyCollapsed.value = false;
  emit("update:controlsHidden", false);
  scheduleAutoHide(2600);
}

function onDockPointerDown(event: PointerEvent) {
  if (startDockDrag(event, stageShellRef.value, dockElRef.value)) {
    openMenu.value = null;
    clearHideTimer();
  }
}

function onStageMouseLeave() {
  if (props.isPlaying && !manuallyCollapsed.value) {
    scheduleAutoHide(500);
  }
}

watch(
  () => props.selected.id,
  () => {
    scrubbing.value = false;
    localScrub.value = null;
    hoverTime.value = null;
    manuallyCollapsed.value = false;
  },
);

watch(
  () => [props.isPlaying, props.showPlayerPlaylist, openMenu.value, props.hlsStarting, props.playError],
  () => {
    if (props.showPlayerPlaylist || props.playError) manuallyCollapsed.value = false;
    revealChrome();
  },
);

function onStageMouseMove() {
  if (manuallyCollapsed.value && !props.isPlaying) return;
  if (manuallyCollapsed.value && props.isPlaying) {
    manuallyCollapsed.value = false;
  }
  const now = performance.now();
  if (!props.controlsHidden && now - lastMoveRevealAt < 250) return;
  lastMoveRevealAt = now;
  revealChrome();
}

function toggleMenu(kind: Exclude<MenuKind, null>) {
  openMenu.value = openMenu.value === kind ? null : kind;
  revealChrome(true);
}

function closeMenus() {
  if (openMenu.value !== null) openMenu.value = null;
}

function handleStageClick(event: MouseEvent) {
  if (openMenu.value !== null) {
    openMenu.value = null;
    revealChrome();
    return;
  }
  if ((event.target as HTMLElement | null)?.closest(".cinema-stage-card, .cinema-player-dock, .cinema-dock-restore-pill, .cinema-player-inspector-backdrop")) {
    return;
  }
  if (manuallyCollapsed.value) {
    restoreCollapsedDock();
    return;
  }
  revealChrome();
  if (event.detail > 1) {
    clearSingleClickTimer();
    return;
  }
  if (props.canDirect || props.hlsSession) {
    clearSingleClickTimer();
    singleClickTimer = window.setTimeout(() => {
      singleClickTimer = undefined;
      emit("toggle-play");
    }, 200);
  }
}

function handleStageDblClick(event: MouseEvent) {
  clearSingleClickTimer();
  if ((event.target as HTMLElement | null)?.closest(".cinema-stage-card, .cinema-player-dock, .cinema-player-inspector-backdrop")) {
    return;
  }
  revealChrome();
  emit("toggle-fullscreen");
}

function onSeekInput(event: Event) {
  const val = Number((event.target as HTMLInputElement).value);
  scrubbing.value = true;
  localScrub.value = val;
  if (effectiveDuration.value > 0) {
    hoverPct.value = Math.max(0, Math.min(100, (val / effectiveDuration.value) * 100));
  }
  revealChrome();
}

function onSeekCommit(event: Event) {
  const val = Number((event.target as HTMLInputElement).value);
  scrubbing.value = false;
  localScrub.value = null;
  revealChrome();
  emit("seek", val);
}

function onSeekHover(event: MouseEvent) {
  if (effectiveDuration.value <= 0) return;
  const rect = (event.currentTarget as HTMLElement).getBoundingClientRect();
  if (rect.width <= 0) return;
  const ratio = Math.max(0, Math.min(1, (event.clientX - rect.left) / rect.width));
  hoverPct.value = ratio * 100;
  hoverTime.value = ratio * effectiveDuration.value;
}

function onSeekLeave() {
  hoverTime.value = null;
}

function handleGlobalPointerDown(event: PointerEvent) {
  if (openMenu.value === null) return;
  const target = event.target as HTMLElement | null;
  if (!target?.closest(".cinema-menu-anchor")) {
    openMenu.value = null;
  }
}

function handleFullscreenChange() {
  emit("media-state");
  revealChrome();
}

onMounted(() => {
  window.addEventListener("pointerdown", handleGlobalPointerDown, true);
  document.addEventListener("fullscreenchange", handleFullscreenChange);
  revealChrome();
});

onUnmounted(() => {
  clearHideTimer();
  clearSingleClickTimer();
  window.removeEventListener("pointerdown", handleGlobalPointerDown, true);
  document.removeEventListener("fullscreenchange", handleFullscreenChange);
});
</script>

<template>
  <div
    ref="stageShellRef"
    class="cinema-stage-shell"
    :class="{
      'cinema-cursor-hidden': controlsHidden && isPlaying,
      'cinema-dock-hidden': controlsHidden || manuallyCollapsed,
      'cinema-dock-lifted-cues': !controlsHidden && !manuallyCollapsed && isDockNearBottom,
    }"
    @mousemove="onStageMouseMove"
    @mouseleave="onStageMouseLeave"
    @pointerdown="() => { if (!manuallyCollapsed) revealChrome(); }"
  >
    <div class="cinema-player-stage" @click="handleStageClick" @dblclick.prevent="handleStageDblClick">
      <video
        v-if="canDirect && !hlsSession && !hlsStarting"
        :ref="(el) => setDirectVideoRef(el as HTMLVideoElement | null)"
        :src="streamUrl"
        :class="{ 'cinema-video-cover': fillScreen }"
        playsinline
        preload="metadata"
        @loadedmetadata="emit('loadedmetadata')"
        @durationchange="emit('timeupdate')"
        @progress="emit('buffer-progress')"
        @timeupdate="emit('timeupdate')"
        @play="emit('media-state')"
        @playing="emit('media-state')"
        @pause="emit('media-state'); emit('pause-save')"
        @volumechange="emit('media-state')"
        @ended="emit('media-state'); emit('ended')"
        @error="emit('direct-error')"
      >
        <track v-if="caption !== 'off'" :key="caption" kind="subtitles" :src="trackUrl" :srclang="captionSrclang" label="字幕" default @load="emit('caption-load')" />
      </video>

      <video
        v-if="hlsSession || hlsStarting"
        :ref="(el) => setHlsVideoRef(el as HTMLVideoElement | null)"
        :class="{ 'cinema-video-cover': fillScreen }"
        playsinline
        preload="auto"
        @loadedmetadata="emit('loadedmetadata')"
        @durationchange="emit('timeupdate')"
        @progress="emit('buffer-progress')"
        @timeupdate="emit('timeupdate')"
        @play="emit('media-state')"
        @playing="emit('media-state')"
        @pause="emit('media-state'); emit('pause-save')"
        @volumechange="emit('media-state')"
        @ended="emit('media-state'); emit('ended')"
        @error="emit('hls-error')"
      >
        <track v-if="caption !== 'off'" :key="caption" kind="subtitles" :src="trackUrl" :srclang="captionSrclang" label="字幕" default @load="emit('caption-load')" />
      </video>

      <button
        v-if="!isPlaying && !hlsStarting && (canDirect || hlsSession) && !showPlayerPlaylist && !manuallyCollapsed"
        type="button"
        class="cinema-center-play"
        aria-label="播放影片"
        @click.stop="emit('toggle-play')"
      >
        <Play :size="30" fill="currentColor" />
      </button>

      <div v-if="hlsStarting" class="cinema-stage-card cinema-stage-card--loading" role="status">
        <span class="cinema-stage-spinner" aria-hidden="true"></span>
        <span>{{ hlsSession ? "正在跳转并缓冲片段…" : "正在启动实时转码，请稍候…" }}</span>
      </div>

      <div
        v-else-if="!canDirect && !hlsSession && selected.probeStatus !== 'pending'"
        class="cinema-stage-card cinema-stage-card--fallback"
      >
        <p>{{ playError || "当前封装或编码无法在浏览器直接硬解，可开启实时转码或下载原片播放。" }}</p>
        <div class="cinema-stage-card-actions">
          <button type="button" class="cinema-primary-pill" @click.stop="emit('start-transcode')">
            <Play :size="15" fill="currentColor" /> 在线转码播放（原片不变）
          </button>
          <button type="button" class="cinema-ghost-pill" @click.stop="emit('download')">下载原片文件</button>
        </div>
      </div>

      <div v-if="playError && (canDirect || hlsSession)" class="cinema-stage-toast" role="alert">
        <span>{{ playError }}</span>
        <button
          v-if="!hlsSession && !hlsStarting"
          type="button"
          class="cinema-toast-action"
          @click.stop="emit('start-transcode')"
        >
          切换转码播放
        </button>
      </div>

      <div
        v-if="showPlayerPlaylist"
        class="cinema-player-inspector-backdrop"
        @click.self="emit('update:showPlayerPlaylist', false)"
      >
        <section class="cinema-player-playlist" role="region" aria-label="同目录播放列表">
          <div class="cinema-inspector-header">
            <div>
              <strong>同目录播放列表</strong>
              <small class="cinema-playlist-sub">{{ playlistDirLabel }} · {{ sameDirectoryFilms.length }} 个视频</small>
            </div>
            <button type="button" title="关闭播放列表" @click="emit('update:showPlayerPlaylist', false)">
              <X :size="18" />
            </button>
          </div>
          <div v-if="directoryError" class="cinema-alert" role="alert">
            读取失败：{{ directoryError }}
            <button type="button" class="cinema-toast-action" @click="emit('reload-playlist', false)">重试加载</button>
          </div>
          <p v-if="directoryLoading" class="cinema-hint" role="status">正在读取当前目录…</p>
          <div class="cinema-playlist-list">
            <button
              v-for="(item, index) in sameDirectoryFilms"
              :key="item.id"
              type="button"
              class="cinema-playlist-item"
              :class="{ active: item.id === selected.id }"
              :disabled="leavingPlayer"
              @click="emit('switch-playlist-film', item)"
            >
              <span class="cinema-playlist-index">{{ index + 1 }}</span>
              <span class="cinema-playlist-main">
                <strong>{{ item.title }}</strong>
                <small>{{ item.path.split("/").pop() }} · {{ duration(item.durationSeconds || item.duration) }}</small>
              </span>
              <span v-if="item.id === selected.id" class="cinema-playlist-badge">正在播放</span>
            </button>
          </div>
          <div class="cinema-playlist-footer">
            <label class="cinema-hud-check">
              <input
                type="checkbox"
                :checked="autoplayNext"
                @change="emit('toggle-autoplay', ($event.target as HTMLInputElement).checked)"
              />
              <span>{{ selected.kind === "series" ? "播完自动下一集" : "播完自动连播" }}</span>
            </label>
            <button
              v-if="directoryNextCursor > 0"
              type="button"
              class="cinema-ghost-pill"
              :disabled="directoryLoading"
              @click="emit('reload-playlist', true)"
            >
              加载更多
            </button>
          </div>
        </section>
      </div>
    </div>

    <button
      v-if="manuallyCollapsed && (canDirect || hlsSession || hlsStarting)"
      type="button"
      class="cinema-dock-restore-pill"
      title="展开播放控制栏"
      aria-label="展开播放控制栏"
      @click.stop="restoreCollapsedDock"
    >
      <ChevronUp :size="15" />
      <span>控制栏</span>
    </button>

    <footer
      v-if="canDirect || hlsSession || hlsStarting"
      ref="dockElRef"
      class="cinema-player-dock"
      :class="{ 'cinema-player-dock--dragging': draggingDock, 'cinema-player-dock--moved': isDockMoved }"
      :style="{ '--dock-x': `${dockOffset.x}px`, '--dock-y': `${dockOffset.y}px` }"
      @click.stop
      @pointerdown="onDockPointerDown"
      @mouseenter="dockHovered = true; clearHideTimer()"
      @mouseleave="dockHovered = false; scheduleAutoHide(1800)"
    >
      <div
        class="cinema-dock-grip-row"
        title="按住空白处或横条可自由拖动位置，双击复位底部居中"
        @dblclick.stop="resetDockPosition"
      >
        <span class="cinema-dock-grip-bar" aria-hidden="true"><GripHorizontal :size="14" /></span>
        <button
          v-if="isDockMoved"
          type="button"
          class="cinema-dock-reset-btn"
          title="复位到底部居中"
          @click.stop="resetDockPosition"
        >
          复位位置
        </button>
      </div>
      <div class="cinema-unified-seek" @mousemove="onSeekHover" @mouseleave="onSeekLeave">
        <span
          v-if="previewBubbleTime !== null && effectiveDuration > 0"
          class="cinema-seek-tooltip"
          :style="{ '--preview-pct': `${previewBubblePct}%` }"
          aria-hidden="true"
        >{{ formatCinemaClock(previewBubbleTime) }}</span>
        <input
          type="range"
          class="cinema-seek-slider"
          min="0"
          :max="effectiveDuration > 0 ? effectiveDuration : 1"
          step="0.1"
          :value="displayPosition"
          :disabled="effectiveDuration <= 0"
          :style="{ '--seek-pct': `${seekPercent}%`, '--buf-pct': `${bufferedPercent}%` }"
          aria-label="播放进度"
          @input="onSeekInput"
          @change="onSeekCommit"
        />
      </div>

      <div class="cinema-player-dock-row">
        <div class="cinema-player-dock-left">
          <button type="button" class="cinema-icon-btn" :title="isPlaying ? '暂停（空格）' : '播放（空格）'" :aria-label="isPlaying ? '暂停' : '播放'" :disabled="hlsStarting" @click="emit('toggle-play')">
            <Pause v-if="isPlaying" :size="20" fill="currentColor" />
            <Play v-else :size="20" fill="currentColor" />
          </button>

          <template v-if="sameDirectoryFilms.length > 1">
            <button type="button" class="cinema-icon-btn" title="上一部" aria-label="上一部" :disabled="hlsStarting || leavingPlayer || !hasPrevPlaylist" @click="emit('prev-playlist')"><SkipBack :size="18" /></button>
            <button type="button" class="cinema-icon-btn" title="下一部" aria-label="下一部" :disabled="hlsStarting || leavingPlayer || !hasNextPlaylist" @click="emit('next-playlist')"><SkipForward :size="18" /></button>
          </template>

          <button type="button" class="cinema-icon-btn" title="快退 10 秒（左方向键）" aria-label="快退 10 秒" :disabled="effectiveDuration <= 0" @click="emit('jump', -10)"><RotateCcw :size="17" /></button>
          <button type="button" class="cinema-icon-btn" title="快进 10 秒（右方向键）" aria-label="快进 10 秒" :disabled="effectiveDuration <= 0" @click="emit('jump', 10)"><RotateCw :size="17" /></button>

          <div class="cinema-volume-cluster">
            <button type="button" class="cinema-icon-btn" :title="isMuted || volume === 0 ? '取消静音' : '静音'" :aria-label="isMuted || volume === 0 ? '取消静音' : '静音'" @click="emit('toggle-mute')">
              <VolumeX v-if="isMuted || volume === 0" :size="17" />
              <Volume2 v-else :size="17" />
            </button>
            <input type="range" class="cinema-volume-slider" min="0" max="1" step="0.02" :value="isMuted ? 0 : volume" :style="{ '--vol-pct': `${volumePercent}%` }" aria-label="音量" @input="emit('set-volume', Number(($event.target as HTMLInputElement).value))" />
          </div>

          <span class="cinema-time-readout">
            <span class="cinema-time-current">{{ formatCinemaClock(displayPosition) }}</span>
            <span class="cinema-time-sep">/</span>
            <span class="cinema-time-total">{{ formatCinemaClock(effectiveDuration) }}</span>
          </span>
        </div>

        <div class="cinema-player-dock-right">
          <button type="button" class="cinema-pill-btn" :class="{ active: showPlayerPlaylist }" title="同目录播放列表" @click="closeMenus(); emit('update:showPlayerPlaylist', !showPlayerPlaylist)">
            <ListVideo :size="15" />
            <span>{{ sameDirectoryFilms.length > 1 ? `播放列表 ${Math.max(1, currentPlaylistIndex + 1)}/${sameDirectoryFilms.length}` : "播放列表" }}</span>
          </button>

          <div class="cinema-menu-anchor">
            <button type="button" class="cinema-pill-btn" :class="{ active: caption !== 'off' || openMenu === 'caption' }" title="字幕选择" :aria-expanded="openMenu === 'caption'" @click="toggleMenu('caption')">
              <Subtitles :size="14" />
              <span>{{ captionPillLabel }}</span>
              <ChevronDown :size="13" class="cinema-pill-chevron" />
            </button>
            <div v-if="openMenu === 'caption'" class="cinema-popover-menu" role="menu">
              <button v-for="opt in captionOptions" :key="String(opt.value)" type="button" class="cinema-popover-item" :class="{ selected: String(opt.value) === caption }" role="menuitemradio" :aria-checked="String(opt.value) === caption" @click="openMenu = null; emit('select-caption', String(opt.value))">
                <Check :size="14" class="cinema-popover-check" />
                <span>{{ opt.value === "off" ? "关闭字幕" : opt.label }}</span>
              </button>
            </div>
          </div>

          <div v-if="(hlsSession || hlsStarting) && audioTrackOptions.length > 1" class="cinema-menu-anchor">
            <button type="button" class="cinema-pill-btn" :class="{ active: openMenu === 'audio' }" title="音轨切换" :aria-expanded="openMenu === 'audio'" @click="toggleMenu('audio')">
              <AudioLines :size="14" />
              <span class="cinema-pill-truncate">{{ audioPillLabel }}</span>
              <ChevronDown :size="13" class="cinema-pill-chevron" />
            </button>
            <div v-if="openMenu === 'audio'" class="cinema-popover-menu" role="menu">
              <button v-for="opt in audioTrackOptions" :key="String(opt.value)" type="button" class="cinema-popover-item" :class="{ selected: Number(opt.value) === (hlsSession?.audioTrack ?? 0) }" role="menuitemradio" :aria-checked="Number(opt.value) === (hlsSession?.audioTrack ?? 0)" @click="openMenu = null; emit('select-audio', Number(opt.value))">
                <Check :size="14" class="cinema-popover-check" />
                <span>{{ opt.label }}</span>
              </button>
            </div>
          </div>

          <div class="cinema-menu-anchor">
            <button type="button" class="cinema-pill-btn" :class="{ active: openMenu === 'quality' }" title="清晰度与解码方式" :disabled="hlsStarting" :aria-expanded="openMenu === 'quality'" @click="toggleMenu('quality')">
              <span>{{ qualityPillLabel }}</span>
              <ChevronDown :size="13" class="cinema-pill-chevron" />
            </button>
            <div v-if="openMenu === 'quality'" class="cinema-popover-menu" role="menu">
              <button v-for="opt in qualityOptions" :key="String(opt.value)" type="button" class="cinema-popover-item" :class="{ selected: String(opt.value) === currentQuality }" role="menuitemradio" :aria-checked="String(opt.value) === currentQuality" @click="openMenu = null; emit('select-quality', String(opt.value))">
                <Check :size="14" class="cinema-popover-check" />
                <span>{{ opt.label }}</span>
              </button>
              <div class="cinema-popover-divider"></div>
              <button type="button" class="cinema-popover-item" :class="{ selected: preferLocalDecode }" role="menuitemcheckbox" :aria-checked="preferLocalDecode" @click="openMenu = null; emit('toggle-local-decode', !preferLocalDecode)">
                <Check :size="14" class="cinema-popover-check" />
                <span>默认优先本地硬解</span>
              </button>
              <button v-if="selected.path" type="button" class="cinema-popover-item" :class="{ selected: autoplayNext }" role="menuitemcheckbox" :aria-checked="autoplayNext" @click="openMenu = null; emit('toggle-autoplay', !autoplayNext)">
                <Check :size="14" class="cinema-popover-check" />
                <span>{{ selected.kind === "series" ? "播完自动下一集" : "播完自动连播" }}</span>
              </button>
            </div>
          </div>

          <div class="cinema-menu-anchor">
            <button type="button" class="cinema-pill-btn" :class="{ active: playbackRate !== 1 || openMenu === 'rate' }" title="播放倍速" :aria-expanded="openMenu === 'rate'" @click="toggleMenu('rate')">
              <span>{{ ratePillLabel }}</span>
              <ChevronDown :size="13" class="cinema-pill-chevron" />
            </button>
            <div v-if="openMenu === 'rate'" class="cinema-popover-menu cinema-popover-menu--narrow" role="menu">
              <button v-for="opt in playbackRateOptions" :key="String(opt.value)" type="button" class="cinema-popover-item" :class="{ selected: Number(opt.value) === playbackRate }" role="menuitemradio" :aria-checked="Number(opt.value) === playbackRate" @click="openMenu = null; emit('select-rate', Number(opt.value))">
                <Check :size="14" class="cinema-popover-check" />
                <span>{{ Number(opt.value) === 1 ? "1.0x（正常）" : opt.label }}</span>
              </button>
            </div>
          </div>

          <button type="button" class="cinema-icon-btn" :class="{ active: fillScreen }" :title="fillScreen ? '适应屏幕' : '铺满画面'" :aria-label="fillScreen ? '适应屏幕' : '铺满画面'" @click="emit('toggle-fill')"><Scan :size="17" /></button>
          <button v-if="canPictureInPicture" type="button" class="cinema-icon-btn" title="画中画" aria-label="画中画" @click="emit('toggle-pip')"><PictureInPicture2 :size="17" /></button>
          <button type="button" class="cinema-icon-btn" :title="isFullscreen ? '退出全屏' : '全屏播放'" :aria-label="isFullscreen ? '退出全屏' : '全屏播放'" @click="emit('toggle-fullscreen')">
            <Minimize2 v-if="isFullscreen" :size="17" />
            <Maximize2 v-else :size="17" />
          </button>
          <button type="button" class="cinema-icon-btn" title="收起控制栏（避免遮挡底部字幕）" aria-label="收起控制栏" @click="collapseDockForSubtitles"><EyeOff :size="16" /></button>
        </div>
      </div>
    </footer>
  </div>
</template>

<style scoped src="./CinemaPlayerStage.css"></style>
