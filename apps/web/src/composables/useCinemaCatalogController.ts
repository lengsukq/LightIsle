import { computed, ref, type Ref } from "vue";
import { describeRootOperationFailure } from "../rootDiscovery.ts";
import { describeUserFacingError } from "../userFacingError.ts";
import { trashMediaOriginals } from "../mediaTrash.ts";
import { createMediaStatusPoller } from "../mediaStatusPoller.ts";
import { mediaQueryKey, transitionMediaQuery } from "../mediaQueryContext.ts";
import {
  duplicateCinemaTitleKeys,
  filmFolderBadge,
  normalizeCinemaTitleKey,
  shouldShowCinemaRecentShelf,
} from "../cinemaCatalogDisplay.ts";
import { readCinemaHomeShelves } from "../cinemaHomeShelves.ts";
import { getMetadata, putMetadata } from "../useIsleCache.ts";
import { requestConfirm } from "../useConfirmDialog.ts";
import type { Movie, Scan } from "../cinemaTypes.ts";

export function useCinemaCatalogController({
  props,
  movies,
  mode,
  query,
  view,
  selected,
  posterFailed,
  actionError,
  getRootEpoch,
  isDisposed,
  api,
  apiPath,
  onSelectedTrashed,
  onScanCompleted,
}: {
  props: { admin: boolean; rootId?: string; rootGeneration?: number };
  movies: Ref<Movie[]>;
  mode: Ref<string>;
  query: Ref<string>;
  view: Ref<"films" | "series">;
  selected: Ref<Movie | null>;
  posterFailed: Ref<Record<number, boolean>>;
  actionError: Ref<string>;
  getRootEpoch: () => number;
  isDisposed: () => boolean;
  api: <T = unknown>(url: string, method?: string, body?: object, signal?: AbortSignal) => Promise<T>;
  apiPath: (path: string) => string;
  onSelectedTrashed: () => void;
  onScanCompleted: () => void;
}) {
  const next = ref(0);
  const loading = ref(false);
  const pageLoaded = ref(false);
  const loadError = ref("");
  const loadErrorReset = ref(true);
  const scanActionError = ref("");
  const scanStatusLoading = ref(false);
  const scanStatusLoaded = ref(false);
  const scanStatusError = ref("");
  const scan = ref<Scan>({ running: false, visited: 0, found: 0, lastDone: 0 });
  const continueShelf = ref<Movie[]>([]);
  const recentShelf = ref<Movie[]>([]);
  const shelvesError = ref("");
  const deleting = ref(false);
  const choosingTrash = ref(false);
  const trashIDs = ref<Set<number>>(new Set());

  let loadGeneration = 0;
  let shelfGeneration = 0;
  let lastDone = 0;

  function cinemaQueryKey() {
    return mediaQueryKey({
      root: props.rootId ?? "",
      generation: props.rootGeneration ?? 0,
      mode: mode.value,
      query: query.value.trim(),
    });
  }
  let pageQueryKey = cinemaQueryKey();

  const featuredFilm = computed(() => continueShelf.value[0] ?? recentShelf.value[0] ?? movies.value[0] ?? null);
  const showRecentShelf = computed(() => recentShelf.value.length > 0 && shouldShowCinemaRecentShelf(movies.value.length, next.value));
  const duplicateTitleSet = computed(() => duplicateCinemaTitleKeys(movies.value));

  function disambiguationBadge(movie: Movie): string {
    return duplicateTitleSet.value.has(normalizeCinemaTitleKey(movie.title)) ? filmFolderBadge(movie.path) : "";
  }

  function toggleTrashFilm(id: number) {
    if (!movies.value.some((movie) => movie.id === id && (props.admin || movie.canWrite === true))) return;
    const updated = new Set(trashIDs.value);
    if (updated.has(id)) updated.delete(id);
    else if (updated.size < 50) updated.add(id);
    trashIDs.value = updated;
  }

  async function loadHomeShelves() {
    const epoch = getRootEpoch();
    const generation = ++shelfGeneration;
    const current = () => !isDisposed() && epoch === getRootEpoch() && generation === shelfGeneration;
    try {
      const shelves = await readCinemaHomeShelves(
        (kind) => api<{ films: Movie[] }>(apiPath("/api/v2/cinema") + "?" + new URLSearchParams({ kind, limit: "8", cursor: "0" })),
        current,
      );
      if (!shelves || !current()) return;
      continueShelf.value = shelves.resume;
      recentShelf.value = shelves.recent;
      shelvesError.value = "";
    } catch (e) {
      if (current()) shelvesError.value = describeRootOperationFailure(e);
    }
  }

  async function load(reset = false) {
    if (loading.value && !reset) return;
    const transition = transitionMediaQuery(pageQueryKey, cinemaQueryKey());
    if (transition.clearContent) {
      pageQueryKey = transition.queryKey;
      movies.value = [];
      next.value = 0;
      pageLoaded.value = false;
      posterFailed.value = {};
    }
    const generation = ++loadGeneration;
    loading.value = true;
    loadError.value = "";
    if (reset && !movies.value.length) {
      const cached = getMetadata<{ films: Movie[]; nextCursor: number }>("cinema:list:" + cinemaQueryKey());
      if (cached?.films?.length) {
        movies.value = cached.films;
        next.value = cached.nextCursor || 0;
        pageLoaded.value = true;
      }
    }
    try {
      const params = new URLSearchParams({ limit: "48", cursor: String(reset ? 0 : next.value) });
      if (mode.value !== "all") params.set("kind", mode.value);
      if (query.value.trim()) params.set("query", query.value.trim());
      const page = await api<{ films: Movie[]; nextCursor: number }>(apiPath("/api/v2/cinema") + "?" + params);
      if (generation !== loadGeneration) return;
      movies.value = reset ? page.films : [...movies.value, ...page.films];
      next.value = page.nextCursor;
      if (reset) {
        pageLoaded.value = true;
        actionError.value = "";
        putMetadata("cinema:list:" + cinemaQueryKey(), { films: page.films, nextCursor: page.nextCursor });
      }
      loadError.value = "";
    } catch (e) {
      if (generation === loadGeneration && !(e instanceof Error && e.name === "AbortError")) {
        loadError.value = describeRootOperationFailure(e);
        loadErrorReset.value = reset;
      }
    } finally {
      if (generation === loadGeneration) loading.value = false;
    }
  }

  function retryLoad() {
    void load(loadErrorReset.value);
  }

  async function trashFilms(items: Movie[]) {
    if (deleting.value || !items.length) return;
    if (items.length > 50 || items.some((item) => !item.path || !(props.admin || item.canWrite === true))) {
      actionError.value = "每次最多删除50部，且只能删除你有写入权限的原文件。";
      return;
    }
    const root = getRootEpoch();
    const generation = loadGeneration;
    const frozen = items.map((item) => ({ id: item.id, path: item.path }));
    if (
      !(await requestConfirm({
        title: "移入回收站",
        message: `将 ${items.length} 部影片的原文件移入回收站？影视记录将在后续扫描时更新。`,
        confirmText: "移入回收站",
        variant: "danger",
      }))
    ) {
      return;
    }
    const current = () =>
      !isDisposed() &&
      root === getRootEpoch() &&
      generation === loadGeneration &&
      frozen.every((item) => movies.value.some((film) => film.id === item.id && film.path === item.path));
    if (!current()) {
      actionError.value = "影片列表或硬盘已变化，请重新选择。";
      return;
    }
    deleting.value = true;
    try {
      const result = await trashMediaOriginals(
        frozen.map((item) => item.path),
        (paths) => api<{ results: Array<{ path?: string; success: boolean; error?: string }> }>(apiPath("/api/v2/files/batch"), "POST", { action: "trash", paths }),
        current,
      );
      if (result.cancelled) {
        actionError.value = "存储根已变化，请回原目录确认删除结果。";
        return;
      }
      if (selected.value && frozen.some((item) => item.id === selected.value?.id)) onSelectedTrashed();
      trashIDs.value = new Set();
      choosingTrash.value = false;
      const outcome =
        `已确认移入回收站 ${result.completed}/${items.length} 项。` +
        (result.needsRootCheck
          ? "硬盘连接发生变化，部分操作的结果不确定。请重新连接原硬盘，检查原目录和回收站后再重试。"
          : result.failed.length
            ? "其余项目请检查权限或文件状态。"
            : "");
      await load(true);
      if (!isDisposed() && root === getRootEpoch()) actionError.value = outcome;
    } catch (error) {
      if (root === getRootEpoch()) actionError.value = "未能确认移入回收站的结果：" + describeRootOperationFailure(error);
    } finally {
      deleting.value = false;
    }
  }

  function trashSelectedFilms() {
    const items = movies.value.filter((item) => trashIDs.value.has(item.id));
    if (items.length !== trashIDs.value.size) {
      actionError.value = "影片列表已变化，请重新选择。";
      return;
    }
    void trashFilms(items);
  }

  const scanStatusPoller = createMediaStatusPoller(
    (signal) => api<{ status: Scan }>(apiPath("/api/v2/cinema/status"), "GET", undefined, signal),
    {
      onValue: (value) => {
        const wasRunning = scan.value.running;
        scan.value = value.status;
        scanStatusLoaded.value = true;
        scanStatusError.value = "";
        scanStatusLoading.value = false;
        if ((wasRunning && !scan.value.running) || (scan.value.lastDone && scan.value.lastDone !== lastDone)) {
          lastDone = scan.value.lastDone;
          void load(true);
          void loadHomeShelves();
          onScanCompleted();
        }
      },
      onError: (value) => {
        scanStatusError.value = describeRootOperationFailure(value);
        scanStatusLoading.value = false;
      },
    },
  );

  function status() {
    scanStatusLoading.value = true;
    return scanStatusPoller.refresh();
  }

  async function startScan() {
    const context = getRootEpoch();
    scanActionError.value = "";
    try {
      await api(apiPath("/api/v2/cinema/scan"), "POST");
      if (context !== getRootEpoch()) return;
      scanStatusPoller.invalidate();
      await status();
    } catch (e) {
      if (context === getRootEpoch()) scanActionError.value = describeUserFacingError(e);
    }
  }

  function clearCatalogForQueryChange() {
    const transition = transitionMediaQuery(pageQueryKey, cinemaQueryKey());
    if (transition.clearContent) {
      pageQueryKey = transition.queryKey;
      loadGeneration += 1;
      movies.value = [];
      next.value = 0;
      loading.value = false;
      pageLoaded.value = false;
      loadError.value = "";
      loadErrorReset.value = true;
      actionError.value = "";
      posterFailed.value = {};
    }
  }

  function resetCatalogForRootChange() {
    loadGeneration += 1;
    shelfGeneration += 1;
    scanStatusPoller.invalidate();
    movies.value = [];
    next.value = 0;
    loading.value = false;
    pageLoaded.value = false;
    pageQueryKey = cinemaQueryKey();
    loadError.value = "";
    actionError.value = "";
    scanActionError.value = "";
    scanStatusLoaded.value = false;
    scanStatusLoading.value = false;
    scanStatusError.value = "";
    scan.value = { running: false, visited: 0, found: 0, lastDone: 0 };
    lastDone = 0;
    continueShelf.value = [];
    recentShelf.value = [];
    shelvesError.value = "";
    trashIDs.value = new Set();
    choosingTrash.value = false;
    deleting.value = false;
  }

  function disposeCatalog() {
    loadGeneration += 1;
    shelfGeneration += 1;
    scanStatusPoller.dispose();
  }

  const filteredView = computed(() => mode.value !== "all" || !!query.value.trim());
  const emptyTitle = computed(() =>
    query.value.trim()
      ? "没有找到匹配的影片"
      : mode.value === "continue"
        ? "还没有可继续观看的影片"
        : mode.value === "unmatched"
          ? "所有影片均已匹配资料"
          : mode.value === "movie"
            ? "电影分类还没有内容"
            : mode.value === "series"
              ? "剧集分类还没有内容"
              : "还没有影片",
  );
  const emptyMessage = computed(() =>
    query.value.trim()
      ? "换个名称试试，或查看全部影片。"
      : mode.value === "continue"
        ? "播放影片后，可从这里继续上次的观看进度。"
        : mode.value === "unmatched"
          ? "没有尚未确认海报或简介的影片。"
          : mode.value !== "all"
            ? "可以查看全部影片，或将此类影视文件加入共享目录后重新扫描。"
            : "将影视文件拷贝到 Mac 共享目录后，点击右上角「扫描影视库」。",
  );
  const continueCount = computed(() => movies.value.filter((v) => v.position > 5 && !v.completed).length);

  return {
    next,
    loading,
    pageLoaded,
    loadError,
    scanActionError,
    scanStatusLoading,
    scanStatusLoaded,
    scanStatusError,
    scan,
    continueShelf,
    recentShelf,
    shelvesError,
    featuredFilm,
    showRecentShelf,
    deleting,
    choosingTrash,
    trashIDs,
    filteredView,
    emptyTitle,
    emptyMessage,
    continueCount,
    disambiguationBadge,
    toggleTrashFilm,
    loadHomeShelves,
    load,
    retryLoad,
    trashFilms,
    trashSelectedFilms,
    status,
    startScan,
    clearCatalogForQueryChange,
    resetCatalogForRootChange,
    disposeCatalog,
  };
}
