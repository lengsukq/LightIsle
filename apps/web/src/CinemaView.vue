<script setup lang="ts">
import { createCinemaKeyboardController } from "./cinemaKeyboard.ts";
import { createVisibleMediaPolling } from "./visibleMediaPolling.ts";
import { ref, onMounted, onBeforeUnmount, onUnmounted, watch, nextTick } from "vue";
import { describeRootOperationFailure } from "./rootDiscovery.ts";
import { describeUserFacingError } from "./userFacingError.ts";
import { createScopedRootApi } from "./apiClient.ts";
import { Trash2, X } from "lucide-vue-next";
import { rootApiPath, rootMediaPath } from "./rootApi.ts";
import CinemaBrowseGrids from "./CinemaBrowseGrids.vue";
import CinemaHeaderBar from "./CinemaHeaderBar.vue";
import CinemaPlayerStage from "./CinemaPlayerStage.vue";
import CinemaRenameModal from "./CinemaRenameModal.vue";
import CinemaSeriesModal from "./CinemaSeriesModal.vue";
import CinemaTmdbPanel from "./CinemaTmdbPanel.vue";
import CinemaHomeShelvesSection from "./CinemaHomeShelvesSection.vue";
import CinemaDetailMetadataPanels from "./CinemaDetailMetadataPanels.vue";
import { useCinemaPlayback } from "./useCinemaPlayback.ts";
import { duration, useCinemaMetadata } from "./useCinemaMetadata.ts";
import { useCinemaSeriesAndHistory } from "./useCinemaSeriesAndHistory.ts";
import { useCinemaDirectoryPlaylist } from "./useCinemaDirectoryPlaylist.ts";
import { useCinemaCatalogController } from "./composables/useCinemaCatalogController.ts";
import { continueAfterPlaybackEnd } from "./cinemaAutoAdvance.ts";
import { confirmCinemaExit } from "./cinemaSafeExit.ts";
import { createBrowserMediaBackstack } from "./browserMediaBackstack.ts";
import { pushModalLayer, type ModalLayerHandle } from "./modalStack.ts";
import IsleButton from "./IsleButton.vue";
import type { Movie } from "./cinemaTypes.ts";

const props = defineProps<{ active?: boolean; admin: boolean; rootId?: string; rootGeneration?: number }>();
const emit = defineEmits<{
  (e: "open-mount-guide"): void;
  (e: "open-scraping-settings"): void;
}>();
const movies = ref<Movie[]>([]);
const mode = ref("all");
const watchedFilter = ref<"all" | "unwatched" | "watched">("all");
const sortBy = ref<"recent" | "rating" | "year" | "title">("recent");
const query = ref("");
const actionError = ref("");
const selected = ref<Movie | null>(null);
const viewerPlaying = ref(false);
const showPlayerPlaylist = ref(false);
const playerControlsHidden = ref(false);
const leavingPlayer = ref(false);
const exitSaveBlocked = ref(false);
let mediaBackstack: ReturnType<typeof createBrowserMediaBackstack> | null = null;
let cinemaLayerHandle: ModalLayerHandle | null = null;
const cinemaDialog = ref<HTMLElement | null>(null);
const playerStageRef = ref<{ closeMenus: () => void } | null>(null);
const playerMenuOpen = ref(false);
const osdMessage = ref("");
let osdTimer: number | undefined;
const keyboardController = createCinemaKeyboardController();

function showOsd(text: string) {
  osdMessage.value = text;
  if (osdTimer) window.clearTimeout(osdTimer);
  osdTimer = window.setTimeout(() => {
    osdTimer = undefined;
    osdMessage.value = "";
  }, 1100);
}

watch(selected, (film) => {
  if (film) {
    cinemaLayerHandle?.dispose();
    cinemaLayerHandle = pushModalLayer({
      onEsc: () => {
        if (viewerPlaying.value && isFullscreen.value) {
          void exitCinemaFullscreen();
        } else if (viewerPlaying.value && playerMenuOpen.value) {
          playerStageRef.value?.closeMenus();
          playerMenuOpen.value = false;
        } else if (viewerPlaying.value && showPlayerPlaylist.value) {
          showPlayerPlaylist.value = false;
        } else {
          if (viewerPlaying.value) returnToOverview();
          else close();
        }
      },
      lockScroll: true,
    });
  } else {
    keyboardController.reset();
    osdMessage.value = "";
    cinemaLayerHandle?.dispose();
    cinemaLayerHandle = null;
  }
});
let returnFocus: HTMLElement | null = null;
const seriesDialog = ref<HTMLElement | null>(null);
const posterFailed = ref<Record<number, boolean>>({});
const view = ref<"films" | "series">("films");

let searchTimer: number | undefined;
let disposed = false;
let rootEpoch = 0;
let rootScopeAbort = new AbortController();
let playbackGeneration = 0;
let selectedController: AbortController | undefined;

function apiPath(path: string) { return rootApiPath(props.rootId, path); }
function mediaPath(path: string) { return rootMediaPath(props.rootId, props.rootGeneration ?? 0, path); }
const { api } = createScopedRootApi({
  getRootId: () => props.rootId,
  getRootGeneration: () => props.rootGeneration ?? 0,
  getEpoch: () => rootEpoch,
  getSignal: () => rootScopeAbort.signal,
});

const {
  next, loading, pageLoaded, loadError, scanActionError, scanStatusLoading, scanStatusLoaded, scanStatusError, scan,
  continueShelf, recentShelf, shelvesError, featuredFilm, showRecentShelf, deleting, choosingTrash, trashIDs,
  filteredView, emptyTitle, emptyMessage, continueCount, disambiguationMap, toggleTrashFilm,
  loadHomeShelves, load, retryLoad, trashFilms, trashSelectedFilms, status, startScan,
  clearCatalogForQueryChange, resetCatalogForRootChange, disposeCatalog,
} = useCinemaCatalogController({
  props, movies, mode, watchedFilter, sortBy, query, view, selected, posterFailed, actionError,
  getRootEpoch: () => rootEpoch, isDisposed: () => disposed, api, apiPath,
  onSelectedTrashed: () => close(),
  onScanCompleted: () => { void refreshScrape(); if (view.value === "series") void loadSeries(); },
});

const {
  player, hlsPlayer, caption, playError, hlsSession, hlsStarting,
  playbackRate, isSpeedBoosting, autoplayNext, preferLocalDecode, directLocalOverride,
  subtitleSize, subtitleOffset, localSubtitleName, localSubtitleError,
  playbackPosition, playbackDuration, playbackBuffered, canPictureInPicture,
  progressSaveError, retryProgress, currentFilmProgressUnsaved, refreshProgressSaveError, refreshBufferedProgress, resetPlaybackForFilm, stream, track, download, playback, canAttemptDirect, destroyHls,
  resetPendingSeek, startTranscode, switchAudioTrack, switchQuality, playbackRateOptions,
  captionOptions, audioTrackOptions, currentQuality, cinemaQualityOptions, setPlaybackRate, startHoldSpeedBoost, stopHoldSpeedBoost,
  setAutoplayNext, setPreferLocalDecode, activeVideo, loaded, save, tick, resetProgressClock, changeCaption, captionLoaded, captionSrclang,
  loadLocalSubtitleFile, clearLocalSubtitle, setSubtitleSize, adjustSubtitleOffset, resetSubtitleOffset,
  jumpPlayback, seekAbsolute, exitCinemaFullscreen, toggleCinemaFullscreen, toggleCinemaPictureInPicture, transcodeErrorMessage,
  isPlaying, volume, isMuted, fillScreen, isFullscreen, syncVideoMediaState, togglePlayPause, setVolume, adjustVolume, toggleMute, toggleFillScreen, syncFullscreenState,
} = useCinemaPlayback({ selected, movies, props, api, apiPath, mediaPath });

const {
  candidatePosterFailed, scraping, scrapeMessage, tmdbQuery, tmdbToken, tmdbMatches, tmdbBusy, tmdbError, batchToken, batchBusy, batchError, batchProgress, batchCandidates,
  doubanQuery, doubanMatches, doubanBusy, doubanError, scrapeState, scrapeBusy, scrapeNotice, scrapeError, cancelBatch, suggestBatch, acceptBatchCandidate,
  searchDouban, matchDouban, renameTarget, renameTitle, renameBusy, renameError, openRenameModal, closeRenameModal, submitRename, importLocalNFO, searchTMDB, matchTMDB, refreshScrape, startScrape, resetMetadataForOpen, resetMetadataForClose, resetMetadataForRootChange, disposeMetadata,
} = useCinemaMetadata({
  isAdmin: () => props.admin, getRootId: () => props.rootId, getRootGeneration: () => props.rootGeneration ?? 0, getRootEpoch: () => rootEpoch, isDisposed: () => disposed,
  movies, selected, posterFailed, actionError, api, apiPath, load: (reset) => load(reset), transcodeErrorMessage,
});

const {
  matchingSeries, seriesSearchLoading, seriesSearchError, historyFilms, historyLoading, historyError, seriesList, seriesLoading, seriesError, seriesDetail, seriesDetailLoading, seriesDetailError,
  seriesTmdbId, seriesTmdbBusy, seriesTmdbMessage, resetSeriesSearch, searchForSeries, loadHistory, clearHistory, markWatched, clearProgress, findNextEpisode, loadSeries, switchView, openSeries,
  finishCloseSeries, closeSeries, seasonNumbers, continueSeries, matchSeriesTMDB, resetSeriesAndHistoryForRootChange, disposeSeriesAndHistory,
} = useCinemaSeriesAndHistory({
  isAdmin: () => props.admin, getRootEpoch: () => rootEpoch, isDisposed: () => disposed, query, watchedFilter, sortBy, view, movies, selected, scrapeMessage, seriesDialog, api, apiPath,
  load: (reset) => load(reset), loadHomeShelves, open: (v, autoStart) => open(v, autoStart), getMediaBackstack: () => mediaBackstack,
});

const {
  directoryOf: playlistDirectory, reset: resetDirectoryPlaylist, load: loadDirectoryPlaylist, findNext: findNextDirectoryFilm, sameDirectoryFilms, currentIndex: currentPlaylistIndex,
  previousFilm: prevPlaylistFilm, nextFilm: nextPlaylistFilm, loading: directoryLoading, error: directoryError, nextCursor: directoryNextCursor,
} = useCinemaDirectoryPlaylist({
  selected, sources: () => [movies.value, continueShelf.value, recentShelf.value, historyFilms.value, seriesDetail.value?.films ?? []],
  rootEpoch: () => rootEpoch, disposed: () => disposed, api, apiPath, describeError: describeRootOperationFailure,
});

function playSelected() {
  const film = selected.value;
  if (!film || viewerPlaying.value) return;
  mediaBackstack?.push();
  viewerPlaying.value = true;
  if (!canAttemptDirect(film)) {
    if (film.probeStatus === "pending") {
      playError.value = "正在检查此视频格式，识别完成后可重试；原片可下载。";
      return;
    }
    void startTranscode(film, film.position > 5 && !film.completed ? film.position : 0, 0);
  }
}

function returnToOverview() {
  if (mediaBackstack?.depth && mediaBackstack.depth > 1) { mediaBackstack.back(); return; }
  void leavePlayer("overview");
}

function finishReturnToOverview() {
  player.value?.pause(); hlsPlayer.value?.pause(); destroyHls();
  viewerPlaying.value = false; showPlayerPlaylist.value = false; playerControlsHidden.value = false; exitSaveBlocked.value = false;
  playError.value = "";
  void loadHomeShelves();
  void nextTick(() => cinemaDialog.value?.focus());
}

function onPlayerPlaylistToggle(openState: boolean) {
  showPlayerPlaylist.value = openState;
  if (openState && selected.value) void loadDirectoryPlaylist(selected.value);
}

async function switchPlaylistFilm(target: Movie, autoStart = true) {
  if (!selected.value || leavingPlayer.value) return;
  if (target.id === selected.value.id) {
    showPlayerPlaylist.value = false;
    if (autoStart && !viewerPlaying.value) playSelected();
    return;
  }
  if (viewerPlaying.value) {
    leavingPlayer.value = true; exitSaveBlocked.value = false;
    try {
      activeVideo()?.pause();
      const saved = await confirmCinemaExit({
        save, hasUnsaved: currentFilmProgressUnsaved,
        onLeave: () => {}, onFailure: () => { exitSaveBlocked.value = true; },
      });
      if (!saved) return;
    } finally { leavingPlayer.value = false; }
  }
  showPlayerPlaylist.value = false;
  await open(target, autoStart);
}

async function findNextPlayable(film: Movie): Promise<Movie | null> {
  if (film.kind === "series") {
    const episode = await findNextEpisode(film);
    if (episode) return episode;
  }
  return findNextDirectoryFilm(film);
}

watch([() => props.rootId, () => props.rootGeneration], () => {
  mediaBackstack?.reset();
  resetDirectoryPlaylist(); showPlayerPlaylist.value = false; playerControlsHidden.value = false;
  rootScopeAbort.abort(); rootScopeAbort = new AbortController();
  rootEpoch += 1; playbackGeneration += 1; selectedController?.abort(); if (searchTimer) clearTimeout(searchTimer);
  resetMetadataForRootChange();
  resetSeriesAndHistoryForRootChange();
  resetCatalogForRootChange();
  refreshProgressSaveError();
  destroyHls(); resetPlaybackForFilm(null);
  selected.value = null; viewerPlaying.value = false; playError.value = ""; player.value?.pause();
  void load(true); void loadHomeShelves(); void status(); void refreshScrape();
  if (view.value === "series") void loadSeries();
  if (mode.value === "history" && view.value === "films") void loadHistory(true);
}, { flush: "sync" });

function filter(value: string) {
  if (searchTimer) clearTimeout(searchTimer);
  if (query.value) query.value = "";
  view.value = "films";
  mode.value = value;
  if (value === "history") { void loadHistory(true); return; }
  void load(true);
  if (value === "all") void loadHomeShelves();
}

watch(query, () => {
  if (query.value.trim()) { view.value = "films"; mode.value = "all"; }
  clearCatalogForQueryChange();
  if (searchTimer) clearTimeout(searchTimer);
  const term = query.value.trim();
  resetSeriesSearch();
  searchTimer = window.setTimeout(() => {
    void load(true);
    if (term) void searchForSeries(term);
  }, 350);
}, { flush: "sync" });

watch([watchedFilter, sortBy], () => {
  if (view.value === "series") {
    void loadSeries(true);
    return;
  }
  if (mode.value !== "history") {
    clearCatalogForQueryChange();
    void load(true);
  }
  const term = query.value.trim();
  if (term) void searchForSeries(term);
});

function resetFilters() {
  mode.value = "all"; watchedFilter.value = "all"; sortBy.value = "recent"; query.value = "";
  if (searchTimer) { clearTimeout(searchTimer); searchTimer = undefined; }
  void load(true);
}

function playbackLabel(v: Movie) {
  const m = playback(v);
  if (m === "verified-direct") return "已验证可播放";
  if (m === "unverified-direct") return "可尝试播放 · 尚未验证";
  const s = v.probeStatus;
  if (s === "pending") return "正在识别格式";
  if (s === "unavailable") return "格式检查器不可用";
  if (s === "failed") return "格式识别失败";
  if (s === "unsupported") return "浏览器暂不支持";
  return "建议下载后播放";
}
function posterReady(v: Movie) { return v.probeStatus === "ready" && !posterFailed.value[v.id]; }
function poster(v: Movie) { return v.posterURL || mediaPath("/api/v2/cinema/" + v.id + "/poster"); }

async function open(v: Movie, autoStart = false) {
  if (!selected.value) mediaBackstack?.push();
  playbackGeneration += 1;
  selectedController?.abort();
  resetMetadataForOpen(v);
  destroyHls(); resetPlaybackForFilm(null);
  seriesTmdbMessage.value = "";
  const controller = new AbortController(); selectedController = controller;
  if (!selected.value) returnFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;
  selected.value = v; viewerPlaying.value = autoStart; playerControlsHidden.value = false; caption.value = "off"; playError.value = ""; directLocalOverride.value = preferLocalDecode.value; resetProgressClock(); resetPlaybackForFilm(v);
  void loadDirectoryPlaylist(v);
  void nextTick(() => cinemaDialog.value?.focus());
  if (!canAttemptDirect(v)) {
    if (v.probeStatus === "pending") {
      playError.value = "正在识别此视频格式，当前无法判断是否可直接播放。识别完成后可重新打开，也可以先下载原片。";
      return;
    }
    if (autoStart) await startTranscode(v, v.position > 5 && !v.completed ? v.position : 0, 0);
    else playError.value = playbackLabel(v) + "。可尝试在线转码播放（服务器实时转封装/转码，原片不变），或下载原片后用 IINA、VLC 打开。";
    return;
  }
  if (autoStart && playback(v) === "unverified-direct") playError.value = "该格式尚未经过本机解码验证，正在尝试浏览器播放；若无法解码，请下载原片使用本地播放器。";
  try {
    const detail = await api<Movie>(apiPath("/api/v2/cinema/" + v.id), "GET", undefined, controller.signal);
    if (controller.signal.aborted || selected.value?.id !== v.id) return;
    selected.value = detail;
    const detailDur = Math.max(detail.durationSeconds || 0, detail.duration || 0);
    if (detailDur > playbackDuration.value) playbackDuration.value = detailDur;
    if (!viewerPlaying.value && !hlsSession.value && !hlsStarting.value) resetPlaybackForFilm(detail);
    if (!canAttemptDirect(detail)) {
      if (autoStart) await startTranscode(detail, detail.position > 5 && !detail.completed ? detail.position : 0, 0);
      else playError.value = playbackLabel(detail) + "。可尝试在线转码播放，或下载原片后用 IINA、VLC 打开。";
    } else if (autoStart && playback(detail) === "unverified-direct") {
      playError.value = "该格式尚未经过本机解码验证，正在尝试浏览器播放；若无法解码，请下载原片使用本地播放器。";
    } else {
      playError.value = "";
    }
  } catch (e) {
    if (!(e instanceof Error && e.name === "AbortError")) {
      /* Keep list metadata and visible fallback guidance when detail fetch fails. */
    }
  }
}

async function playbackEnded() {
  const finished = selected.value;
  const generation = playbackGeneration;
  await continueAfterPlaybackEnd({
    film: finished,
    saveFinished: () => save(true),
    shouldAdvance: (film) => autoplayNext.value && (film.kind === "series" || !!film.path),
    isCurrent: () => !disposed && generation === playbackGeneration && selected.value?.id === finished?.id,
    findNext: findNextPlayable,
    openNext: (film) => open(film, true),
    onNoNext: () => {
      playError.value = directoryError.value
        ? "同目录播放列表读取失败：" + directoryError.value
        : finished?.kind === "series"
          ? "本季已播完，或还没有扫描到下一集。可从剧集库选择继续观看。"
          : "当前目录没有下一部影片。";
    },
  });
}

function finishClose() {
  playbackGeneration += 1; selectedController?.abort(); selectedController = undefined; resetMetadataForClose();
  player.value?.pause(); hlsPlayer.value?.pause(); destroyHls(); resetDirectoryPlaylist(); selected.value = null; viewerPlaying.value = false; showPlayerPlaylist.value = false; playerControlsHidden.value = false; exitSaveBlocked.value = false;
  playError.value = ""; seriesTmdbMessage.value = ""; resetPendingSeek(); resetPlaybackForFilm(null);
  const target = returnFocus; returnFocus = null; void nextTick(() => { if (target?.isConnected) target.focus(); }); void loadHomeShelves();
}

async function leavePlayer(destination: "overview" | "close", allowUnsaved = false): Promise<boolean> {
  if (leavingPlayer.value || !selected.value) return false;
  if (!viewerPlaying.value) { finishClose(); return true; }
  if (allowUnsaved) {
    if (destination === "overview") finishReturnToOverview(); else finishClose();
    return true;
  }
  leavingPlayer.value = true; exitSaveBlocked.value = false;
  try {
    activeVideo()?.pause();
    return await confirmCinemaExit({
      save, hasUnsaved: currentFilmProgressUnsaved,
      onLeave: () => { if (destination === "overview") finishReturnToOverview(); else finishClose(); },
      onFailure: () => { exitSaveBlocked.value = true; },
    });
  } finally { leavingPlayer.value = false; }
}

function close() {
  if (mediaBackstack?.back(seriesDetail.value ? 1 : mediaBackstack.depth)) return;
  void leavePlayer("close");
}

function cinemaKeyBindings() {
  const playing = selected.value !== null && viewerPlaying.value;
  return {
    dialog: selected.value ? cinemaDialog.value : seriesDetail.value ? seriesDialog.value : null,
    playing,
    playlistOpen: showPlayerPlaylist.value,
    popoverOpen: playerMenuOpen.value,
    isFullscreen: isFullscreen.value,
    showControls: () => { playerControlsHidden.value = false; },
    jump: (seconds: number) => {
      showOsd(seconds > 0 ? `⏩ +${seconds}s` : `⏪ ${seconds}s`);
      void jumpPlayback(seconds);
    },
    togglePlay: () => {
      const willPlay = !isPlaying.value;
      showOsd(willPlay ? "▶ 继续播放" : "⏸ 已暂停");
      void togglePlayPause();
    },
    adjustVolume: (delta: number) => {
      adjustVolume(delta);
      showOsd(isMuted.value || volume.value === 0 ? "🔇 已静音" : `🔊 音量 ${Math.round(volume.value * 100)}%`);
    },
    toggleMute: () => {
      toggleMute();
      showOsd(isMuted.value || volume.value === 0 ? "🔇 已静音" : `🔊 音量 ${Math.round(volume.value * 100)}%`);
    },
    toggleFullscreen: () => void toggleCinemaFullscreen(cinemaDialog.value),
    exitFullscreen: () => void exitCinemaFullscreen(),
    startHoldBoost: () => startHoldSpeedBoost(),
    stopHoldBoost: () => stopHoldSpeedBoost(),
    closePopover: () => { playerStageRef.value?.closeMenus(); playerMenuOpen.value = false; },
    closePlaylist: () => { showPlayerPlaylist.value = false; },
    close: () => selected.value ? (playing ? returnToOverview() : close()) : closeSeries(),
  };
}

function keydown(event: KeyboardEvent) {
  if (props.active === false || event.defaultPrevented) return;
  if (cinemaLayerHandle && !cinemaLayerHandle.isTop()) return;
  keyboardController.handleKeydown(event, cinemaKeyBindings());
}

function keyup(event: KeyboardEvent) {
  if (props.active === false) return;
  keyboardController.handleKeyup(event, cinemaKeyBindings());
}

function onWindowBlur() {
  keyboardController.reset();
  stopHoldSpeedBoost();
}

const setScanPolling = createVisibleMediaPolling(status, 5000);
function syncCinemaActiveBindings(active: boolean) {
  setScanPolling(active);
  if (active) {
    window.addEventListener("keydown", keydown);
    window.addEventListener("keyup", keyup);
    window.addEventListener("blur", onWindowBlur);
  } else {
    keyboardController.reset();
    stopHoldSpeedBoost();
    window.removeEventListener("keydown", keydown);
    window.removeEventListener("keyup", keyup);
    window.removeEventListener("blur", onWindowBlur);
  }
}

function onVisibilityFlush() {
  if (document.visibilityState === "hidden" && selected.value && viewerPlaying.value) void save();
}
function onPageHideFlush() {
  if (selected.value && viewerPlaying.value) void save();
}

onMounted(() => {
  disposed = false;
  document.addEventListener("visibilitychange", onVisibilityFlush);
  window.addEventListener("pagehide", onPageHideFlush);
  mediaBackstack = createBrowserMediaBackstack(window, "lightisle-cinema", async (_old, target) => {
    if (selected.value) {
      const toOverview = viewerPlaying.value && target > 0 && !seriesDetail.value;
      const saved = await leavePlayer(toOverview ? "overview" : "close");
      if (saved && target === 0 && seriesDetail.value) finishCloseSeries();
      return saved;
    }
    if (seriesDetail.value) finishCloseSeries();
    return true;
  });
  void load(true); void loadHomeShelves(); void status(); void refreshScrape();
  syncCinemaActiveBindings(props.active !== false);
});

watch(() => props.active, (val) => {
  const isActive = val !== false;
  syncCinemaActiveBindings(isActive);
  if (!isActive) {
    if (selected.value) void leavePlayer("close", true);
    if (seriesDetail.value) finishCloseSeries();
  } else if (!document.hidden) {
    void status();
  }
});

onBeforeUnmount(() => { void save(); });
onUnmounted(() => {
  document.removeEventListener("visibilitychange", onVisibilityFlush);
  window.removeEventListener("pagehide", onPageHideFlush);
  cinemaLayerHandle?.dispose(); cinemaLayerHandle = null;
  disposed = true; rootEpoch += 1; rootScopeAbort.abort(); syncCinemaActiveBindings(false); resetDirectoryPlaylist();
  mediaBackstack?.dispose(); mediaBackstack = null; playbackGeneration += 1; disposeSeriesAndHistory();
  if (searchTimer) clearTimeout(searchTimer); if (osdTimer) clearTimeout(osdTimer); clearLocalSubtitle(); selectedController?.abort(); disposeMetadata(); destroyHls(); disposeCatalog();
});
</script>

<template>
  <div class="content cinema-view">
    <CinemaHeaderBar
      v-model:query="query"
      v-model:watched-filter="watchedFilter"
      v-model:sort-by="sortBy"
      :admin="admin"
      :view="view"
      :mode="mode"
      :can-batch-trash="admin || movies.some(movie => movie.canWrite === true)"
      :choosing-trash="choosingTrash"
      :deleting="deleting"
      :scan-running="scan.running"
      :scan-status-error="scanStatusError"
      @toggle-trash-mode="choosingTrash = !choosingTrash; trashIDs = new Set()"
      @start-scan="startScan"
      @filter="filter"
      @switch-view="switchView"
      @open-mount-guide="emit('open-mount-guide')"
      @open-scraping-settings="emit('open-scraping-settings')"
    />
    <CinemaTmdbPanel
      v-if="admin && view === 'films' && mode === 'unmatched'"
      v-model:batch-token="batchToken"
      :batch-busy="batchBusy"
      :batch-progress="batchProgress"
      :batch-error="batchError"
      :batch-candidates="batchCandidates"
      :scrape-state="scrapeState"
      :scrape-busy="scrapeBusy"
      :scrape-notice="scrapeNotice"
      :scrape-error="scrapeError"
      :unmatched-count="movies.length"
      @suggest-batch="suggestBatch"
      @cancel-batch="cancelBatch"
      @accept-candidate="acceptBatchCandidate"
      @start-scrape="startScrape"
    />
    <div v-if="scan.running&&!scanStatusError" class="cinema-alert">正在扫描：{{scan.visited}} 项 · 已找到 {{scan.found}} 部作品</div>
    <div v-if="scanStatusError&&movies.length" class="cinema-alert" role="alert">扫描状态读取失败：{{scanStatusError}} <span v-if="scanStatusLoaded">显示的是最近一次成功读取的状态。</span> <button type="button" class="account-action" :disabled="scanStatusLoading" @click="status">{{scanStatusLoading?"正在重试…":"重试状态"}}</button></div>
    <div v-if="scanStatusLoaded&&scan.lastError&&movies.length" class="cinema-alert" role="alert">扫描未完成：{{describeUserFacingError(scan.lastError)}}</div>
    <div v-if="scanActionError&&movies.length" class="cinema-alert" role="alert">无法启动扫描：{{scanActionError}}</div>
    <div v-if="actionError&&movies.length" class="cinema-alert" role="alert">{{actionError}}</div>
    <div v-if="loadError&&movies.length" class="cinema-alert" role="alert">加载影视库失败：{{loadError}} 当前仍显示上次成功读取的内容。 <button type="button" class="account-action" :disabled="loading" @click="retryLoad">重试加载</button></div>
    <div v-if="progressSaveError" class="cinema-alert" role="alert">{{progressSaveError}} <button type="button" class="account-action" @click="retryProgress">重试保存进度</button></div>
    <Transition name="isle-hud-float">
      <div v-if="choosingTrash&&view==='films'&&mode!=='history'" class="cinema-batch-hud" role="group" aria-label="已选择影片的操作">
        <span>已选 {{trashIDs.size}} 部（最多50部）</span>
        <IsleButton variant="glass" size="sm" :disabled="deleting" @click="trashIDs=new Set(movies.filter(movie=>admin||movie.canWrite===true).slice(0,50).map(movie=>movie.id))">全选可删除影片</IsleButton>
        <IsleButton v-if="trashIDs.size" variant="glass" size="sm" :disabled="deleting" @click="trashIDs=new Set()">清空选择</IsleButton>
        <IsleButton variant="danger" size="sm" :disabled="deleting||!trashIDs.size" @click="trashSelectedFilms"><template #icon><Trash2 :size="14"/></template>移入回收站</IsleButton>
        <IsleButton variant="primary" size="sm" :disabled="deleting" @click="choosingTrash=false;trashIDs=new Set()"><template #icon><X :size="14"/></template>完成</IsleButton>
      </div>
    </Transition>
    <p v-if="view==='films'&&mode==='continue'&&continueCount" class="cinema-hint">当前列表有 {{continueCount}} 部作品可继续观看</p>
    <CinemaHomeShelvesSection
      v-if="view==='films'&&mode==='all'&&!query.trim()&&!choosingTrash"
      class="isle-subview-pane"
      :featured-film="featuredFilm"
      :continue-shelf="continueShelf"
      :recent-shelf="recentShelf"
      :show-recent-shelf="showRecentShelf"
      :shelves-error="shelvesError"
      :poster-failed="posterFailed"
      :poster-ready="posterReady"
      :poster-url="poster"
      @retry-shelves="loadHomeShelves"
      @open-film="(film, autoStart) => open(film, autoStart)"
      @clear-progress="clearProgress"
      @filter-mode="filter"
      @poster-error="(id) => { posterFailed[id] = true }"
    />
    <CinemaBrowseGrids
      :view="view"
      :mode="mode"
      :query="query"
      :admin="admin"
      :movies="movies"
      :next="next"
      :loading="loading"
      :page-loaded="pageLoaded"
      :load-error="loadError"
      :action-error="actionError"
      :scan-action-error="scanActionError"
      :scan-status-error="scanStatusError"
      :scan-status-loaded="scanStatusLoaded"
      :scan-status-loading="scanStatusLoading"
      :scan="scan"
      :choosing-trash="choosingTrash"
      :trash-ids="trashIDs"
      :deleting="deleting"
      :filtered-view="filteredView"
      :empty-title="emptyTitle"
      :empty-message="emptyMessage"
      :featured-film="featuredFilm"
      :continue-shelf="continueShelf"
      :show-recent-shelf="showRecentShelf"
      :disambiguation-map="disambiguationMap"
      :matching-series="matchingSeries"
      :series-search-loading="seriesSearchLoading"
      :series-search-error="seriesSearchError"
      :series-list="seriesList"
      :series-loading="seriesLoading"
      :series-error="seriesError"
      :history-films="historyFilms"
      :history-loading="historyLoading"
      :history-error="historyError"
      :poster-failed="posterFailed"
      :poster-ready="posterReady"
      :poster-url="poster"
      :playback="playback"
      @retry-series-search="searchForSeries(query.trim())"
      @open-series="openSeries"
      @continue-series="continueSeries"
      @reload-series="loadSeries(true)"
      @retry-load="retryLoad"
      @retry-status="status"
      @start-scan="startScan"
      @reset-filters="resetFilters"
      @reload-history="loadHistory(true)"
      @clear-history="clearHistory"
      @open-film="(film, autoStart) => open(film, autoStart)"
      @toggle-trash-film="toggleTrashFilm"
      @trash-film="(film) => trashFilms([film])"
      @open-rename="openRenameModal"
      @mark-restart="(film) => { markWatched(film, false); open(film, true); }"
      @load-more="load()"
      @poster-error="(id) => { posterFailed[id] = true }"
    />
    <details class="cinema-foot"><summary>播放兼容性说明</summary><p>优先原画直出；浏览器不兼容时可在线转码（需 FFmpeg，不改动原片）或下载后用本地播放器打开。</p></details>

    <CinemaRenameModal
      :open="Boolean(renameTarget)"
      v-model:rename-title="renameTitle"
      :rename-busy="renameBusy"
      :rename-error="renameError"
      @close="closeRenameModal"
      @submit="submitRename"
    />

    <CinemaSeriesModal
      :open="Boolean(seriesDetail) && props.active !== false"
      :series-detail="seriesDetail"
      :series-detail-loading="seriesDetailLoading"
      :series-detail-error="seriesDetailError"
      :series-tmdb-id="seriesTmdbId"
      :series-tmdb-busy="seriesTmdbBusy"
      :series-tmdb-message="seriesTmdbMessage"
      :admin="admin"
      :season-numbers="seriesDetail ? seasonNumbers(seriesDetail.films) : []"
      @close="closeSeries"
      @play-episode="(episode) => open(episode, true)"
      @continue-series="continueSeries"
      @toggle-watched="(episode, completed) => markWatched(episode, completed)"
      @clear-progress="(episode) => clearProgress(episode)"
      @update:series-tmdb-id="seriesTmdbId = $event"
      @match-tmdb="matchSeriesTMDB"
    />

    <Teleport to="body">
      <Transition name="isle-overlay-fade">
      <div v-if="selected && props.active !== false" class="cinema-backdrop" :class="{'cinema-backdrop--media':!!seriesDetail,'cinema-backdrop--playing':viewerPlaying}" @click.self="close">
        <section ref="cinemaDialog" class="cinema-dialog" :class="{'cinema-dialog-playing':viewerPlaying,'cinema-controls-hidden':viewerPlaying&&playerControlsHidden}" role="dialog" aria-modal="true" :aria-label="selected.title+(viewerPlaying?' · 播放':' · 影片详情')" tabindex="-1">
          <header :class="{'cinema-player-topbar':viewerPlaying}">
            <div><strong>{{selected.title}}</strong><small>{{selected.kind==='series'?'第 '+selected.season+' 季 · 第 '+selected.episode+' 集':'电影'}} · {{selected.year||'年份未知'}} · {{duration(selected.durationSeconds||selected.duration||playbackDuration)}}</small></div>
            <div class="cinema-actions">
              <button v-if="viewerPlaying" type="button" class="cinema-top-pill" title="返回影片详情" aria-label="返回影片详情" :disabled="leavingPlayer" @click="returnToOverview">{{leavingPlayer?"正在保存…":"返回详情"}}</button>
              <button type="button" title="关闭" aria-label="关闭影片详情" :disabled="leavingPlayer" @click="close"><X :size="19"/></button>
            </div>
          </header>
          <div v-if="exitSaveBlocked" class="cinema-alert" :class="{'cinema-player-banner':viewerPlaying}" role="alert">
            当前影片的观看进度未保存，已暂停播放。请重试保存，或明确选择放弃本次未保存的进度。
            <button type="button" class="account-action" :disabled="leavingPlayer" @click="leavePlayer('close')">重试保存并关闭</button>
            <button type="button" class="account-action" :disabled="leavingPlayer" @click="leavePlayer('close',true)">仍然关闭（不保存）</button>
          </div>
          <CinemaDetailMetadataPanels
            v-if="!viewerPlaying"
            :selected="selected"
            :admin="admin"
            :can-trash-selected="Boolean((admin || selected.canWrite === true) && selected.path && movies.some(movie => movie.id === selected!.id))"
            :deleting="deleting"
            :leaving-player="leavingPlayer"
            :poster-failed="posterFailed"
            :poster-ready="posterReady"
            :poster-url="poster"
            :playback-mode="playback(selected)"
            :playback-label-text="playbackLabel(selected)"
            :same-directory-films="sameDirectoryFilms"
            :playlist-dir-label="playlistDirectory(selected.path)"
            :scrape-message="scrapeMessage"
            :scraping="scraping"
            :douban-query="doubanQuery"
            :douban-matches="doubanMatches"
            :douban-busy="doubanBusy"
            :douban-error="doubanError"
            :tmdb-token="tmdbToken"
            :tmdb-query="tmdbQuery"
            :tmdb-matches="tmdbMatches"
            :tmdb-busy="tmdbBusy"
            :tmdb-error="tmdbError"
            :candidate-poster-failed="candidatePosterFailed"
            @play-selected="playSelected"
            @poster-error="(id) => { posterFailed[id] = true }"
            @candidate-poster-error="(id) => { candidatePosterFailed[id] = true }"
            @switch-playlist-film="(film) => void switchPlaylistFilm(film, true)"
            @update:douban-query="doubanQuery = $event"
            @update:tmdb-token="tmdbToken = $event"
            @update:tmdb-query="tmdbQuery = $event"
            @search-douban="searchDouban"
            @match-douban="matchDouban"
            @search-tmdb="searchTMDB"
            @match-tmdb="matchTMDB"
            @trash-selected="trashFilms([selected])"
            @download-selected="download(selected)"
            @toggle-watched="markWatched(selected, !selected.completed)"
            @clear-progress="clearProgress(selected)"
            @restart-from-beginning="markWatched(selected, false); open(selected, true)"
            @import-local-nfo="importLocalNFO(selected)"
            @open-mount-guide="emit('open-mount-guide')"
          />
          <CinemaPlayerStage
            ref="playerStageRef"
            v-if="viewerPlaying" :selected="selected" :can-direct="canAttemptDirect(selected)"
            :stream-url="stream(selected)" :track-url="track(selected)" :caption="caption" :caption-srclang="captionSrclang()"
            :caption-options="captionOptions" :audio-track-options="audioTrackOptions" :quality-options="cinemaQualityOptions"
            :current-quality="currentQuality" :playback-rate="playbackRate" :is-speed-boosting="isSpeedBoosting" :osd-message="osdMessage" :playback-rate-options="playbackRateOptions"
            :subtitle-size="subtitleSize" :subtitle-offset="subtitleOffset" :local-subtitle-name="localSubtitleName" :local-subtitle-error="localSubtitleError"
            :hls-session="hlsSession" :hls-starting="hlsStarting" :play-error="playError" :is-playing="isPlaying"
            :volume="volume" :is-muted="isMuted" :fill-screen="fillScreen" :is-fullscreen="isFullscreen"
            :can-picture-in-picture="canPictureInPicture" :playback-position="playbackPosition" :playback-duration="playbackDuration" :playback-buffered="playbackBuffered"
            :autoplay-next="autoplayNext" :prefer-local-decode="preferLocalDecode"
            :leaving-player="leavingPlayer" :show-player-playlist="showPlayerPlaylist" :same-directory-films="sameDirectoryFilms"
            :current-playlist-index="currentPlaylistIndex" :has-prev-playlist="!!prevPlaylistFilm" :has-next-playlist="!!nextPlaylistFilm"
            :playlist-dir-label="playlistDirectory(selected.path)" :directory-loading="directoryLoading" :directory-error="directoryError"
            :directory-next-cursor="directoryNextCursor" :controls-hidden="playerControlsHidden"
            :set-direct-video-ref="(el) => { player = el }" :set-hls-video-ref="(el) => { hlsPlayer = el }"
            @update:controls-hidden="playerControlsHidden = $event"
            @update:menu-open="playerMenuOpen = $event"
            @update:show-player-playlist="onPlayerPlaylistToggle" @loadedmetadata="loaded" @timeupdate="tick" @buffer-progress="refreshBufferedProgress"
            @media-state="syncVideoMediaState(); syncFullscreenState()" @pause-save="save()" @ended="playbackEnded"
            @direct-error="playError = '浏览器无法解码该视频格式，可切换在线转码或下载原片使用 IINA / VLC 播放。'"
            @hls-error="playError = playError || '转码播放出错，可重新尝试或下载原片。'"
            @caption-load="captionLoaded" @toggle-play="togglePlayPause" @jump="(d) => { showOsd(d > 0 ? `⏩ +${d}s` : `⏪ ${d}s`); void jumpPlayback(d); }" @seek="seekAbsolute"
            @set-volume="setVolume" @toggle-mute="toggleMute"
            @select-caption="(val) => { caption = val; void changeCaption() }"
            @select-local-subtitle="loadLocalSubtitleFile"
            @clear-local-subtitle="clearLocalSubtitle"
            @update:subtitle-size="setSubtitleSize"
            @adjust-subtitle-offset="adjustSubtitleOffset"
            @reset-subtitle-offset="resetSubtitleOffset"
            @select-audio="(idx) => void switchAudioTrack(idx)" @select-quality="(q) => void switchQuality(q)"
            @select-rate="(r) => setPlaybackRate(r)" @toggle-autoplay="(c) => setAutoplayNext(c)"
            @toggle-local-decode="(c) => setPreferLocalDecode(c)" @toggle-fill="toggleFillScreen"
            @toggle-pip="toggleCinemaPictureInPicture" @toggle-fullscreen="toggleCinemaFullscreen(cinemaDialog)"
            @start-transcode="startTranscode(selected, selected.position > 5 && !selected.completed ? selected.position : 0, 0)"
            @download="download(selected)" @switch-playlist-film="(film) => void switchPlaylistFilm(film, true)"
            @prev-playlist="prevPlaylistFilm && void switchPlaylistFilm(prevPlaylistFilm, true)"
            @next-playlist="nextPlaylistFilm && void switchPlaylistFilm(nextPlaylistFilm, true)"
            @reload-playlist="(append) => void loadDirectoryPlaylist(selected!, append)"
          />
        </section>
      </div>
      </Transition>
    </Teleport>
  </div>
</template>
