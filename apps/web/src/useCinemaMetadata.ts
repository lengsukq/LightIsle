import { ref, type Ref } from "vue";
import { describeUserFacingError } from "./userFacingError.js";
import { createLatestRequestGate } from "./latestRequestGate.js";
import { createMediaStatusPoller } from "./mediaStatusPoller.js";
import { tmdbCandidateScore } from "./cinemaCandidateScore.js";
import { isTMDBAuthenticationFailure, runSequentialTMDBBatch } from "./tmdbBatch.js";
import type { BatchCandidate, DoubanCandidate, Movie, TMDBCandidate } from "./cinemaTypes.js";

export function duration(v: number) {
  if (!Number.isFinite(v) || v <= 0) return "时长未知";
  if (v < 60) return Math.ceil(v) + " 秒";
  const min = Math.floor(v / 60);
  return min >= 60 ? Math.floor(min / 60) + "h " + (min % 60) + "m" : min + " 分钟";
}

export function metadataSourceName(value?: string) {
  if (!value) return "文件名自动识别";
  if (value === "manual") return "手动命名";
  if (value === "legacy-confirmed") return "旧版已确认（具体来源未记录）";
  if (value.startsWith("tmdb:")) return "TMDB";
  if (value.startsWith("nfo:")) return "本地 NFO";
  if (value.startsWith("douban-suggest:")) return "豆瓣网页搜索建议";
  return "已确认的其他来源";
}

export function formatLabel(v: Movie) {
  const values = [v.container?.toUpperCase(), v.videoCodec?.toUpperCase(), v.audioCodec?.toUpperCase()].filter(Boolean);
  return values.join(" · ");
}

export function percent(v: Movie) {
  return v.duration ? Math.min(100, Math.round((v.position / v.duration) * 100)) : 0;
}

export function useCinemaMetadata(options: {
  isAdmin: () => boolean;
  getRootId: () => string | undefined;
  getRootGeneration: () => number;
  getRootEpoch: () => number;
  isDisposed: () => boolean;
  movies: Ref<Movie[]>;
  selected: Ref<Movie | null>;
  posterFailed: Ref<Record<number, boolean>>;
  actionError: Ref<string>;
  api: <T>(url: string, method?: string, body?: object, signal?: AbortSignal) => Promise<T>;
  apiPath: (path: string) => string;
  load: (reset?: boolean) => Promise<void>;
  transcodeErrorMessage: (error: unknown) => string;
}) {
  const candidatePosterFailed = ref<Record<number, boolean>>({});
  const scraping = ref(false);
  const scrapeMessage = ref("");
  const tmdbQuery = ref("");
  const tmdbToken = ref("");
  const tmdbMatches = ref<TMDBCandidate[]>([]);
  const tmdbBusy = ref(false);
  const tmdbError = ref("");
  const batchToken = ref("");
  const batchBusy = ref(false);
  const batchError = ref("");
  const batchProgress = ref("");
  const batchCandidates = ref<BatchCandidate[]>([]);
  const doubanQuery = ref("");
  const doubanMatches = ref<DoubanCandidate[]>([]);
  const doubanBusy = ref(false);
  const doubanError = ref("");
  const scrapeState = ref<{
    running: boolean;
    operation: string;
    processed: number;
    matched: number;
    tmdbConfigured: boolean;
  } | null>(null);
  const scrapeBusy = ref(false);
  const scrapeNotice = ref("");
  const scrapeError = ref("");
  const scrapeRetryTried = ref(false);

  let batchController: AbortController | undefined;
  let scrapeTimer: number | undefined;
  const nfoRequests = createLatestRequestGate();
  const tmdbSearchRequests = createLatestRequestGate();
  const tmdbMatchRequests = createLatestRequestGate();
  const doubanSearchRequests = createLatestRequestGate();
  const doubanMatchRequests = createLatestRequestGate();

  function cancelBatch() {
    batchController?.abort();
    batchController = undefined;
    batchBusy.value = false;
    batchToken.value = "";
    batchCandidates.value = [];
    batchProgress.value = "";
  }

  function tmdbErrorMessage(error: unknown) {
    if (isTMDBAuthenticationFailure(error)) {
      return "TMDB 拒绝了该访问令牌或其权限（401/403）。请检查 Read Access Token 是否有效且有访问权限。";
    }
    return describeUserFacingError(error);
  }

  async function suggestBatch() {
    if (!options.isAdmin() || batchBusy.value) return;
    if (batchToken.value.trim().length < 20) {
      batchError.value = "输入自己的 TMDB Read Access Token（仅保留在本页内存）。";
      return;
    }
    const target = options.movies.value.filter((f) => !f.metadataSource && !f.titleSource).slice(0, 8);
    if (!target.length) {
      batchError.value = "当前已加载的列表中没有需要匹配的影片。";
      return;
    }
    const rootID = options.getRootId();
    const generation = options.getRootGeneration();
    batchController?.abort();
    const request = new AbortController();
    batchController = request;
    const fresh = () =>
      !options.isDisposed() &&
      !request.signal.aborted &&
      batchController === request &&
      rootID === options.getRootId() &&
      generation === options.getRootGeneration();
    batchBusy.value = true;
    batchError.value = "";
    batchCandidates.value = [];
    try {
      const result = await runSequentialTMDBBatch(
        target,
        async (film) => {
          const response = await options.api<{ results: TMDBCandidate[] }>(
            options.apiPath("/api/v2/cinema/" + film.id + "/metadata/tmdb/search"),
            "POST",
            { accessToken: batchToken.value, query: film.title },
            request.signal,
          );
          return response.results
            .map((c) => ({ filmId: film.id, filmTitle: film.title, match: c, score: tmdbCandidateScore(film, c) }))
            .sort((a, b) => b.score - a.score);
        },
        {
          isCurrent: fresh,
          onProgress: (film, index, total) => {
            batchProgress.value = `正在分析 ${index + 1}/${total}：${film.title}`;
          },
          onResult: (_film, ranked) => {
            if (ranked.length && ranked[0].score >= 60) batchCandidates.value.push(ranked[0]);
          },
        },
      );
      if (!fresh()) return;
      if (result.status === "auth-rejected") {
        batchToken.value = "";
        batchCandidates.value = [];
        batchError.value =
          "TMDB 拒绝了该访问令牌或其权限（401/403）。已停止后续查询并清除令牌；请检查 Read Access Token 后重试。";
        batchProgress.value = "认证失败，未查询剩余影片。";
      } else if (result.status === "completed") {
        batchError.value = result.hadFailures ? "部分匹配查询失败；可稍后重试。不会自动修改现有影片。" : "";
        batchProgress.value = result.hadFailures
          ? "候选建议已生成；部分影片未能查询。"
          : "匹配建议生成完成；必须逐条确认才会保存。";
      }
    } catch (e) {
      if (fresh()) batchError.value = "批量查询失败：" + tmdbErrorMessage(e);
    } finally {
      if (fresh()) batchBusy.value = false;
    }
  }

  async function acceptBatchCandidate(item: BatchCandidate) {
    if (!options.isAdmin() || batchBusy.value || !batchToken.value) return;
    const film = options.movies.value.find((v) => v.id === item.filmId);
    if (
      !film ||
      !window.confirm("确认将「" + item.match.title + "」的 TMDB 信息写入「" + item.filmTitle + "」？每部影片需独立确认。")
    ) {
      return;
    }
    batchBusy.value = true;
    batchError.value = "";
    try {
      const updated = await options.api<Movie>(
        options.apiPath("/api/v2/cinema/" + item.filmId + "/metadata/tmdb/match"),
        "POST",
        { accessToken: batchToken.value, tmdbId: item.match.id },
      );
      options.movies.value = options.movies.value.map((v) => (v.id === item.filmId ? { ...v, ...updated } : v));
      batchCandidates.value = batchCandidates.value.filter((v) => v.filmId !== item.filmId);
    } catch (e) {
      if (isTMDBAuthenticationFailure(e)) {
        batchToken.value = "";
        batchCandidates.value = [];
        batchError.value =
          "TMDB 拒绝了该访问令牌或其权限（401/403）。已停止后续确认并清除令牌；请检查 Read Access Token 后重试。";
      } else {
        batchError.value = "无法保存「" + item.filmTitle + "」：" + tmdbErrorMessage(e);
      }
    } finally {
      batchBusy.value = false;
    }
  }

  function cancelMetadataRequests() {
    nfoRequests.cancel();
    tmdbSearchRequests.cancel();
    tmdbMatchRequests.cancel();
    doubanSearchRequests.cancel();
    doubanMatchRequests.cancel();
    scraping.value = false;
    tmdbBusy.value = false;
    doubanBusy.value = false;
  }

  async function searchDouban() {
    const film = options.selected.value;
    if (!film || !options.isAdmin() || doubanBusy.value || tmdbBusy.value || scraping.value) return;
    const search = doubanQuery.value.trim();
    if (search.length < 2 || search.length > 60) {
      doubanError.value = "请输入 2–60 个字符的片名。";
      return;
    }
    const filmID = film.id;
    const request = doubanSearchRequests.begin();
    const isCurrent = () => request.isCurrent() && options.selected.value?.id === filmID;
    doubanBusy.value = true;
    doubanMatches.value = [];
    doubanError.value = "";
    try {
      const result = await options.api<{ results: DoubanCandidate[] }>(
        options.apiPath("/api/v2/cinema/" + filmID + "/metadata/douban/search"),
        "POST",
        { query: search },
        request.signal,
      );
      if (isCurrent()) {
        doubanMatches.value = result.results
          .filter((c) => c.kind !== "tv" || film.kind === "series")
          .filter((c) => c.kind !== "movie" || film.kind === "movie");
        if (!doubanMatches.value.length) {
          doubanError.value = "未找到候选资料，或搜索结果不属于当前影片类型。";
        }
      }
    } catch (e) {
      if (isCurrent() && !(e instanceof Error && e.name === "AbortError")) {
        doubanError.value = "豆瓣网页搜索暂不可用（可能限流、拒绝访问或页面调整）。可继续使用 TMDB 或本地 NFO。";
      }
    } finally {
      if (isCurrent()) doubanBusy.value = false;
    }
  }

  async function matchDouban(candidate: DoubanCandidate) {
    const film = options.selected.value;
    if (!film || !options.isAdmin() || doubanBusy.value || tmdbBusy.value || scraping.value) return;
    if (
      !window.confirm(
        "将豆瓣网页搜索建议「" +
          candidate.title +
          "」" +
          (candidate.year ? "（" + candidate.year + "）" : "") +
          "匹配到「" +
          film.title +
          "」？只更新非手动片名和年份，不复制简介、评分或海报，原始文件及观看进度不变。",
      )
    ) {
      return;
    }
    const filmID = film.id;
    const request = doubanMatchRequests.begin();
    const isCurrent = () => request.isCurrent() && options.selected.value?.id === filmID;
    doubanBusy.value = true;
    doubanError.value = "";
    try {
      await options.api(
        options.apiPath("/api/v2/cinema/" + filmID + "/metadata/douban/match"),
        "POST",
        { query: doubanQuery.value.trim(), doubanId: candidate.id },
        request.signal,
      );
      if (!isCurrent()) return;
      const updated = await options.api<Movie>(options.apiPath("/api/v2/cinema/" + filmID), "GET", undefined, request.signal);
      if (isCurrent()) {
        options.selected.value = updated;
        options.movies.value = options.movies.value.map((m) => (m.id === filmID ? { ...m, ...updated } : m));
        doubanMatches.value = [];
        scrapeMessage.value = "已根据网页搜索结果更新片名/年份；简介、评分、海报保持原有来源，不会保存网页副本。";
      }
    } catch (e) {
      if (isCurrent() && !(e instanceof Error && e.name === "AbortError")) {
        doubanError.value = "匹配失败：网页结果可能已变化或不再可访问，请稍后重试。";
      }
    } finally {
      if (isCurrent()) doubanBusy.value = false;
    }
  }

  async function rename(v: Movie) {
    if (!options.isAdmin()) return;
    const title = window.prompt("修改影片展示名称", v.title)?.trim();
    if (!title || title === v.title) return;
    try {
      await options.api(options.apiPath("/api/v2/cinema/" + v.id), "PATCH", { title });
      v.title = title;
    } catch (e) {
      options.actionError.value = describeUserFacingError(e);
    }
  }

  async function importLocalNFO(v: Movie) {
    if (!options.isAdmin() || scraping.value || tmdbBusy.value) return;
    const filmID = v.id;
    const request = nfoRequests.begin();
    const isCurrent = () => request.isCurrent() && options.selected.value?.id === filmID;
    scraping.value = true;
    scrapeMessage.value = "";
    try {
      await options.api<Movie>(options.apiPath("/api/v2/cinema/" + filmID + "/metadata/nfo"), "POST", undefined, request.signal);
      if (!isCurrent()) return;
      const updated = await options.api<Movie>(options.apiPath("/api/v2/cinema/" + filmID), "GET", undefined, request.signal);
      if (!isCurrent()) return;
      options.selected.value = updated;
      options.movies.value = options.movies.value.map((movie) => (movie.id === filmID ? { ...movie, ...updated } : movie));
      scrapeMessage.value = "本地 NFO 资料已导入，原视频与观看进度未修改。";
    } catch (e) {
      if (!isCurrent() || (e instanceof Error && e.name === "AbortError")) return;
      const code = e instanceof Error ? e.message : "request_failed";
      scrapeMessage.value =
        code === "nfo_not_found"
          ? "未找到同名 .nfo 或电影目录下的 movie.nfo。"
          : code === "invalid_nfo"
            ? "NFO 文件内容无效或超出大小限制。"
            : "读取 NFO 失败：" + code;
    } finally {
      if (isCurrent()) scraping.value = false;
    }
  }

  async function searchTMDB() {
    const film = options.selected.value;
    if (!film || !options.isAdmin() || tmdbBusy.value || scraping.value) return;
    if (!tmdbToken.value || !tmdbQuery.value.trim()) {
      tmdbError.value = "请输入自己的 TMDB API Read Access Token 和搜索关键词。";
      return;
    }
    const filmID = film.id;
    const request = tmdbSearchRequests.begin();
    const isCurrent = () => request.isCurrent() && options.selected.value?.id === filmID;
    tmdbBusy.value = true;
    tmdbMatches.value = [];
    candidatePosterFailed.value = {};
    tmdbError.value = "";
    try {
      const result = await options.api<{ results: TMDBCandidate[] }>(
        options.apiPath("/api/v2/cinema/" + filmID + "/metadata/tmdb/search"),
        "POST",
        { accessToken: tmdbToken.value, query: tmdbQuery.value.trim() },
        request.signal,
      );
      if (isCurrent()) {
        tmdbMatches.value = result.results;
        tmdbError.value = result.results.length ? "" : "没有找到相关影片，可调整关键词再试。";
      }
    } catch (e) {
      if (isCurrent() && !(e instanceof Error && e.name === "AbortError")) {
        tmdbError.value = "搜索失败：" + tmdbErrorMessage(e);
      }
    } finally {
      if (isCurrent()) tmdbBusy.value = false;
    }
  }

  async function matchTMDB(candidate: TMDBCandidate) {
    const film = options.selected.value;
    if (!film || !options.isAdmin() || tmdbBusy.value || scraping.value) return;
    if (
      !window.confirm(
        "确认将「" + candidate.title + "」的 TMDB 资料匹配到「" + film.title + "」？将更新简介、评分及海报；手动设置的影片名保持不变。",
      )
    ) {
      return;
    }
    const filmID = film.id;
    const request = tmdbMatchRequests.begin();
    const isCurrent = () => request.isCurrent() && options.selected.value?.id === filmID;
    tmdbBusy.value = true;
    tmdbError.value = "";
    try {
      await options.api<Movie>(
        options.apiPath("/api/v2/cinema/" + filmID + "/metadata/tmdb/match"),
        "POST",
        { accessToken: tmdbToken.value, tmdbId: candidate.id },
        request.signal,
      );
      if (!isCurrent()) return;
      const updated = await options.api<Movie>(options.apiPath("/api/v2/cinema/" + filmID), "GET", undefined, request.signal);
      if (isCurrent()) {
        options.selected.value = updated;
        options.movies.value = options.movies.value.map((item) => (item.id === film.id ? { ...item, ...updated } : item));
        delete options.posterFailed.value[filmID];
        tmdbMatches.value = [];
        tmdbToken.value = "";
        scrapeMessage.value = "已匹配 TMDB 资料；API 凭据已从页面内存清除。";
      }
    } catch (e) {
      if (isCurrent() && !(e instanceof Error && e.name === "AbortError")) {
        tmdbError.value = "保存匹配失败：" + tmdbErrorMessage(e);
      }
    } finally {
      if (isCurrent()) tmdbBusy.value = false;
    }
  }

  function stopScrapeTimer() {
    if (scrapeTimer !== undefined) window.clearInterval(scrapeTimer);
    scrapeTimer = undefined;
  }

  const scrapeStatusPoller = createMediaStatusPoller(
    (signal) =>
      options.api<NonNullable<typeof scrapeState.value>>(
        options.apiPath("/api/v2/cinema/scrape/status"),
        "GET",
        undefined,
        signal,
      ),
    {
      onValue: (status) => {
        const wasRunning = scrapeState.value?.running;
        scrapeState.value = status;
        if (wasRunning && !status.running) {
          scrapeNotice.value = "自动刮削已结束：处理 " + status.processed + " 项，成功匹配 " + status.matched + " 项。";
          void options.load(true);
        }
        if (!status.running) stopScrapeTimer();
        else if (scrapeTimer === undefined) {
          scrapeTimer = window.setInterval(() => {
            if (!document.hidden) void refreshScrape();
          }, 3000);
        }
      },
    },
  );

  function refreshScrape() {
    if (!options.isDisposed() && options.isAdmin() === true) return scrapeStatusPoller.refresh();
  }

  async function startScrape() {
    if (scrapeBusy.value) return;
    const context = options.getRootEpoch();
    scrapeBusy.value = true;
    scrapeError.value = "";
    try {
      await options.api(options.apiPath("/api/v2/cinema/scrape/start"), "POST", { retryMisses: scrapeRetryTried.value });
      if (options.isDisposed() || context !== options.getRootEpoch()) return;
      scrapeStatusPoller.invalidate();
      scrapeNotice.value = "自动刮削已启动；处理速度受 TMDB 限速约束，可随时在任务中心取消。";
      await refreshScrape();
    } catch (e) {
      const code = e instanceof Error ? e.message : "request_failed";
      if (options.isDisposed() || context !== options.getRootEpoch()) return;
      scrapeError.value =
        code === "tmdb_token_not_configured"
          ? "自动刮削需要在 Mac App「偏好与安全」中配置 TMDB Token。"
          : code === "scan_running"
            ? "媒体库扫描正在进行，请稍后再试。"
            : options.transcodeErrorMessage(e);
    } finally {
      scrapeBusy.value = false;
    }
  }

  function resetMetadataForOpen(v: Movie) {
    cancelMetadataRequests();
    tmdbQuery.value = v.title;
    tmdbToken.value = "";
    tmdbMatches.value = [];
    candidatePosterFailed.value = {};
    tmdbError.value = "";
    scrapeMessage.value = "";
    doubanQuery.value = v.title;
    doubanMatches.value = [];
    doubanError.value = "";
  }

  function resetMetadataForClose() {
    cancelMetadataRequests();
    tmdbToken.value = "";
    tmdbMatches.value = [];
    tmdbError.value = "";
    doubanMatches.value = [];
    doubanError.value = "";
    scrapeMessage.value = "";
  }

  function resetMetadataForRootChange() {
    cancelBatch();
    cancelMetadataRequests();
    scrapeStatusPoller.invalidate();
    stopScrapeTimer();
    scrapeState.value = null;
    scrapeNotice.value = "";
  }

  function disposeMetadata() {
    stopScrapeTimer();
    scrapeStatusPoller.dispose();
    cancelMetadataRequests();
    cancelBatch();
    tmdbToken.value = "";
  }

  return {
    candidatePosterFailed,
    scraping,
    scrapeMessage,
    tmdbQuery,
    tmdbToken,
    tmdbMatches,
    tmdbBusy,
    tmdbError,
    batchToken,
    batchBusy,
    batchError,
    batchProgress,
    batchCandidates,
    doubanQuery,
    doubanMatches,
    doubanBusy,
    doubanError,
    scrapeState,
    scrapeBusy,
    scrapeNotice,
    scrapeError,
    scrapeRetryTried,
    cancelBatch,
    suggestBatch,
    acceptBatchCandidate,
    cancelMetadataRequests,
    searchDouban,
    matchDouban,
    rename,
    importLocalNFO,
    searchTMDB,
    matchTMDB,
    refreshScrape,
    startScrape,
    resetMetadataForOpen,
    resetMetadataForClose,
    resetMetadataForRootChange,
    disposeMetadata,
  };
}
