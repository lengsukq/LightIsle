<script setup lang="ts">
import { createCinemaKeyboardController } from "./cinemaKeyboard.ts";
import { createVisibleMediaPolling } from "../../api/visibleMediaPolling.ts";
import { computed, ref, onMounted, onBeforeUnmount, onUnmounted, provide, watch, nextTick } from "vue";
import { describeRootOperationFailure } from "../../api/rootDiscovery.ts";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import { createScopedRootApi } from "../../api/apiClient.ts";
import { TIMINGS_MS } from "../../constants/timings.ts";
import {
  CINEMA_BROWSE_CTX,
  CINEMA_DETAIL_CTX,
  CINEMA_PLAYER_CTX,
} from "../../contexts/cinemaContext.ts";
import { Trash2, X } from "lucide-vue-next";
import { rootApiPath, rootMediaPath } from "../../api/rootApi.ts";
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
import { useCinemaCatalogController } from "./useCinemaCatalogController.ts";
import { isCinemaFilmPosterReady, resolveCinemaFilmPosterUrl, resolveCinemaSeriesPosterUrl } from "./cinemaCatalogDisplay.ts";
import { continueAfterPlaybackEnd } from "./cinemaAutoAdvance.ts";
import { confirmCinemaExit } from "./cinemaSafeExit.ts";
import { createBrowserMediaBackstack } from "../photos/browserMediaBackstack.ts";
import { pushModalLayer, type ModalLayerHandle } from "../../utils/modalStack.ts";
import IsleButton from "../../components/ui/IsleButton.vue";
import type { Movie } from "./cinemaTypes.ts";

const props = defineProps<{ active?: boolean; admin: boolean; rootId?: string; rootGeneration?: number; launchRequest?: { film: Movie; nonce: number } | null }>();
const emit = defineEmits<{ (e: "open-mount-guide"): void; (e: "launch-handled"): void }>();
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
const posterDirectFallback = ref<Record<number, boolean>>({});
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
  player, hlsPlayer, caption, playError, hlsSession, hlsStarting, hlsTracks,
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
  movies, selected, posterFailed, actionError, api, apiPath, load: (reset) => load(reset),
  onScrapeCompleted: () => { void loadHomeShelves(); if (view.value === "series") void loadSeries(); },
  onFilmRenamed: (filmId, title) => {
    const patch = (list: Movie[]) => list.map((m) => (m.id === filmId ? { ...m, title, titleSource: "manual" } : m));
    continueShelf.value = patch(continueShelf.value);
    recentShelf.value = patch(recentShelf.value);
    historyFilms.value = patch(historyFilms.value);
  },
  transcodeErrorMessage,
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
  }, TIMINGS_MS.SEARCH_DEBOUNCE);
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
const posterReady = (v: Movie) => isCinemaFilmPosterReady(v, posterFailed.value);
const poster = (v: Movie) => resolveCinemaFilmPosterUrl(v, mediaPath, posterDirectFallback.value);
const seriesPosterUrl = (id: number, rawUrl?: string) => resolveCinemaSeriesPosterUrl(id, rawUrl, mediaPath);
function onPosterError(id: number) {
  const hit = [selected.value, featuredFilm.value, ...movies.value, ...continueShelf.value, ...recentShelf.value, ...historyFilms.value].find((m) => m && m.id === id);
  if (hit?.posterURL && !posterDirectFallback.value[id]) posterDirectFallback.value[id] = true;
  else posterFailed.value[id] = true;
}

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

const setScanPolling = createVisibleMediaPolling(status, TIMINGS_MS.FAST_POLL);
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

let lastHandledLaunchNonce = 0;
function consumeLaunchRequest(req: { film: Movie; nonce: number } | null | undefined) {
  if (!req || req.nonce === lastHandledLaunchNonce || props.active === false) return;
  lastHandledLaunchNonce = req.nonce;
  emit("launch-handled");
  void open(req.film, true);
}
watch(() => [props.active, props.launchRequest] as const, ([activeVal, req]) => {
  if (activeVal !== false && req) consumeLaunchRequest(req);
});
let initialLoadPending = false;
function triggerInitialLoad() {
  void load(true);
  void loadHomeShelves();
  void status();
  void refreshScrape();
}
function openScrapingFlow() {
  if (view.value !== "films") view.value = "films";
  filter("unmatched");
  void refreshScrape();
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
  if (props.active !== false) {
    initialLoadPending = false;
    triggerInitialLoad();
  } else {
    initialLoadPending = true;
  }
  syncCinemaActiveBindings(props.active !== false);
  consumeLaunchRequest(props.launchRequest);
});

watch(() => props.active, (val) => {
  const isActive = val !== false;
  syncCinemaActiveBindings(isActive);
  if (!isActive) {
    if (selected.value) void leavePlayer("close", true);
    if (seriesDetail.value) finishCloseSeries();
  } else if (initialLoadPending) {
    initialLoadPending = false;
    triggerInitialLoad();
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

provide(CINEMA_BROWSE_CTX, {
  view, mode, query,
  admin: computed(() => props.admin),
  movies, next, loading, pageLoaded, loadError, actionError, scanActionError,
  scanStatusError, scanStatusLoaded, scanStatusLoading, scan, choosingTrash,
  trashIds: trashIDs, deleting, filteredView, emptyTitle, emptyMessage, featuredFilm,
  continueShelf, showRecentShelf, disambiguationMap, matchingSeries,
  seriesSearchLoading, seriesSearchError, seriesList, seriesLoading, seriesError,
  historyFilms, historyLoading, historyError, posterFailed, posterReady,
  posterUrl: poster, seriesPosterUrl, playback,
  retrySeriesSearch: () => void searchForSeries(query.value.trim()),
  openSeries, continueSeries,
  reloadSeries: () => void loadSeries(true),
  retryLoad,
  retryStatus: () => void status(),
  startScan, resetFilters,
  reloadHistory: () => void loadHistory(true),
  clearHistory,
  openFilm: (film, autoStart) => void open(film, autoStart),
  toggleTrashFilm,
  trashFilm: (film) => void trashFilms([film]),
  openRename: openRenameModal,
  markRestart: (film) => { void markWatched(film, false); void open(film, true); },
  loadMore: () => void load(),
  posterError: onPosterError,
});

provide(CINEMA_DETAIL_CTX, {
  selected,
  admin: computed(() => props.admin),
  canTrashSelected: computed(() =>
    Boolean(selected.value && (props.admin || selected.value.canWrite === true) && selected.value.path && movies.value.some((m) => m.id === selected.value!.id)),
  ),
  deleting, leavingPlayer, posterFailed, posterReady, posterUrl: poster, mediaPath, api, apiPath,
  playbackMode: computed(() => (selected.value ? playback(selected.value) : "download-only")),
  playbackLabelText: computed(() => (selected.value ? playbackLabel(selected.value) : "")),
  sameDirectoryFilms,
  playlistDirLabel: computed(() => (selected.value ? playlistDirectory(selected.value.path) : "")),
  scrapeMessage, scraping, doubanQuery, doubanMatches, doubanBusy, doubanError,
  tmdbToken, tmdbQuery, tmdbMatches, tmdbBusy, tmdbError, candidatePosterFailed,
  playSelected,
  posterError: onPosterError,
  candidatePosterError: (id) => { candidatePosterFailed.value[id] = true; },
  switchPlaylistFilm: (film) => void switchPlaylistFilm(film, true),
  searchDouban: () => void searchDouban(),
  matchDouban: (c) => void matchDouban(c),
  searchTmdb: () => void searchTMDB(),
  matchTmdb: (c) => void matchTMDB(c),
  trashSelected: () => { if (selected.value) void trashFilms([selected.value]); },
  downloadSelected: () => { if (selected.value) download(selected.value); },
  toggleWatched: () => { if (selected.value) void markWatched(selected.value, !selected.value.completed); },
  clearProgress: () => { if (selected.value) void clearProgress(selected.value); },
  restartFromBeginning: () => { if (selected.value) { void markWatched(selected.value, false); void open(selected.value, true); } },
  importLocalNfo: () => { if (selected.value) void importLocalNFO(selected.value); },
  openMountGuide: () => emit("open-mount-guide"),
});

provide(CINEMA_PLAYER_CTX, {
  selected,
  canDirect: computed(() => (selected.value ? canAttemptDirect(selected.value) : false)),
  streamUrl: computed(() => (selected.value ? stream(selected.value) : "")),
  trackUrl: computed(() => (selected.value ? track(selected.value) : "")),
  caption,
  captionSrclang: computed(() => captionSrclang()),
  captionOptions, audioTrackOptions, chapters: computed(() => hlsTracks.value?.chapters ?? []), qualityOptions: cinemaQualityOptions,
  currentQuality, playbackRate, isSpeedBoosting, osdMessage, playbackRateOptions,
  subtitleSize, subtitleOffset, localSubtitleName, localSubtitleError,
  hlsSession, hlsStarting, playError, isPlaying, volume, isMuted, fillScreen,
  isFullscreen, canPictureInPicture, playbackPosition, playbackDuration, playbackBuffered,
  autoplayNext, preferLocalDecode, leavingPlayer, showPlayerPlaylist, sameDirectoryFilms,
  currentPlaylistIndex,
  hasPrevPlaylist: computed(() => !!prevPlaylistFilm.value),
  hasNextPlaylist: computed(() => !!nextPlaylistFilm.value),
  playlistDirLabel: computed(() => (selected.value ? playlistDirectory(selected.value.path) : "")),
  directoryLoading, directoryError, directoryNextCursor,
  controlsHidden: playerControlsHidden,
  setDirectVideoRef: (el) => { player.value = el; },
  setHlsVideoRef: (el) => { hlsPlayer.value = el; },
  setControlsHidden: (hidden) => { playerControlsHidden.value = hidden; },
  setMenuOpen: (openState) => { playerMenuOpen.value = openState; },
  togglePlaylist: onPlayerPlaylistToggle,
  onLoadedMetadata: loaded,
  onTimeUpdate: tick,
  onBufferProgress: refreshBufferedProgress,
  onMediaState: () => { syncVideoMediaState(); syncFullscreenState(); },
  onPauseSave: () => { void save(); },
  onEnded: () => void playbackEnded(),
  onDirectError: () => { playError.value = "浏览器无法解码该视频格式，可切换在线转码或下载原片使用 IINA / VLC 播放。"; },
  onHlsError: () => { playError.value = playError.value || "转码播放出错，可重新尝试或下载原片。"; },
  onCaptionLoad: captionLoaded,
  togglePlay: () => void togglePlayPause(),
  jump: (d) => { showOsd(d > 0 ? `⏩ +${d}s` : `⏪ ${d}s`); void jumpPlayback(d); },
  seek: (pos) => void seekAbsolute(pos),
  setVolume,
  toggleMute,
  selectCaption: (val) => { caption.value = val; void changeCaption(); },
  selectLocalSubtitle: (file) => void loadLocalSubtitleFile(file),
  clearLocalSubtitle,
  setSubtitleSize,
  adjustSubtitleOffset,
  resetSubtitleOffset,
  selectAudio: (idx) => void switchAudioTrack(idx),
  selectQuality: (q) => void switchQuality(q),
  selectRate: setPlaybackRate,
  toggleAutoplay: setAutoplayNext,
  toggleLocalDecode: setPreferLocalDecode,
  toggleFill: toggleFillScreen,
  togglePip: () => void toggleCinemaPictureInPicture(),
  toggleFullscreen: () => void toggleCinemaFullscreen(cinemaDialog.value),
  startTranscode: () => {
    const film = selected.value;
    if (film) void startTranscode(film, film.position > 5 && !film.completed ? film.position : 0, 0);
  },
  download: () => { if (selected.value) download(selected.value); },
  switchPlaylistFilm: (film) => void switchPlaylistFilm(film, true),
  prevPlaylist: () => { if (prevPlaylistFilm.value) void switchPlaylistFilm(prevPlaylistFilm.value, true); },
  nextPlaylist: () => { if (nextPlaylistFilm.value) void switchPlaylistFilm(nextPlaylistFilm.value, true); },
  reloadPlaylist: (append) => { if (selected.value) void loadDirectoryPlaylist(selected.value, append); },
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
      :prefer-local-decode="preferLocalDecode"
      @toggle-trash-mode="choosingTrash = !choosingTrash; trashIDs = new Set()"
      @start-scan="startScan"
      @filter="filter"
      @switch-view="switchView"
      @open-mount-guide="emit('open-mount-guide')"
      @open-scraping-settings="openScrapingFlow"
      @toggle-prefer-local-decode="setPreferLocalDecode"
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
      @poster-error="onPosterError"
    />
    <CinemaBrowseGrids />

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
          <CinemaDetailMetadataPanels v-if="!viewerPlaying" />
          <CinemaPlayerStage v-if="viewerPlaying" ref="playerStageRef" />
        </section>
      </div>
      </Transition>
    </Teleport>
  </div>
</template>
