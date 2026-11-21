import { computed, ref, type Ref } from "vue";
import type { Movie } from "./cinemaTypes.ts";

// A playlist is scoped to the physical root generation and the immediate
// directory of the selected film. Never keep results from an old root.
export function useCinemaDirectoryPlaylist(options: {
  selected: Ref<Movie | null>;
  sources: () => Movie[][];
  rootEpoch: () => number;
  disposed: () => boolean;
  api: <T>(url: string, method?: string, body?: object, signal?: AbortSignal) => Promise<T>;
  apiPath: (path: string) => string;
  describeError: (error: unknown) => string;
}) {
  const films = ref<Movie[]>([]);
  const loadedKey = ref("");
  const nextCursor = ref(0);
  const loading = ref(false);
  const error = ref("");
  let requestGeneration = 0;
  let currentRequestKey = "";
  let controller: AbortController | null = null;
  let inFlight: Promise<void> | null = null;

  function directoryOf(path: string): string {
    const normalized = path.replace(/\\/g, "/").replace(/^\/+|\/+$/g, "");
    const slash = normalized.lastIndexOf("/");
    return slash < 0 ? "." : normalized.slice(0, slash);
  }
  function keyFor(film: Movie): string {
    return options.rootEpoch() + ":" + directoryOf(film.path);
  }
  function reset() {
    requestGeneration += 1;
    controller?.abort();
    controller = null;
    inFlight = null;
    currentRequestKey = "";
    films.value = [];
    loadedKey.value = "";
    nextCursor.value = 0;
    loading.value = false;
    error.value = "";
  }
  const sameDirectoryFilms = computed(() => {
    const current = options.selected.value;
    if (!current) return [];
    const dir = directoryOf(current.path);
    const all = new Map<number, Movie>();
    const entries = [
      ...(loadedKey.value === keyFor(current) ? films.value : []),
      ...options.sources().flat(),
      current,
    ];
    for (const item of entries) {
      if (item.id === current.id || directoryOf(item.path) === dir) {
        all.set(item.id, item.id === current.id ? current : item);
      }
    }
    return [...all.values()].sort((a, b) =>
      (a.season || 0) - (b.season || 0) ||
      (a.episode || 0) - (b.episode || 0) ||
      a.path.localeCompare(b.path, undefined, { numeric: true }) ||
      a.id - b.id,
    );
  });
  const currentIndex = computed(() => {
    const id = options.selected.value?.id;
    return Math.max(0, sameDirectoryFilms.value.findIndex(movie => movie.id === id));
  });
  const previousFilm = computed(() => sameDirectoryFilms.value[currentIndex.value - 1] ?? null);
  const nextFilm = computed(() => sameDirectoryFilms.value[currentIndex.value + 1] ?? null);

  async function load(film: Movie, append = false): Promise<void> {
    const key = keyFor(film);
    if (append && (loadedKey.value !== key || nextCursor.value === 0)) return;
    if (!append && loadedKey.value === key) return;
    if (inFlight && currentRequestKey === key) {
      await inFlight;
      if (append) return load(film, true);
      return;
    }
    if (inFlight) controller?.abort();
    if (loadedKey.value !== key) {
      films.value = [];
      loadedKey.value = "";
      nextCursor.value = 0;
    }
    const generation = ++requestGeneration;
    const offset = append ? nextCursor.value : 0;
    const abort = new AbortController();
    controller = abort;
    currentRequestKey = key;
    loading.value = true;
    error.value = "";
    const isCurrent = () =>
      !options.disposed() &&
      generation === requestGeneration &&
      key === keyFor(film) &&
      (options.selected.value ? keyFor(options.selected.value) === key : false);
    const work = (async () => {
      try {
        const params = new URLSearchParams({
          dir: directoryOf(film.path), limit: "120", cursor: String(offset),
        });
        const page = await options.api<{films: Movie[]; nextCursor: number}>(
          options.apiPath("/api/v2/cinema") + "?" + params,
          "GET", undefined, abort.signal,
        );
        if (!isCurrent()) return;
        const fetched = Array.isArray(page.films) ? page.films : [];
        films.value = append ? [...films.value, ...fetched] : fetched;
        loadedKey.value = key;
        nextCursor.value = Number.isInteger(page.nextCursor) && page.nextCursor > offset
          ? page.nextCursor : 0;
      } catch (reason) {
        if (isCurrent() && !abort.signal.aborted) error.value = options.describeError(reason);
      } finally {
        if (generation === requestGeneration) {
          loading.value = false;
          controller = null;
          inFlight = null;
          currentRequestKey = "";
        }
      }
    })();
    inFlight = work;
    await work;
  }
  async function findNext(film: Movie): Promise<Movie | null> {
    if (options.selected.value?.id !== film.id) return null;
    if (nextFilm.value) return nextFilm.value;
    await load(film);
    if (nextFilm.value) return nextFilm.value;
    let pages = 0;
    while (!error.value && nextCursor.value && pages++ < 10 &&
           options.selected.value?.id === film.id) {
      const previousCursor = nextCursor.value;
      await load(film, true);
      if (nextFilm.value) return nextFilm.value;
      if (nextCursor.value === previousCursor) break;
    }
    return null;
  }
  return {
    directoryOf, reset, load, findNext, sameDirectoryFilms, currentIndex,
    previousFilm, nextFilm, loading, error, nextCursor, loadedKey,
  };
}
