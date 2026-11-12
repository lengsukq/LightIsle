<script setup lang="ts">
import { handleCinemaKeydown } from "./cinemaKeyboard.ts";
import { createVisibleMediaPolling } from "./visibleMediaPolling.ts";
import { ref, onMounted, onBeforeUnmount, onUnmounted, watch, nextTick } from "vue";
import { describeRootOperationFailure } from "./rootDiscovery.ts";
import { describeUserFacingError } from "./userFacingError.ts";
import { createScopedRootApi } from "./apiClient.ts";
import { Clapperboard, Film, Tv, Play, Download, Search, RefreshCcw, X, Pencil, Wand2, RotateCcw, Trash2 } from "lucide-vue-next";
import { rootApiPath, rootMediaPath } from "./rootApi.ts";
import CinemaPlayerStage from "./CinemaPlayerStage.vue";
import CinemaTmdbPanel from "./CinemaTmdbPanel.vue";
import CinemaHomeShelvesSection from "./CinemaHomeShelvesSection.vue";
import CinemaDetailMetadataPanels from "./CinemaDetailMetadataPanels.vue";
import { useCinemaPlayback } from "./useCinemaPlayback.ts";
import { duration, percent, useCinemaMetadata } from "./useCinemaMetadata.ts";
import { useCinemaSeriesAndHistory } from "./useCinemaSeriesAndHistory.ts";
import { useCinemaDirectoryPlaylist } from "./useCinemaDirectoryPlaylist.ts";
import { useCinemaCatalogController } from "./composables/useCinemaCatalogController.ts";
import { continueAfterPlaybackEnd } from "./cinemaAutoAdvance.ts";
import { confirmCinemaExit } from "./cinemaSafeExit.ts";
import { createBrowserMediaBackstack } from "./browserMediaBackstack.ts";
import IsleModal from "./IsleModal.vue";
import IsleButton from "./IsleButton.vue";
import IsleChip from "./IsleChip.vue";
import IsleBanner from "./IsleBanner.vue";
import IsleBadge from "./IsleBadge.vue";
import IsleEmpty from "./IsleEmpty.vue";
import type { Movie } from "./cinemaTypes.ts";

const props = defineProps<{ active?: boolean; admin: boolean; rootId?: string; rootGeneration?: number }>();
const movies = ref<Movie[]>([]);
const mode = ref("all");
const query = ref("");
const actionError = ref("");
const selected = ref<Movie | null>(null);
const viewerPlaying = ref(false);
const showPlayerPlaylist = ref(false);
const playerControlsHidden = ref(false);
const leavingPlayer = ref(false);
const exitSaveBlocked = ref(false);
let mediaBackstack: ReturnType<typeof createBrowserMediaBackstack> | null = null;
const cinemaDialog = ref<HTMLElement | null>(null);
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
  filteredView, emptyTitle, emptyMessage, continueCount, disambiguationBadge, toggleTrashFilm,
  loadHomeShelves, load, retryLoad, trashFilms, trashSelectedFilms, status, startScan,
  clearCatalogForQueryChange, resetCatalogForRootChange, disposeCatalog,
} = useCinemaCatalogController({
  props, movies, mode, query, view, selected, posterFailed, actionError,
  getRootEpoch: () => rootEpoch, isDisposed: () => disposed, api, apiPath,
  onSelectedTrashed: () => close(),
  onScanCompleted: () => { void refreshScrape(); if (view.value === "series") void loadSeries(); },
});

const {
  player, hlsPlayer, caption, playError, hlsSession, hlsStarting,
  playbackRate, autoplayNext, preferLocalDecode, directLocalOverride, playbackPosition, playbackDuration, playbackBuffered, canPictureInPicture, seekPreview,
  progressSaveError, retryProgress, currentFilmProgressUnsaved, refreshProgressSaveError, refreshBufferedProgress, resetPlaybackForFilm, stream, track, download, playback, canAttemptDirect, destroyHls,
  resetPendingSeek, startTranscode, switchAudioTrack, switchQuality, playbackRateOptions,
  captionOptions, audioTrackOptions, currentQuality, cinemaQualityOptions, setPlaybackRate,
  setAutoplayNext, setPreferLocalDecode, activeVideo, loaded, save, tick, resetProgressClock, changeCaption, captionSrclang,
  jumpPlayback, seekAbsolute, toggleCinemaFullscreen, toggleCinemaPictureInPicture, transcodeErrorMessage,
  isPlaying, volume, isMuted, fillScreen, isFullscreen, syncVideoMediaState, togglePlayPause, setVolume, toggleMute, toggleFillScreen, syncFullscreenState,
} = useCinemaPlayback({ selected, movies, props, api, apiPath, mediaPath });

const {
  candidatePosterFailed, scraping, scrapeMessage, tmdbQuery, tmdbToken, tmdbMatches, tmdbBusy, tmdbError, batchToken, batchBusy, batchError, batchProgress, batchCandidates,
  doubanQuery, doubanMatches, doubanBusy, doubanError, scrapeState, scrapeBusy, scrapeNotice, scrapeError, cancelBatch, suggestBatch, acceptBatchCandidate,
  searchDouban, matchDouban, rename, importLocalNFO, searchTMDB, matchTMDB, refreshScrape, startScrape, resetMetadataForOpen, resetMetadataForClose, resetMetadataForRootChange, disposeMetadata,
} = useCinemaMetadata({
  isAdmin: () => props.admin, getRootId: () => props.rootId, getRootGeneration: () => props.rootGeneration ?? 0, getRootEpoch: () => rootEpoch, isDisposed: () => disposed,
  movies, selected, posterFailed, actionError, api, apiPath, load: (reset) => load(reset), transcodeErrorMessage,
});

const {
  matchingSeries, seriesSearchLoading, seriesSearchError, historyFilms, historyLoading, historyError, seriesList, seriesLoading, seriesError, seriesDetail, seriesDetailLoading, seriesDetailError,
  seriesTmdbId, seriesTmdbBusy, seriesTmdbMessage, resetSeriesSearch, searchForSeries, loadHistory, clearHistory, markWatched, findNextEpisode, loadSeries, switchView, openSeries,
  finishCloseSeries, closeSeries, seasonNumbers, continueSeries, matchSeriesTMDB, resetSeriesAndHistoryForRootChange, disposeSeriesAndHistory,
} = useCinemaSeriesAndHistory({
  isAdmin: () => props.admin, getRootEpoch: () => rootEpoch, isDisposed: () => disposed, query, view, movies, selected, scrapeMessage, seriesDialog, api, apiPath,
  load: (reset) => load(reset), open: (v, autoStart) => open(v, autoStart), getMediaBackstack: () => mediaBackstack,
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

function resetFilters() {
  mode.value = "all"; query.value = "";
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

function keydown(event: KeyboardEvent) {
  if (props.active === false) return;
  const playing = selected.value !== null && viewerPlaying.value;
  handleCinemaKeydown(event, {
    dialog: selected.value ? cinemaDialog.value : seriesDetail.value ? seriesDialog.value : null,
    playing, playlistOpen: showPlayerPlaylist.value,
    showControls: () => { playerControlsHidden.value = false; },
    jump: (seconds) => void jumpPlayback(seconds), togglePlay: () => void togglePlayPause(),
    closePlaylist: () => { showPlayerPlaylist.value = false; },
    close: () => selected.value ? (playing ? returnToOverview() : close()) : closeSeries(),
  });
}

const setScanPolling = createVisibleMediaPolling(status, 5000);
function syncCinemaActiveBindings(active: boolean) {
  setScanPolling(active);
  if (active) window.addEventListener("keydown", keydown);
  else window.removeEventListener("keydown", keydown);
}

onMounted(() => {
  disposed = false;
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
  disposed = true; rootEpoch += 1; rootScopeAbort.abort(); syncCinemaActiveBindings(false); resetDirectoryPlaylist();
  mediaBackstack?.dispose(); mediaBackstack = null; playbackGeneration += 1; disposeSeriesAndHistory();
  if (searchTimer) clearTimeout(searchTimer); selectedController?.abort(); disposeMetadata(); destroyHls(); disposeCatalog();
});
</script>

<template>
  <div class="content cinema-view">
    <div class="section-heading cinema-header-bar">
      <div><h2>私人影院</h2><p>选择想看的作品，或者从上次的位置继续观看。</p></div>
      <div class="cinema-header-actions">
        <label class="cinema-search"><Search :size="15"/><input v-model="query" maxlength="120" type="search" placeholder="搜索电影、剧集或单集…" aria-label="搜索电影、剧集或单集"/><button v-if="query" type="button" title="清除搜索" @click="query=''"><X :size="14"/></button></label>
        <button v-if="(admin||movies.some(movie=>movie.canWrite===true))&&view==='films'&&mode!=='history'" type="button" class="dl-btn" :class="{chosen:choosingTrash}" :disabled="deleting" @click="choosingTrash=!choosingTrash;trashIDs=new Set()">{{choosingTrash?"退出多选":"多选"}}</button>
        <button v-if="admin" class="refresh" :disabled="scan.running&&!scanStatusError" @click="startScan"><RefreshCcw :size="15" :class="{spinning: scan.running&&!scanStatusError}"/>{{scan.running&&!scanStatusError?"扫描中…":"扫描影视库"}}</button>
      </div>
    </div>
    <div class="cinema-tools cinema-navigation">
      <div class="cinema-tabs" role="group" aria-label="影视分类与观看记录">
        <IsleChip :selected="view==='films'&&mode==='all'" @select="filter('all')"><template #icon><Clapperboard :size="15"/></template>首页</IsleChip>
        <IsleChip :selected="view==='films'&&mode==='movie'" @select="filter('movie')"><template #icon><Film :size="15"/></template>电影</IsleChip>
        <IsleChip :selected="view==='series'" @select="switchView('series')"><template #icon><Tv :size="15"/></template>剧集</IsleChip>
        <IsleChip :selected="mode==='continue'&&view==='films'" @select="filter('continue')"><template #icon><Play :size="15"/></template>继续观看</IsleChip>
        <IsleChip :selected="mode==='history'&&view==='films'" @select="filter('history')">观看历史</IsleChip>
        <IsleChip :selected="view==='films'&&mode==='unmatched'" @select="filter('unmatched')"><template #icon><Wand2 :size="15"/></template>待匹配</IsleChip>
      </div>
    </div>
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
    <div v-if="choosingTrash&&view==='films'&&mode!=='history'" class="cinema-batch-hud" role="group" aria-label="已选择影片的操作">
      <span>已选 {{trashIDs.size}} 部（最多50部）</span>
      <IsleButton variant="glass" size="sm" :disabled="deleting" @click="trashIDs=new Set(movies.filter(movie=>admin||movie.canWrite===true).slice(0,50).map(movie=>movie.id))">全选可删除影片</IsleButton>
      <IsleButton v-if="trashIDs.size" variant="ghost" size="sm" :disabled="deleting" @click="trashIDs=new Set()">清空选择</IsleButton>
      <IsleButton variant="danger" size="sm" :disabled="deleting||!trashIDs.size" @click="trashSelectedFilms"><template #icon><Trash2 :size="14"/></template>移入回收站</IsleButton>
      <IsleButton variant="primary" size="sm" :disabled="deleting" @click="choosingTrash=false;trashIDs=new Set()"><template #icon><X :size="14"/></template>完成</IsleButton>
    </div>
    <p v-if="view==='films'&&mode==='continue'&&continueCount" class="cinema-hint">当前列表有 {{continueCount}} 部作品可继续观看</p>
    <CinemaHomeShelvesSection
      v-if="view==='films'&&mode==='all'&&!query.trim()&&!choosingTrash"
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
      @filter-mode="filter"
      @poster-error="(id) => { posterFailed[id] = true }"
    />
    <section v-if="query.trim()" class="cinema-home-section" aria-label="影视搜索结果">
      <div class="cinema-home-heading"><h3>剧集匹配</h3><small v-if="seriesSearchLoading" role="status">正在搜索剧集…</small></div>
      <p v-if="seriesSearchError" class="cinema-alert" role="alert">搜索剧集失败：{{seriesSearchError}} <button type="button" class="account-action" @click="searchForSeries(query.trim())">重试</button></p>
      <div v-if="matchingSeries.length" class="cinema-home-rail" role="group" aria-label="匹配的完整剧集">
        <button v-for="item in matchingSeries" :key="item.id" type="button" class="cinema-home-card" :aria-label="'查看剧集 '+item.name" @click="openSeries(item)">
          <span class="cinema-home-cover"><img v-if="item.posterURL" :src="item.posterURL" :alt="item.name+'海报'" loading="lazy"/><Tv v-else :size="32"/></span>
          <strong :title="item.name">{{item.name}}</strong><small>{{item.episodeCount}} 集 · {{item.year||'年份未知'}}</small>
        </button>
      </div>
      <p v-else-if="!seriesSearchLoading&&!seriesSearchError" class="cinema-hint">没有匹配的完整剧集，可继续查看下方影片和单集。</p>
      <div class="cinema-home-heading"><h3>影片与单集匹配</h3></div>
    </section>
    <div v-if="view==='series'" class="cinema-tools">
      <span v-if="seriesLoading" class="cinema-hint" role="status">正在读取剧集库…</span>
      <span v-else-if="seriesError" class="cinema-alert" role="alert">剧集库读取失败：{{seriesError}} <button type="button" class="account-action" @click="loadSeries">重试</button></span>
      <span v-else-if="!seriesList.length" class="cinema-hint">暂无可聚合剧集；放入含剧集编号的视频并扫描后自动聚合。</span>
      <span v-else class="cinema-hint">共 {{seriesList.length}} 部剧集</span>
    </div>
    <div v-if="view==='series'&&seriesList.length" class="cinema-grid">
      <article v-for="item in seriesList" :key="item.id" class="cinema-tile">
        <button class="cinema-poster" :aria-label="'查看剧集 '+item.name" @click="openSeries(item)">
          <img v-if="item.posterURL" :src="item.posterURL" :alt="item.name+'海报'" class="cinema-poster-image"/>
          <template v-else><Tv :size="44"/></template>
          <span class="cinema-play"><Play v-if="item.nextFilmId" :size="18" fill="currentColor"/><Tv v-else :size="18"/></span>
          <span class="cinema-label">{{item.year||"剧集"}}</span>
        </button>
        <div class="cinema-details">
          <strong :title="item.name">{{item.name}}</strong>
          <small>已看 {{item.watchedCount}}/{{item.episodeCount}} 集</small>
          <IsleBadge v-if="item.inProgress&&item.nextTitle" variant="accent" size="sm">继续：{{item.nextTitle}}</IsleBadge>
          <IsleBadge v-else-if="item.watchedCount>=item.episodeCount&&item.episodeCount" variant="online" size="sm">已看完</IsleBadge>
          <button v-if="item.nextFilmId" @click="continueSeries(item)" title="继续观看"><Play :size="14"/></button>
        </div>
      </article>
    </div>
    <IsleEmpty
      v-if="view==='films'&&mode!=='history'&&!movies.length&&(loadError||actionError||scanActionError||scanStatusError||scanStatusLoaded&&scan.lastError)"
      :icon="Clapperboard" :icon-size="44"
      :title="loadError?'暂时无法读取影视库':actionError?'操作未完成':scanActionError?'扫描无法启动':scanStatusError?'无法确认扫描状态':'上次扫描未完成'"
      :description="loadError?'加载影视库失败：'+loadError:actionError||scanActionError||(scanStatusError?'扫描状态暂不可用：'+scanStatusError:'上次扫描未完成：'+describeUserFacingError(scan.lastError))"
      role="alert"
    >
      <template #action>
        <IsleButton v-if="loadError" variant="tonal" size="sm" :disabled="loading" @click="retryLoad">重试读取影视库</IsleButton>
        <IsleButton v-if="scanStatusError" variant="tonal" size="sm" :disabled="scanStatusLoading" @click="status">重试读取扫描状态</IsleButton>
        <IsleButton v-if="admin&&(!loadError||scanActionError||scan.lastError)" variant="tonal" size="sm" :disabled="scan.running&&!scanStatusError" @click="startScan">重新扫描</IsleButton>
      </template>
    </IsleEmpty>
    <IsleEmpty
      v-else-if="view==='films'&&mode!=='history'&&!movies.length&&(loading||!pageLoaded||!scanStatusLoaded&&!scanStatusError||scan.running&&!scanStatusError)"
      :icon="Clapperboard" :icon-size="44"
      :title="scan.running&&!scanStatusError?'正在扫描影视库…':!scanStatusLoaded&&!scanStatusError?'正在确认扫描状态…':'正在读取影视库…'"
      description="正在检查 Mac 授权的共享目录。"
    />
    <IsleEmpty
      v-else-if="view==='films'&&mode!=='history'&&!movies.length&&!(query.trim()&&matchingSeries.length)"
      :icon="Clapperboard" :icon-size="44" :title="emptyTitle" :description="emptyMessage"
    >
      <template v-if="filteredView" #action>
        <IsleButton variant="tonal" size="sm" @click="resetFilters">查看全部影片</IsleButton>
      </template>
    </IsleEmpty>
    <div v-if="view==='films'&&mode==='history'" class="cinema-tools">
      <span v-if="historyLoading" class="cinema-hint" role="status">正在读取历史记录…</span>
      <span v-else-if="historyError" class="cinema-alert" role="alert">历史读取失败：{{historyError}} <button type="button" class="account-action" @click="loadHistory(true)">重试</button></span>
      <span v-else-if="!historyFilms.length" class="cinema-hint">还没有观看记录；播放过的影片和剧集会按时间出现在这里。</span>
      <span v-else class="cinema-hint">共 {{historyFilms.length}} 条记录（仅当前账号可见） <button type="button" class="account-action" @click="clearHistory">清空历史</button></span>
    </div>
    <div v-if="view==='films'&&mode==='history'" class="cinema-grid">
      <article v-for="movie in historyFilms" :key="movie.id" class="cinema-tile">
        <button class="cinema-poster" @click="open(movie,true)">
          <img v-if="(movie.posterURL||posterReady(movie))&&!posterFailed[movie.id]" :src="poster(movie)" :alt="movie.title+'海报'" class="cinema-poster-image" @error="posterFailed[movie.id]=true"/>
          <template v-else><Tv v-if="movie.kind==='series'" :size="44"/><Film v-else :size="44"/></template>
          <span class="cinema-play"><Play :size="18" fill="currentColor"/></span>
          <span class="cinema-label">{{movie.updatedAt?new Date(movie.updatedAt*1000).toLocaleDateString():""}}</span>
          <span class="cinema-watchbar" :style="{width:percent(movie)+'%'}"></span>
        </button>
        <div class="cinema-details">
          <strong :title="movie.title">{{movie.title}}</strong>
          <small>{{movie.completed?"已看完":"看到 "+percent(movie)+"%"}} · {{duration(movie.durationSeconds||movie.duration)}}</small>
          <button v-if="movie.position>5&&!movie.completed" @click="markWatched(movie,false);open(movie,true)" title="从头播放"><RotateCcw :size="14"/></button>
        </div>
      </article>
    </div>
    <div v-if="view==='films'&&mode==='all'&&!query.trim()&&!choosingTrash&&movies.length&&(featuredFilm||continueShelf.length||showRecentShelf)" class="cinema-home-heading cinema-all-heading"><h3>全部影片</h3><small class="cinema-hint-inline">共 {{next?movies.length+'+':movies.length}} 部</small></div>
    <div v-if="view==='films'&&mode!=='history'" class="cinema-grid">
      <article v-for="movie in movies" :key="movie.id" class="cinema-tile">
        <button class="cinema-poster" :aria-label="choosingTrash?'选择 '+movie.title:'查看影片 '+movie.title"
          :aria-pressed="choosingTrash?trashIDs.has(movie.id):undefined"
          :style="choosingTrash&&trashIDs.has(movie.id)?{outline:'3px solid var(--accent-primary)'}:undefined"
          @click="choosingTrash?toggleTrashFilm(movie.id):open(movie)">
          <img v-if="(movie.posterURL||posterReady(movie))&&!posterFailed[movie.id]" :src="poster(movie)" :alt="movie.title+'海报'" class="cinema-poster-image" @error="posterFailed[movie.id]=true"/>
          <template v-else><Tv v-if="movie.kind==='series'" :size="44"/><Film v-else :size="44"/></template>
          <span class="cinema-play"><Download v-if="playback(movie)==='download-only'" :size="18"/><Play v-else :size="18" fill="currentColor"/></span>
          <span v-if="disambiguationBadge(movie)" class="cinema-scope-label">{{disambiguationBadge(movie)}}</span>
          <span class="cinema-label">{{movie.kind==='series'?'S'+movie.season+'E'+movie.episode:(movie.year||'电影')}}</span>
          <span v-if="choosingTrash" class="cinema-label" style="left:auto;right:8px">{{trashIDs.has(movie.id)?"✓":"○"}}</span>
          <span class="cinema-watchbar" :style="{width:percent(movie)+'%'}"></span>
        </button>
        <div class="cinema-details">
          <strong :title="movie.title">{{movie.title}}</strong>
          <small>{{movie.kind==='series'?'剧集':'电影'}} · {{duration(movie.durationSeconds||movie.duration)}}<template v-if="disambiguationBadge(movie)"> · {{disambiguationBadge(movie)}}</template><template v-if="movie.completed"> · 已看完</template><template v-else-if="movie.position>5"> · 已看 {{percent(movie)}}%</template></small>
          <IsleBadge v-if="mode==='unmatched'&&!movie.metadataSource" variant="warning" size="sm">{{movie.scrapeState==='miss'?'自动未命中 · 待手动匹配':'待匹配资料'}}</IsleBadge>
          <button v-if="admin" @click="rename(movie)" title="修改展示名称"><Pencil :size="14"/></button>
          <button v-if="(admin||movie.canWrite===true)&&!choosingTrash" :disabled="deleting" @click="trashFilms([movie])" title="移入回收站"><Trash2 :size="14"/></button>
        </div>
      </article>
    </div>
    <div v-if="view==='films'&&mode!=='history'" class="cinema-more"><button v-if="next" :disabled="loading" @click="load()">{{loading?"正在加载…":"加载更多作品"}}</button><span v-else-if="movies.length">已展示全部 {{movies.length}} 部作品</span></div>
    <details class="cinema-foot"><summary>播放兼容性说明</summary><p>优先原画直出；浏览器不兼容时可在线转码（需 FFmpeg，不改动原片）或下载后用本地播放器打开。</p></details>

    <Teleport to="body">
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
            @restart-from-beginning="markWatched(selected, false); open(selected, true)"
            @import-local-nfo="importLocalNFO(selected)"
          />
          <CinemaPlayerStage
            v-if="viewerPlaying" :selected="selected" :can-direct="canAttemptDirect(selected)"
            :stream-url="stream(selected)" :track-url="track(selected)" :caption="caption" :caption-srclang="captionSrclang()"
            :caption-options="captionOptions" :audio-track-options="audioTrackOptions" :quality-options="cinemaQualityOptions"
            :current-quality="currentQuality" :playback-rate="playbackRate" :playback-rate-options="playbackRateOptions"
            :hls-session="hlsSession" :hls-starting="hlsStarting" :play-error="playError" :is-playing="isPlaying"
            :volume="volume" :is-muted="isMuted" :fill-screen="fillScreen" :is-fullscreen="isFullscreen"
            :can-picture-in-picture="canPictureInPicture" :playback-position="playbackPosition" :playback-duration="playbackDuration" :playback-buffered="playbackBuffered"
            :seek-preview="seekPreview" :autoplay-next="autoplayNext" :prefer-local-decode="preferLocalDecode"
            :leaving-player="leavingPlayer" :show-player-playlist="showPlayerPlaylist" :same-directory-films="sameDirectoryFilms"
            :current-playlist-index="currentPlaylistIndex" :has-prev-playlist="!!prevPlaylistFilm" :has-next-playlist="!!nextPlaylistFilm"
            :playlist-dir-label="playlistDirectory(selected.path)" :directory-loading="directoryLoading" :directory-error="directoryError"
            :directory-next-cursor="directoryNextCursor" :controls-hidden="playerControlsHidden"
            :set-direct-video-ref="(el) => { player = el }" :set-hls-video-ref="(el) => { hlsPlayer = el }"
            @update:controls-hidden="playerControlsHidden = $event" @update:seek-preview="seekPreview = $event"
            @update:show-player-playlist="onPlayerPlaylistToggle" @loadedmetadata="loaded" @timeupdate="tick" @buffer-progress="refreshBufferedProgress"
            @media-state="syncVideoMediaState(); syncFullscreenState()" @pause-save="save()" @ended="playbackEnded"
            @direct-error="playError = '浏览器无法解码该视频格式，可切换在线转码或下载原片使用 IINA / VLC 播放。'"
            @hls-error="playError = playError || '转码播放出错，可重新尝试或下载原片。'"
            @caption-load="changeCaption" @toggle-play="togglePlayPause" @jump="jumpPlayback" @seek="seekAbsolute"
            @set-volume="setVolume" @toggle-mute="toggleMute"
            @select-caption="(val) => { caption = val; void changeCaption() }"
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
    </Teleport>
    <Teleport to="body">
      <div v-if="seriesDetail && props.active !== false">
        <IsleModal
          :title="seriesDetail.series.name"
          :description="(seriesDetail.series.year || '剧集') + ' · 已看 ' + seriesDetail.series.watchedCount + '/' + seriesDetail.series.episodeCount + ' 集' + (seriesDetail.series.tmdbId ? ' · TMDB' : '')"
          size="wide"
          role="dialog"
          :aria-label="seriesDetail.series.name + ' · 剧集列表'"
          @close="closeSeries"
        >
          <template #icon><Tv :size="18" /></template>
          <p v-if="seriesDetail.series.overview" class="cinema-synopsis">{{ seriesDetail.series.overview }}</p>
          <IsleBanner v-if="seriesDetailLoading" type="info" compact message="正在读取剧集分集…" style="margin-bottom:10px" />
          <IsleBanner v-if="seriesDetailError" type="error" compact :message="seriesDetailError" style="margin-bottom:10px" />
          <div v-for="season in seasonNumbers(seriesDetail.films)" :key="season" class="cinema-season">
            <h4>第 {{ season }} 季</h4>
            <button v-for="episode in seriesDetail.films.filter(f => f.season === season)" :key="episode.id" class="cinema-episode" @click="open(episode, true)">
              <span class="cinema-episode-no">E{{ episode.episode }}</span>
              <span class="cinema-episode-title">{{ episode.title }}</span>
              <span class="cinema-episode-meta">{{ duration(episode.durationSeconds || episode.duration) }}</span>
              <IsleBadge v-if="episode.completed" variant="online" size="sm">已看完</IsleBadge>
              <IsleBadge v-else-if="episode.position > 5" variant="accent" size="sm">已看 {{ percent(episode) }}%</IsleBadge>
            </button>
          </div>
          <p v-if="seriesTmdbMessage" class="cinema-alert" role="status">{{ seriesTmdbMessage }}</p>
          <details v-if="admin" class="cinema-tmdb-panel" style="margin-top:14px">
            <summary>匹配 TMDB 剧集资料（使用 Mac App 配置的 Token）</summary>
            <form class="cinema-tmdb-form" @submit.prevent="matchSeriesTMDB(seriesDetail.series)">
              <input v-model="seriesTmdbId" type="text" inputmode="numeric" placeholder="TMDB 剧集 ID（数字，可在 themoviedb.org 剧集页地址中找到）" :disabled="seriesTmdbBusy"/>
              <IsleButton type="submit" variant="primary" size="sm" :disabled="seriesTmdbBusy">{{ seriesTmdbBusy ? "匹配中…" : "匹配" }}</IsleButton>
            </form>
          </details>
        </IsleModal>
      </div>
    </Teleport>
  </div>
</template>
<style scoped src="./CinemaView.css"></style>
