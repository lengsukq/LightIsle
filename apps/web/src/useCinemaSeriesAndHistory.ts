import { nextTick, ref, type Ref } from "vue";
import { describeRootOperationFailure } from "./rootDiscovery.js";
import { requestConfirm } from "./useConfirmDialog";
import type { createBrowserMediaBackstack } from "./browserMediaBackstack.js";
import type { Movie, SeriesInfo } from "./cinemaTypes.js";

export function useCinemaSeriesAndHistory(options: {
  isAdmin: () => boolean;
  getRootEpoch: () => number;
  isDisposed: () => boolean;
  query: Ref<string>;
  view: Ref<"films" | "series">;
  movies: Ref<Movie[]>;
  selected: Ref<Movie | null>;
  scrapeMessage: Ref<string>;
  seriesDialog: Ref<HTMLElement | null>;
  api: <T>(url: string, method?: string, body?: object, signal?: AbortSignal) => Promise<T>;
  apiPath: (path: string) => string;
  load: (reset?: boolean) => Promise<void>;
  open: (v: Movie, autoStart?: boolean) => Promise<void>;
  getMediaBackstack: () => ReturnType<typeof createBrowserMediaBackstack> | null;
}) {
  const matchingSeries = ref<SeriesInfo[]>([]);
  const seriesSearchLoading = ref(false);
  const seriesSearchError = ref("");
  let seriesSearchGeneration = 0;

  const historyFilms = ref<Movie[]>([]);
  const historyNext = ref(0);
  const historyLoading = ref(false);
  const historyError = ref("");
  const historyLoaded = ref(false);
  let historyGeneration = 0;

  const seriesList = ref<SeriesInfo[]>([]);
  const seriesLoading = ref(false);
  const seriesError = ref("");
  const seriesDetail = ref<{ series: SeriesInfo; films: Movie[] } | null>(null);
  const seriesDetailLoading = ref(false);
  const seriesDetailError = ref("");
  const seriesTmdbId = ref("");
  const seriesTmdbBusy = ref(false);
  const seriesTmdbMessage = ref("");
  let seriesGeneration = 0;
  let seriesDetailGeneration = 0;
  let seriesReturnFocus: HTMLElement | null = null;

  function resetSeriesSearch() {
    seriesSearchGeneration += 1;
    matchingSeries.value = [];
    seriesSearchError.value = "";
    seriesSearchLoading.value = false;
  }

  async function searchForSeries(term: string) {
    const generation = ++seriesSearchGeneration;
    const root = options.getRootEpoch();
    const current = () =>
      !options.isDisposed() &&
      generation === seriesSearchGeneration &&
      root === options.getRootEpoch() &&
      options.query.value.trim() === term;
    seriesSearchLoading.value = true;
    seriesSearchError.value = "";
    try {
      const result = await options.api<{ series: SeriesInfo[] }>(
        options.apiPath("/api/v2/series") + "?" + new URLSearchParams({ limit: "120", query: term }),
      );
      if (current()) matchingSeries.value = result.series;
    } catch (e) {
      if (current() && !(e instanceof Error && e.name === "AbortError")) {
        seriesSearchError.value = describeRootOperationFailure(e);
      }
    } finally {
      if (current()) seriesSearchLoading.value = false;
    }
  }

  async function loadHistory(reset = false) {
    if (historyLoading.value) return;
    const generation = ++historyGeneration;
    const root = options.getRootEpoch();
    const current = () => !options.isDisposed() && generation === historyGeneration && root === options.getRootEpoch();
    historyLoading.value = true;
    historyError.value = "";
    try {
      const query = new URLSearchParams({ limit: "48", cursor: String(reset ? 0 : historyNext.value) });
      const page = await options.api<{ films: Movie[]; nextCursor: number }>(
        options.apiPath("/api/v2/cinema/history") + "?" + query.toString(),
      );
      if (!current()) return;
      historyFilms.value = reset ? page.films : [...historyFilms.value, ...page.films];
      historyNext.value = page.nextCursor;
      historyLoaded.value = true;
    } catch (e) {
      if (current() && !(e instanceof Error && e.name === "AbortError")) {
        historyError.value = describeRootOperationFailure(e);
      }
    } finally {
      if (current()) historyLoading.value = false;
    }
  }

  async function clearHistory() {
    if (
      !(await requestConfirm({
        title: "清空观看历史",
        message: "清空全部观看历史与各影片的续播进度？该操作只影响当前账号，且不可撤销。",
        confirmText: "确认清空",
        variant: "danger",
      }))
    )
      return;
    try {
      await options.api(options.apiPath("/api/v2/cinema/history"), "DELETE");
      historyFilms.value = [];
      historyNext.value = 0;
      options.movies.value = options.movies.value.map((item) => ({ ...item, position: 0, completed: false }));
      await options.load(true);
    } catch (e) {
      historyError.value = describeRootOperationFailure(e);
    }
  }

  async function markWatched(v: Movie, completed: boolean) {
    try {
      const updated = await options.api<Movie>(options.apiPath("/api/v2/cinema/" + v.id + "/watched"), "POST", {
        completed,
      });
      if (options.selected.value?.id === v.id) options.selected.value = updated;
      options.movies.value = options.movies.value.map((item) => (item.id === v.id ? { ...item, ...updated } : item));
      historyFilms.value = historyFilms.value
        .map((item) => (item.id === v.id ? { ...item, ...updated } : item))
        .filter((item) => item.id !== v.id || item.position > 5 || item.completed);
      options.scrapeMessage.value = completed ? "已标记为看完。" : "已标记为未看，续播进度已重置。";
    } catch (e) {
      options.scrapeMessage.value = "标记失败：" + describeRootOperationFailure(e);
    }
  }

  async function findNextEpisode(film: Movie): Promise<Movie | null> {
    if (film.kind !== "series" || !film.series || film.season < 0) return null;
    try {
      const matching =
        seriesDetail.value?.series.name === film.series
          ? [seriesDetail.value.series]
          : seriesList.value.filter((item) => item.name === film.series);
      const candidates = matching.length
        ? matching
        : (await options.api<{ series: SeriesInfo[] }>(options.apiPath("/api/v2/series") + "?limit=60")).series.filter(
            (item) => item.name === film.series,
          );
      if (candidates.length !== 1) return null;
      const detail =
        seriesDetail.value?.series.id === candidates[0].id
          ? seriesDetail.value
          : await options.api<{ series: SeriesInfo; films: Movie[] }>(
              options.apiPath("/api/v2/series/" + candidates[0].id),
            );
      const episodes = detail.films.slice().sort((a, b) => a.season - b.season || a.episode - b.episode || a.id - b.id);
      const index = episodes.findIndex((item) => item.id === film.id);
      return index >= 0 ? episodes[index + 1] ?? null : null;
    } catch {
      return null;
    }
  }

  async function loadSeries() {
    if (seriesLoading.value) return;
    const generation = ++seriesGeneration;
    const root = options.getRootEpoch();
    const current = () => !options.isDisposed() && generation === seriesGeneration && root === options.getRootEpoch();
    seriesLoading.value = true;
    seriesError.value = "";
    try {
      const page = await options.api<{ series: SeriesInfo[] }>(options.apiPath("/api/v2/series") + "?limit=60");
      if (!current()) return;
      seriesList.value = page.series;
    } catch (e) {
      if (current() && !(e instanceof Error && e.name === "AbortError")) {
        seriesError.value = describeRootOperationFailure(e);
      }
    } finally {
      if (current()) seriesLoading.value = false;
    }
  }

  function switchView(target: "films" | "series") {
    if (options.query.value) options.query.value = "";
    options.view.value = target;
    if (target === "series") void loadSeries();
    else void options.load(true);
  }

  async function openSeries(item: SeriesInfo) {
    seriesReturnFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    const generation = ++seriesDetailGeneration;
    const root = options.getRootEpoch();
    const current = () =>
      !options.isDisposed() && generation === seriesDetailGeneration && root === options.getRootEpoch();
    seriesDetailLoading.value = true;
    seriesDetailError.value = "";
    seriesTmdbMessage.value = "";
    seriesTmdbId.value = "";
    try {
      const detail = await options.api<{ series: SeriesInfo; films: Movie[] }>(
        options.apiPath("/api/v2/series/" + item.id),
      );
      if (current()) {
        options.getMediaBackstack()?.push();
        seriesDetail.value = detail;
        void nextTick(() => options.seriesDialog.value?.focus());
      }
    } catch (e) {
      if (current() && !(e instanceof Error && e.name === "AbortError")) {
        seriesDetailError.value = describeRootOperationFailure(e);
      }
    } finally {
      if (current()) seriesDetailLoading.value = false;
    }
  }

  function finishCloseSeries() {
    seriesDetailGeneration += 1;
    seriesDetailLoading.value = false;
    seriesDetail.value = null;
    seriesDetailError.value = "";
    seriesTmdbMessage.value = "";
    seriesTmdbId.value = "";
    const target = seriesReturnFocus;
    seriesReturnFocus = null;
    void nextTick(() => {
      if (target?.isConnected) target.focus();
    });
  }

  function closeSeries() {
    if (options.getMediaBackstack()?.back()) return;
    finishCloseSeries();
  }

  function seasonNumbers(films: Movie[]) {
    return Array.from(new Set(films.map((f) => f.season))).sort((a, b) => a - b);
  }

  async function continueSeries(item: SeriesInfo) {
    if (!item.nextFilmId) return;
    const film = seriesDetail.value?.films.find((f) => f.id === item.nextFilmId);
    // Preserve the season/episode page underneath the active episode, so Back
    // returns to the user's season rather than the library root.
    if (film) {
      await options.open(film, true);
      return;
    }
    // Not in the loaded detail — open by id via a minimal movie stub so the
    // player still starts; the dialog refreshes metadata on its own.
    await options.open(
      {
        id: item.nextFilmId,
        title: item.nextTitle || item.name,
        path: "",
        kind: "series",
        series: item.name,
        season: 0,
        episode: 0,
        year: item.year || 0,
        size: 0,
        position: item.position || 0,
        duration: item.duration || 0,
        completed: false,
      },
      true,
    );
  }

  async function matchSeriesTMDB(item: SeriesInfo) {
    if (!options.isAdmin() || seriesTmdbBusy.value) return;
    const parsed = Number.parseInt(seriesTmdbId.value, 10);
    if (!Number.isFinite(parsed) || parsed < 1) {
      seriesTmdbMessage.value = "请输入有效的 TMDB 剧集 ID（数字）。";
      return;
    }
    seriesTmdbBusy.value = true;
    seriesTmdbMessage.value = "";
    try {
      const updated = await options.api<{ series: SeriesInfo }>(
        options.apiPath("/api/v2/series/" + item.id + "/metadata/tmdb/match"),
        "POST",
        { tmdbId: parsed },
      );
      if (seriesDetail.value && seriesDetail.value.series.id === item.id) {
        seriesDetail.value = {
          ...seriesDetail.value,
          series: { ...seriesDetail.value.series, ...updated.series },
        };
      }
      seriesList.value = seriesList.value.map((s) => (s.id === item.id ? { ...s, ...updated.series } : s));
      seriesTmdbId.value = "";
      seriesTmdbMessage.value = "已更新剧集资料（海报/简介）。";
    } catch (e) {
      const code = e instanceof Error ? e.message : "request_failed";
      seriesTmdbMessage.value =
        code === "tmdb_token_not_configured"
          ? "未配置 TMDB Token：请管理员在 Mac App「偏好与安全」中配置后重试。"
          : code === "series_not_found"
            ? "剧集不存在或已变化，请刷新列表。"
            : "匹配失败：" + code;
    } finally {
      seriesTmdbBusy.value = false;
    }
  }

  function resetSeriesAndHistoryForRootChange() {
    seriesGeneration += 1;
    seriesDetailGeneration += 1;
    historyGeneration += 1;
    resetSeriesSearch();
    seriesList.value = [];
    seriesDetail.value = null;
    seriesError.value = "";
    seriesDetailError.value = "";
    seriesLoading.value = false;
    seriesDetailLoading.value = false;
    historyFilms.value = [];
    historyNext.value = 0;
    historyLoaded.value = false;
    historyError.value = "";
    historyLoading.value = false;
  }

  function disposeSeriesAndHistory() {
    seriesGeneration += 1;
    seriesDetailGeneration += 1;
    historyGeneration += 1;
  }

  return {
    matchingSeries,
    seriesSearchLoading,
    seriesSearchError,
    historyFilms,
    historyNext,
    historyLoading,
    historyError,
    historyLoaded,
    seriesList,
    seriesLoading,
    seriesError,
    seriesDetail,
    seriesDetailLoading,
    seriesDetailError,
    seriesTmdbId,
    seriesTmdbBusy,
    seriesTmdbMessage,
    resetSeriesSearch,
    searchForSeries,
    loadHistory,
    clearHistory,
    markWatched,
    findNextEpisode,
    loadSeries,
    switchView,
    openSeries,
    finishCloseSeries,
    closeSeries,
    seasonNumbers,
    continueSeries,
    matchSeriesTMDB,
    resetSeriesAndHistoryForRootChange,
    disposeSeriesAndHistory,
  };
}
