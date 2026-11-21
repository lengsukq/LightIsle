import type { ComputedRef, InjectionKey, Ref } from "vue";
import type { SubtitleSizePreset } from "../features/cinema/cinemaSubtitles.ts";
import type {
  BrowserPlayback,
  DoubanCandidate,
  Movie,
  Scan,
  SeriesInfo,
  TMDBCandidate,
  TranscodeSession,
} from "../features/cinema/cinemaTypes.ts";

export interface CinemaSelectChoice {
  value: string | number;
  label: string;
}

export interface CinemaBrowseContext {
  view: Ref<"films" | "series">;
  mode: Ref<string>;
  query: Ref<string>;
  admin: ComputedRef<boolean>;
  movies: Ref<Movie[]>;
  next: Ref<number>;
  loading: Ref<boolean>;
  pageLoaded: Ref<boolean>;
  loadError: Ref<string>;
  actionError: Ref<string>;
  scanActionError: Ref<string>;
  scanStatusError: Ref<string>;
  scanStatusLoaded: Ref<boolean>;
  scanStatusLoading: Ref<boolean>;
  scan: Ref<Scan>;
  choosingTrash: Ref<boolean>;
  trashIds: Ref<Set<number>>;
  deleting: Ref<boolean>;
  filteredView: ComputedRef<boolean>;
  emptyTitle: ComputedRef<string>;
  emptyMessage: ComputedRef<string>;
  featuredFilm: ComputedRef<Movie | null>;
  continueShelf: Ref<Movie[]>;
  showRecentShelf: ComputedRef<boolean>;
  disambiguationMap: ComputedRef<ReadonlyMap<number, string>>;
  matchingSeries: Ref<SeriesInfo[]>;
  seriesSearchLoading: Ref<boolean>;
  seriesSearchError: Ref<string>;
  seriesList: Ref<SeriesInfo[]>;
  seriesLoading: Ref<boolean>;
  seriesError: Ref<string>;
  historyFilms: Ref<Movie[]>;
  historyLoading: Ref<boolean>;
  historyError: Ref<string>;
  posterFailed: Ref<Record<number, boolean>>;
  posterReady: (movie: Movie) => boolean;
  posterUrl: (movie: Movie) => string;
  seriesPosterUrl: (id: number, rawUrl?: string) => string;
  playback: (movie: Movie) => BrowserPlayback;
  retrySeriesSearch: () => void;
  openSeries: (item: SeriesInfo) => void;
  continueSeries: (item: SeriesInfo) => void;
  reloadSeries: () => void;
  retryLoad: () => void;
  retryStatus: () => void;
  startScan: () => void;
  resetFilters: () => void;
  reloadHistory: () => void;
  clearHistory: () => void;
  openFilm: (film: Movie, autoStart?: boolean) => void;
  toggleTrashFilm: (id: number) => void;
  trashFilm: (film: Movie) => void;
  openRename: (film: Movie) => void;
  markRestart: (film: Movie) => void;
  loadMore: () => void;
  posterError: (id: number) => void;
}

export interface CinemaDetailContext {
  selected: Ref<Movie | null>;
  admin: ComputedRef<boolean>;
  canTrashSelected: ComputedRef<boolean>;
  deleting: Ref<boolean>;
  leavingPlayer: Ref<boolean>;
  posterFailed: Ref<Record<number, boolean>>;
  posterReady: (movie: Movie) => boolean;
  posterUrl: (movie: Movie) => string;
  mediaPath: (path: string) => string;
  playbackMode: ComputedRef<BrowserPlayback>;
  playbackLabelText: ComputedRef<string>;
  sameDirectoryFilms: ComputedRef<Movie[]>;
  playlistDirLabel: ComputedRef<string>;
  scrapeMessage: Ref<string>;
  scraping: Ref<boolean>;
  doubanQuery: Ref<string>;
  doubanMatches: Ref<DoubanCandidate[]>;
  doubanBusy: Ref<boolean>;
  doubanError: Ref<string>;
  tmdbToken: Ref<string>;
  tmdbQuery: Ref<string>;
  tmdbMatches: Ref<TMDBCandidate[]>;
  tmdbBusy: Ref<boolean>;
  tmdbError: Ref<string>;
  candidatePosterFailed: Ref<Record<number, boolean>>;
  playSelected: () => void;
  posterError: (id: number) => void;
  candidatePosterError: (id: number) => void;
  switchPlaylistFilm: (film: Movie) => void;
  searchDouban: () => void;
  matchDouban: (candidate: DoubanCandidate) => void;
  searchTmdb: () => void;
  matchTmdb: (candidate: TMDBCandidate) => void;
  trashSelected: () => void;
  downloadSelected: () => void;
  toggleWatched: () => void;
  clearProgress: () => void;
  restartFromBeginning: () => void;
  importLocalNfo: () => void;
  openMountGuide: () => void;
}

export interface CinemaPlayerContext {
  selected: Ref<Movie | null>;
  canDirect: ComputedRef<boolean>;
  streamUrl: ComputedRef<string>;
  trackUrl: ComputedRef<string>;
  caption: Ref<string>;
  captionSrclang: ComputedRef<string>;
  captionOptions: ComputedRef<CinemaSelectChoice[]>;
  audioTrackOptions: ComputedRef<CinemaSelectChoice[]>;
  qualityOptions: ComputedRef<CinemaSelectChoice[]>;
  currentQuality: ComputedRef<string>;
  playbackRate: Ref<number>;
  isSpeedBoosting: Ref<boolean>;
  osdMessage: Ref<string>;
  playbackRateOptions: ReadonlyArray<CinemaSelectChoice>;
  subtitleSize: Ref<SubtitleSizePreset>;
  subtitleOffset: Ref<number>;
  localSubtitleName: Ref<string>;
  localSubtitleError: Ref<string>;
  hlsSession: Ref<TranscodeSession | null>;
  hlsStarting: Ref<boolean>;
  playError: Ref<string>;
  isPlaying: Ref<boolean>;
  volume: Ref<number>;
  isMuted: Ref<boolean>;
  fillScreen: Ref<boolean>;
  isFullscreen: Ref<boolean>;
  canPictureInPicture: boolean;
  playbackPosition: Ref<number>;
  playbackDuration: Ref<number>;
  playbackBuffered: Ref<number>;
  autoplayNext: Ref<boolean>;
  preferLocalDecode: Ref<boolean>;
  leavingPlayer: Ref<boolean>;
  showPlayerPlaylist: Ref<boolean>;
  sameDirectoryFilms: ComputedRef<Movie[]>;
  currentPlaylistIndex: ComputedRef<number>;
  hasPrevPlaylist: ComputedRef<boolean>;
  hasNextPlaylist: ComputedRef<boolean>;
  playlistDirLabel: ComputedRef<string>;
  directoryLoading: Ref<boolean>;
  directoryError: Ref<string>;
  directoryNextCursor: Ref<number>;
  controlsHidden: Ref<boolean>;
  setDirectVideoRef: (el: HTMLVideoElement | null) => void;
  setHlsVideoRef: (el: HTMLVideoElement | null) => void;
  setControlsHidden: (hidden: boolean) => void;
  setMenuOpen: (open: boolean) => void;
  togglePlaylist: (open: boolean) => void;
  onLoadedMetadata: () => void;
  onTimeUpdate: () => void;
  onBufferProgress: () => void;
  onMediaState: () => void;
  onPauseSave: () => void;
  onEnded: () => void;
  onDirectError: () => void;
  onHlsError: () => void;
  onCaptionLoad: () => void;
  togglePlay: () => void;
  jump: (deltaSeconds: number) => void;
  seek: (positionSeconds: number) => void;
  setVolume: (volume: number) => void;
  toggleMute: () => void;
  selectCaption: (value: string) => void;
  selectLocalSubtitle: (file: File) => void;
  clearLocalSubtitle: () => void;
  setSubtitleSize: (size: SubtitleSizePreset) => void;
  adjustSubtitleOffset: (deltaSeconds: number) => void;
  resetSubtitleOffset: () => void;
  selectAudio: (index: number) => void;
  selectQuality: (quality: string) => void;
  selectRate: (rate: number) => void;
  toggleAutoplay: (checked: boolean) => void;
  toggleLocalDecode: (checked: boolean) => void;
  toggleFill: () => void;
  togglePip: () => void;
  toggleFullscreen: () => void;
  startTranscode: () => void;
  download: () => void;
  switchPlaylistFilm: (film: Movie) => void;
  prevPlaylist: () => void;
  nextPlaylist: () => void;
  reloadPlaylist: (append: boolean) => void;
}

export const CINEMA_BROWSE_CTX: InjectionKey<CinemaBrowseContext> = Symbol("lightisle-cinema-browse");
export const CINEMA_DETAIL_CTX: InjectionKey<CinemaDetailContext> = Symbol("lightisle-cinema-detail");
export const CINEMA_PLAYER_CTX: InjectionKey<CinemaPlayerContext> = Symbol("lightisle-cinema-player");
