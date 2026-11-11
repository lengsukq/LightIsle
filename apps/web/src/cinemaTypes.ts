// Shared movie and playback data shapes for the cinema page and its playback controller.
export type BrowserPlayback = "verified-direct" | "unverified-direct" | "download-only";
export type ProbeStatus = "pending" | "ready" | "unsupported" | "unavailable" | "failed";

export type Movie = {
  id: number;
  title: string;
  path: string;
  kind: string;
  series: string;
  season: number;
  episode: number;
  year: number;
  size: number;
  canWrite?: boolean;
  playable?: boolean;
  browserPlayback?: BrowserPlayback;
  probeStatus?: ProbeStatus;
  mime?: string;
  container?: string;
  videoCodec?: string;
  audioCodec?: string;
  durationSeconds?: number;
  width?: number;
  height?: number;
  position: number;
  duration: number;
  completed: boolean;
  updatedAt?: number;
  overview?: string;
  rating?: number;
  metadataSource?: string;
  titleSource?: string;
  yearSource?: string;
  scrapeState?: string;
  posterURL?: string;
};

export type TMDBCandidate = {
  id: number;
  kind: string;
  title: string;
  year?: string;
  overview?: string;
  rating: number;
  posterURL?: string;
};

export type DoubanCandidate = { id: string; title: string; year?: string; kind?: string };
export type Scan = { running: boolean; visited: number; found: number; lastDone: number; lastError?: string };
export type TranscodeSession = {
  sessionId: string;
  start: number;
  durationSeconds?: number;
  profile: "remux" | "transcode";
  audioTrack: number;
  quality: string;
  ready: boolean;
};
export type AudioTrackInfo = {
  streamIndex: number;
  audioIndex: number;
  codec?: string;
  language?: string;
  title?: string;
  channels?: number;
};
export type SubtitleTrackInfo = {
  streamIndex: number;
  codec?: string;
  language?: string;
  title?: string;
  extractable: boolean;
};
export type TrackInfo = {
  videoCodec?: string;
  width?: number;
  height?: number;
  durationSeconds?: number;
  audio: AudioTrackInfo[];
  subtitles: SubtitleTrackInfo[];
};
export type SeriesInfo = {
  id: number;
  name: string;
  tmdbId?: number;
  overview?: string;
  posterURL?: string;
  episodeCount: number;
  watchedCount: number;
  year?: number;
  nextFilmId?: number;
  nextTitle?: string;
  inProgress?: boolean;
  position?: number;
  duration?: number;
};
export type BatchCandidate = {
  filmId: number;
  filmTitle: string;
  match: TMDBCandidate;
  score: number;
};
