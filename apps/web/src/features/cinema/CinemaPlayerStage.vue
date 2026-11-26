<script setup lang="ts">
import { computed, inject, nextTick, onMounted, onUnmounted, ref, watch, type Component } from "vue";
import {
  ChevronUp, EyeOff, FastForward, Gauge, GripHorizontal, ListVideo,
  Maximize2, Minimize2, Pause, PictureInPicture2, Play, Rewind,
  RotateCcw, RotateCw, Scan, SkipBack, SkipForward, Volume2, VolumeX,
} from "lucide-vue-next";
import CinemaPlayerMenus, { type CinemaMenuKind } from "./CinemaPlayerMenus.vue";
import CinemaPlayerPlaylistOverlay from "./CinemaPlayerPlaylistOverlay.vue";
import { formatCinemaClock } from "./cinemaCatalogDisplay.ts";
import { useCinemaDockDrag } from "./useCinemaDockDrag.ts";
import { TIMINGS_MS } from "../../constants/timings.ts";
import { CINEMA_PLAYER_CTX } from "../../contexts/cinemaContext.ts";

const ctx = inject(CINEMA_PLAYER_CTX);
if (!ctx) throw new Error("CinemaPlayerStage requires CINEMA_PLAYER_CTX");

const {
  selected, canDirect, streamUrl, trackUrl, caption, captionSrclang, captionOptions,
  audioTrackOptions, chapters, qualityOptions, currentQuality, playbackRate, isSpeedBoosting,
  osdMessage, playbackRateOptions, subtitleSize, subtitleOffset, localSubtitleName,
  localSubtitleError, hlsSession, hlsStarting, playError, isPlaying, volume, isMuted,
  fillScreen, isFullscreen, canPictureInPicture, playbackPosition, playbackDuration,
  playbackBuffered, autoplayNext, preferLocalDecode, leavingPlayer, showPlayerPlaylist,
  sameDirectoryFilms, currentPlaylistIndex, hasPrevPlaylist, hasNextPlaylist,
  playlistDirLabel, directoryLoading, directoryError, directoryNextCursor, controlsHidden,
  setDirectVideoRef, setHlsVideoRef, setControlsHidden, setMenuOpen, togglePlaylist,
  onLoadedMetadata, onTimeUpdate, onBufferProgress, onMediaState, onPauseSave, onEnded,
  onDirectError, onHlsError, onCaptionLoad, togglePlay, jump, seek, setVolume, toggleMute,
  selectCaption, selectLocalSubtitle, clearLocalSubtitle, setSubtitleSize,
  adjustSubtitleOffset, resetSubtitleOffset, selectAudio, selectQuality, selectRate,
  toggleAutoplay, toggleLocalDecode, toggleFill, togglePip, toggleFullscreen,
  startTranscode, download, switchPlaylistFilm, prevPlaylist, nextPlaylist, reloadPlaylist,
} = ctx;

const openMenu = ref<CinemaMenuKind>(null);
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
} = useCinemaDockDrag({ stageRef: stageShellRef, dockRef: dockElRef });
const dockInUpperHalf = ref(false);
const popoverShiftX = ref(0);
let hideTimer: number | undefined;
let singleClickTimer: number | undefined;
let lastMoveRevealAt = 0;
let closedMenuOnPointerDown = false;

function updateDockUpperHalf() {
  const stageEl = stageShellRef.value;
  const dockEl = dockElRef.value;
  if (!stageEl || !dockEl) {
    dockInUpperHalf.value = false;
    return;
  }
  const stageRect = stageEl.getBoundingClientRect();
  const dockRect = dockEl.getBoundingClientRect();
  if (stageRect.height <= 0) {
    dockInUpperHalf.value = false;
    return;
  }
  const dockCenterY = dockRect.top + dockRect.height / 2 - stageRect.top;
  dockInUpperHalf.value =
    dockOffset.value.y < -stageRect.height * 0.25 ||
    dockCenterY < stageRect.height * 0.45;
}

function clampOpenPopoverHorizontal() {
  popoverShiftX.value = 0;
  if (openMenu.value === null || typeof window === "undefined" || window.innerWidth <= 680) return;
  void nextTick(() => {
    const stageEl = stageShellRef.value;
    const dockEl = dockElRef.value;
    if (!stageEl || !dockEl) return;
    const menuEl = dockEl.querySelector<HTMLElement>(".cinema-popover-menu");
    if (!menuEl) return;
    const stageRect = stageEl.getBoundingClientRect();
    const menuRect = menuEl.getBoundingClientRect();
    const margin = 8;
    if (menuRect.left < stageRect.left + margin) {
      popoverShiftX.value = Math.round(stageRect.left + margin - menuRect.left);
    } else if (menuRect.right > stageRect.right - margin) {
      popoverShiftX.value = Math.round(stageRect.right - margin - menuRect.right);
    }
  });
}

function clearSingleClickTimer() {
  if (singleClickTimer !== undefined) {
    window.clearTimeout(singleClickTimer);
    singleClickTimer = undefined;
  }
}

const effectiveDuration = computed(() =>
  Math.max(
    playbackDuration.value || 0,
    selected.value?.durationSeconds || 0,
    selected.value?.duration || 0,
  ),
);

const displayPosition = computed(() => {
  const raw = localScrub.value ?? playbackPosition.value;
  if (effectiveDuration.value > 0) return Math.max(0, Math.min(effectiveDuration.value, raw));
  return Math.max(0, raw);
});

const seekPercent = computed(() => {
  if (effectiveDuration.value <= 0) return 0;
  return Math.max(0, Math.min(100, (displayPosition.value / effectiveDuration.value) * 100));
});

const bufferedPercent = computed(() => {
  if (effectiveDuration.value <= 0) return 0;
  const raw = Math.max(playbackBuffered.value || 0, displayPosition.value);
  return Math.max(seekPercent.value, Math.min(100, (raw / effectiveDuration.value) * 100));
});

const previewBubbleTime = computed(() => (localScrub.value !== null ? localScrub.value : hoverTime.value));
const previewBubblePct = computed(() => (localScrub.value !== null ? seekPercent.value : hoverPct.value));
const volumePercent = computed(() => Math.round((isMuted.value ? 0 : volume.value) * 100));

const captionPillLabel = computed(() => {
  if (caption.value === "off") return "字幕";
  if (caption.value === "local") return "本地字幕";
  return captionOptions.value.find((o) => String(o.value) === caption.value)?.label ?? "字幕";
});

const qualityPillLabel = computed(() => {
  return qualityOptions.value.find((o) => String(o.value) === currentQuality.value)?.label ?? "原画";
});

const audioPillLabel = computed(() => {
  const active = hlsSession.value?.audioTrack ?? 0;
  return audioTrackOptions.value.find((o) => Number(o.value) === active)?.label ?? "音轨";
});

const ratePillLabel = computed(() => (playbackRate.value === 1 ? "1.0x" : `${playbackRate.value}x`));

const osdDisplay = computed<{ icon: Component; label: string } | null>(() => {
  if (isSpeedBoosting.value) {
    return { icon: Gauge, label: "2.0x 倍速播放中（松开恢复）" };
  }
  const msg = osdMessage.value.trim();
  if (!msg) return null;
  if (msg.startsWith("+") || msg.includes("快进")) return { icon: FastForward, label: msg };
  if (msg.startsWith("-") || msg.includes("快退")) return { icon: Rewind, label: msg };
  if (msg.includes("静音")) return { icon: VolumeX, label: msg };
  if (msg.includes("音量")) return { icon: Volume2, label: msg };
  if (msg.includes("暂停")) return { icon: Pause, label: msg };
  return { icon: Play, label: msg };
});

const activeSkipChapter = computed(() => {
  const pos = displayPosition.value;
  return chapters.value.find(
    (ch) => (ch.kind === "intro" || ch.kind === "credits") && pos >= ch.startSeconds && pos < ch.endSeconds - 1,
  ) ?? null;
});

function clearHideTimer() {
  if (hideTimer !== undefined) {
    window.clearTimeout(hideTimer);
    hideTimer = undefined;
  }
}

function scheduleAutoHide(delayMs: number = TIMINGS_MS.PLAYER_HUD_HIDE) {
  clearHideTimer();
  if (
    isPlaying.value &&
    !hlsStarting.value &&
    !playError.value &&
    !showPlayerPlaylist.value &&
    openMenu.value === null &&
    !scrubbing.value &&
    !draggingDock.value &&
    !dockHovered.value
  ) {
    hideTimer = window.setTimeout(() => {
      if (
        isPlaying.value &&
        !showPlayerPlaylist.value &&
        openMenu.value === null &&
        !scrubbing.value &&
        !draggingDock.value &&
        !dockHovered.value &&
        !playError.value
      ) {
        setControlsHidden(true);
      }
    }, delayMs);
  }
}

function revealChrome(forceUncollapse = false) {
  if (forceUncollapse) manuallyCollapsed.value = false;
  if (manuallyCollapsed.value) return;
  if (controlsHidden.value) setControlsHidden(false);
  scheduleAutoHide();
}

function collapseDockForSubtitles() {
  openMenu.value = null;
  manuallyCollapsed.value = true;
  clearHideTimer();
  setControlsHidden(true);
}

function restoreCollapsedDock() {
  manuallyCollapsed.value = false;
  setControlsHidden(false);
  scheduleAutoHide();
}

function onDockPointerDown(event: PointerEvent) {
  if (startDockDrag(event, stageShellRef.value, dockElRef.value)) {
    openMenu.value = null;
    clearHideTimer();
  }
}

function onStageMouseLeave() {
  if (isPlaying.value && !manuallyCollapsed.value) {
    scheduleAutoHide(500);
  }
}

watch(
  () => selected.value?.id,
  () => {
    scrubbing.value = false;
    localScrub.value = null;
    hoverTime.value = null;
    manuallyCollapsed.value = false;
  },
);

watch(
  () => [isPlaying.value, showPlayerPlaylist.value, openMenu.value, hlsStarting.value, playError.value],
  () => {
    if (showPlayerPlaylist.value || playError.value) manuallyCollapsed.value = false;
    revealChrome();
  },
);

function onStageMouseMove() {
  if (manuallyCollapsed.value) return;
  const now = performance.now();
  if (!controlsHidden.value && now - lastMoveRevealAt < 250) return;
  lastMoveRevealAt = now;
  revealChrome();
}

function toggleMenu(kind: Exclude<CinemaMenuKind, null>) {
  openMenu.value = openMenu.value === kind ? null : kind;
  updateDockUpperHalf();
  revealChrome(true);
}

function closeMenus() {
  if (openMenu.value !== null) openMenu.value = null;
}

watch(openMenu, (val) => {
  setMenuOpen(val !== null);
});

watch(
  [openMenu, () => dockOffset.value.x, () => dockOffset.value.y],
  () => {
    updateDockUpperHalf();
    clampOpenPopoverHorizontal();
  },
);

defineExpose({ closeMenus });

function handleStageClick(event: MouseEvent) {
  if (closedMenuOnPointerDown || openMenu.value !== null) {
    closedMenuOnPointerDown = false;
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
  if (canDirect.value || hlsSession.value) {
    clearSingleClickTimer();
    singleClickTimer = window.setTimeout(() => {
      singleClickTimer = undefined;
      togglePlay();
    }, 200);
  }
}

function handleStageDblClick(event: MouseEvent) {
  closedMenuOnPointerDown = false;
  clearSingleClickTimer();
  if ((event.target as HTMLElement | null)?.closest(".cinema-stage-card, .cinema-player-dock, .cinema-player-inspector-backdrop")) {
    return;
  }
  revealChrome();
  toggleFullscreen();
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
  seek(val);
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
  if (openMenu.value === null) {
    closedMenuOnPointerDown = false;
    return;
  }
  const target = event.target as HTMLElement | null;
  if (!target?.closest(".cinema-menu-anchor")) {
    openMenu.value = null;
    closedMenuOnPointerDown = true;
  } else {
    closedMenuOnPointerDown = false;
  }
}

function handleFullscreenChange() {
  onMediaState();
  revealChrome();
  updateDockUpperHalf();
  clampOpenPopoverHorizontal();
}

function handleWindowResize() {
  updateDockUpperHalf();
  clampOpenPopoverHorizontal();
}

onMounted(() => {
  window.addEventListener("pointerdown", handleGlobalPointerDown, true);
  window.addEventListener("resize", handleWindowResize, { passive: true });
  document.addEventListener("fullscreenchange", handleFullscreenChange);
  revealChrome();
});

onUnmounted(() => {
  clearHideTimer();
  clearSingleClickTimer();
  window.removeEventListener("pointerdown", handleGlobalPointerDown, true);
  window.removeEventListener("resize", handleWindowResize);
  document.removeEventListener("fullscreenchange", handleFullscreenChange);
});
</script>

<template>
  <div
    v-if="selected"
    ref="stageShellRef"
    class="cinema-stage-shell"
    :class="[
      `cinema-sub-${subtitleSize}`,
      {
        'cinema-cursor-hidden': controlsHidden && isPlaying,
        'cinema-dock-hidden': controlsHidden || manuallyCollapsed,
        'cinema-dock-lifted-cues': !controlsHidden && !manuallyCollapsed && isDockNearBottom,
      },
    ]"
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
        @loadedmetadata="onLoadedMetadata()"
        @durationchange="onTimeUpdate()"
        @progress="onBufferProgress()"
        @timeupdate="onTimeUpdate()"
        @play="onMediaState()"
        @playing="onMediaState()"
        @pause="onMediaState(); onPauseSave()"
        @volumechange="onMediaState()"
        @ended="onMediaState(); onEnded()"
        @error="onDirectError()"
      >
        <track v-if="caption !== 'off'" :key="caption + ':' + trackUrl" kind="subtitles" :src="trackUrl" :srclang="captionSrclang" label="字幕" default @load="onCaptionLoad()" />
      </video>

      <video
        v-if="hlsSession || hlsStarting"
        :ref="(el) => setHlsVideoRef(el as HTMLVideoElement | null)"
        :class="{ 'cinema-video-cover': fillScreen }"
        playsinline
        preload="auto"
        @loadedmetadata="onLoadedMetadata()"
        @durationchange="onTimeUpdate()"
        @progress="onBufferProgress()"
        @timeupdate="onTimeUpdate()"
        @play="onMediaState()"
        @playing="onMediaState()"
        @pause="onMediaState(); onPauseSave()"
        @volumechange="onMediaState()"
        @ended="onMediaState(); onEnded()"
        @error="onHlsError()"
      >
        <track v-if="caption !== 'off'" :key="caption + ':' + trackUrl" kind="subtitles" :src="trackUrl" :srclang="captionSrclang" label="字幕" default @load="onCaptionLoad()" />
      </video>

      <Transition name="cinema-hud-top">
        <div v-if="osdDisplay" class="cinema-player-osd" role="status" aria-live="polite">
          <component :is="osdDisplay.icon" :size="15" class="cinema-osd-icon" aria-hidden="true" />
          <span>{{ osdDisplay.label }}</span>
        </div>
      </Transition>

      <Transition name="isle-pop">
        <button
          v-if="activeSkipChapter && (canDirect || hlsSession)"
          type="button"
          class="cinema-skip-intro-btn"
          @click.stop="seek(activeSkipChapter.endSeconds)"
        >
          <SkipForward :size="15" />
          <span>{{ activeSkipChapter.kind === 'credits' ? '跳过片尾' : '跳过片头' }}</span>
        </button>
      </Transition>

      <Transition name="cinema-cue-pop">
        <button
          v-if="!isPlaying && !hlsStarting && (canDirect || hlsSession) && !showPlayerPlaylist && !manuallyCollapsed"
          type="button"
          class="cinema-center-play"
          aria-label="播放影片"
          @click.stop="togglePlay()"
        >
          <Play :size="30" fill="currentColor" />
        </button>
      </Transition>

      <Transition name="isle-pop">
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
            <button type="button" class="cinema-primary-pill" @click.stop="startTranscode()">
              <Play :size="15" fill="currentColor" /> 在线转码播放（原片不变）
            </button>
            <button type="button" class="cinema-ghost-pill" @click.stop="download()">下载原片文件</button>
          </div>
        </div>
      </Transition>

      <Transition name="isle-hud-float">
        <div v-if="playError && (canDirect || hlsSession)" class="cinema-stage-toast" role="alert">
          <span>{{ playError }}</span>
          <button
            v-if="!hlsSession && !hlsStarting"
            type="button"
            class="cinema-toast-action"
            @click.stop="startTranscode()"
          >
            切换转码播放
          </button>
          <button type="button" class="cinema-toast-action" @click.stop="download()">下载原片</button>
        </div>
      </Transition>

      <CinemaPlayerPlaylistOverlay
        :open="showPlayerPlaylist"
        :selected="selected"
        :same-directory-films="sameDirectoryFilms"
        :playlist-dir-label="playlistDirLabel"
        :directory-error="directoryError"
        :directory-loading="directoryLoading"
        :directory-next-cursor="directoryNextCursor"
        :leaving-player="leavingPlayer"
        :autoplay-next="autoplayNext"
        @close="togglePlaylist(false)"
        @reload="(append) => reloadPlaylist(append)"
        @select-film="(item) => switchPlaylistFilm(item)"
        @toggle-autoplay="(checked) => toggleAutoplay(checked)"
      />
    </div>

    <Transition name="isle-pop">
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
    </Transition>

    <footer
      v-if="canDirect || hlsSession || hlsStarting"
      ref="dockElRef"
      class="cinema-player-dock"
      :class="{
        'cinema-player-dock--dragging': draggingDock,
        'cinema-player-dock--moved': isDockMoved,
        'cinema-dock--upper': dockInUpperHalf,
      }"
      :style="{
        '--dock-x': `${dockOffset.x}px`,
        '--dock-y': `${dockOffset.y}px`,
        '--popover-shift-x': `${popoverShiftX}px`,
      }"
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
        <Transition name="cinema-cue-pop">
          <span
            v-if="previewBubbleTime !== null && effectiveDuration > 0"
            class="cinema-seek-tooltip"
            :style="{ '--preview-pct': `${previewBubblePct}%` }"
            aria-hidden="true"
          >{{ formatCinemaClock(previewBubbleTime) }}</span>
        </Transition>
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
          <button type="button" class="cinema-icon-btn cinema-play-toggle" :title="isPlaying ? '暂停（空格）' : '播放（空格）'" :aria-label="isPlaying ? '暂停' : '播放'" :disabled="hlsStarting" @click="togglePlay()">
            <Pause v-if="isPlaying" :size="19" fill="currentColor" />
            <Play v-else :size="19" fill="currentColor" />
          </button>

          <template v-if="sameDirectoryFilms.length > 1">
            <button type="button" class="cinema-icon-btn" title="上一部" aria-label="上一部" :disabled="hlsStarting || leavingPlayer || !hasPrevPlaylist" @click="prevPlaylist()"><SkipBack :size="17" /></button>
            <button type="button" class="cinema-icon-btn" title="下一部" aria-label="下一部" :disabled="hlsStarting || leavingPlayer || !hasNextPlaylist" @click="nextPlaylist()"><SkipForward :size="17" /></button>
          </template>

          <button type="button" class="cinema-icon-btn cinema-skip-step" title="快退 10 秒（左方向键）" aria-label="快退 10 秒" :disabled="effectiveDuration <= 0" @click="jump(-10)"><RotateCcw :size="16" /></button>
          <button type="button" class="cinema-icon-btn cinema-skip-step" title="快进 10 秒（右方向键）" aria-label="快进 10 秒" :disabled="effectiveDuration <= 0" @click="jump(10)"><RotateCw :size="16" /></button>

          <div class="cinema-volume-cluster">
            <button type="button" class="cinema-icon-btn" :title="isMuted || volume === 0 ? '取消静音' : '静音'" :aria-label="isMuted || volume === 0 ? '取消静音' : '静音'" @click="toggleMute()">
              <VolumeX v-if="isMuted || volume === 0" :size="16" />
              <Volume2 v-else :size="16" />
            </button>
            <input type="range" class="cinema-volume-slider" min="0" max="1" step="0.02" :value="isMuted ? 0 : volume" :style="{ '--vol-pct': `${volumePercent}%` }" aria-label="音量" @input="setVolume(Number(($event.target as HTMLInputElement).value))" />
          </div>

          <span class="cinema-time-readout">
            <span class="cinema-time-current">{{ formatCinemaClock(displayPosition) }}</span>
            <span class="cinema-time-sep">/</span>
            <span class="cinema-time-total">{{ formatCinemaClock(effectiveDuration) }}</span>
          </span>
        </div>

        <div class="cinema-player-dock-right">
          <button type="button" class="cinema-pill-btn" :class="{ active: showPlayerPlaylist }" title="同目录播放列表" @click="closeMenus(); togglePlaylist(!showPlayerPlaylist)">
            <ListVideo :size="14" />
            <span class="cinema-pill-label--full">{{ sameDirectoryFilms.length > 1 ? `列表 ${Math.max(1, currentPlaylistIndex + 1)}/${sameDirectoryFilms.length}` : "列表" }}</span>
          </button>

          <CinemaPlayerMenus
            :open-menu="openMenu"
            :selected="selected"
            :dock-in-upper-half="dockInUpperHalf"
            :display-position="displayPosition"
            :caption="caption"
            :caption-pill-label="captionPillLabel"
            :caption-options="captionOptions"
            :subtitle-size="subtitleSize"
            :subtitle-offset="subtitleOffset"
            :local-subtitle-name="localSubtitleName"
            :local-subtitle-error="localSubtitleError"
            :chapters="chapters"
            :hls-session="hlsSession"
            :hls-starting="hlsStarting"
            :audio-track-options="audioTrackOptions"
            :audio-pill-label="audioPillLabel"
            :quality-options="qualityOptions"
            :current-quality="currentQuality"
            :quality-pill-label="qualityPillLabel"
            :prefer-local-decode="preferLocalDecode"
            :autoplay-next="autoplayNext"
            :playback-rate="playbackRate"
            :rate-pill-label="ratePillLabel"
            :playback-rate-options="playbackRateOptions"
            @toggle-menu="toggleMenu"
            @close-menus="closeMenus"
            @select-caption="(val) => selectCaption(val)"
            @select-local-subtitle="(file) => selectLocalSubtitle(file)"
            @clear-local-subtitle="clearLocalSubtitle()"
            @update:subtitle-size="(s) => setSubtitleSize(s)"
            @adjust-subtitle-offset="(d) => adjustSubtitleOffset(d)"
            @reset-subtitle-offset="resetSubtitleOffset()"
            @seek="(pos) => seek(pos)"
            @select-audio="(idx) => selectAudio(idx)"
            @select-quality="(q) => selectQuality(q)"
            @toggle-local-decode="(c) => toggleLocalDecode(c)"
            @toggle-autoplay="(c) => toggleAutoplay(c)"
            @select-rate="(r) => selectRate(r)"
          />

          <span class="cinema-dock-sep" aria-hidden="true"></span>

          <div class="cinema-dock-util-group">
            <button type="button" class="cinema-icon-btn" :class="{ active: fillScreen }" :title="fillScreen ? '适应屏幕' : '铺满画面'" :aria-label="fillScreen ? '适应屏幕' : '铺满画面'" @click="toggleFill()"><Scan :size="16" /></button>
            <button v-if="canPictureInPicture" type="button" class="cinema-icon-btn" title="画中画" aria-label="画中画" @click="togglePip()"><PictureInPicture2 :size="16" /></button>
            <button type="button" class="cinema-icon-btn" :title="isFullscreen ? '退出全屏' : '全屏播放'" :aria-label="isFullscreen ? '退出全屏' : '全屏播放'" @click="toggleFullscreen()">
              <Minimize2 v-if="isFullscreen" :size="16" />
              <Maximize2 v-else :size="16" />
            </button>
            <button type="button" class="cinema-icon-btn" title="收起控制栏（避免遮挡底部字幕）" aria-label="收起控制栏" @click="collapseDockForSubtitles"><EyeOff :size="15" /></button>
          </div>
        </div>
      </div>
    </footer>
  </div>
</template>
