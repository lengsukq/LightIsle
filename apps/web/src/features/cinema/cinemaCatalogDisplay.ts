import type { BrowserPlayback, ProbeStatus } from "./cinemaTypes.ts";

export function formatCinemaClock(rawSeconds: number): string {
  if (!Number.isFinite(rawSeconds) || rawSeconds <= 0) return "0:00";
  const total = Math.floor(rawSeconds);
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const seconds = total % 60;
  const pad2 = (n: number) => String(n).padStart(2, "0");
  if (hours > 0) return `${hours}:${pad2(minutes)}:${pad2(seconds)}`;
  return `${minutes}:${pad2(seconds)}`;
}

const CODEC_LABELS: Record<string, string> = {
  hevc: "HEVC",
  h265: "HEVC",
  "h.265": "HEVC",
  hev1: "HEVC",
  hvc1: "HEVC",
  h264: "H.264",
  "h.264": "H.264",
  avc: "H.264",
  avc1: "H.264",
  av1: "AV1",
  av01: "AV1",
  vp9: "VP9",
  vp09: "VP9",
  eac3: "EAC3",
  "ec-3": "EAC3",
  ddp: "EAC3",
  ac3: "AC3",
  "ac-3": "AC3",
  truehd: "TrueHD",
  dts: "DTS",
  dca: "DTS",
  aac: "AAC",
  mp4a: "AAC",
  flac: "FLAC",
  opus: "Opus",
  mp3: "MP3",
};

export function formatCinemaResolution(width?: number, height?: number): string {
  const w = Number(width || 0);
  const h = Number(height || 0);
  if (h >= 2100 || w >= 3800) return "4K";
  if (h >= 1400 || w >= 2500) return "2K";
  if (h >= 1000 || w >= 1800) return "1080p";
  if (h >= 700 || w >= 1200) return "720p";
  if (h > 0) return `${h}p`;
  return "";
}

export function formatCinemaCodec(raw?: string): string {
  const clean = (raw || "").trim().toLowerCase();
  if (!clean) return "";
  return CODEC_LABELS[clean] ?? clean.toUpperCase().slice(0, 10);
}

export function formatCinemaPlaybackLabel(mode: BrowserPlayback, probeStatus?: ProbeStatus): string {
  if (mode === "verified-direct") return "已验证可播放";
  if (mode === "unverified-direct") return "可尝试播放 · 尚未验证";
  if (probeStatus === "pending") return "正在识别格式";
  if (probeStatus === "unavailable") return "格式检查器不可用";
  if (probeStatus === "failed") return "格式识别失败";
  if (probeStatus === "unsupported") return "浏览器暂不支持";
  return "建议下载后播放";
}

export interface CinemaPosterPalette {
  bg: string;
  glow: string;
  accent: string;
}

const POSTER_PALETTES: readonly CinemaPosterPalette[] = [
  {
    bg: "linear-gradient(155deg, #161C28 0%, #243044 55%, #12151C 100%)",
    glow: "radial-gradient(circle at 76% 24%, rgba(103, 212, 224, 0.24), transparent 62%)",
    accent: "#67D4E0",
  },
  {
    bg: "linear-gradient(155deg, #1E1916 0%, #342821 55%, #131110 100%)",
    glow: "radial-gradient(circle at 74% 26%, rgba(244, 185, 66, 0.24), transparent 62%)",
    accent: "#F4B942",
  },
  {
    bg: "linear-gradient(155deg, #15211E 0%, #213A34 55%, #101715 100%)",
    glow: "radial-gradient(circle at 72% 24%, rgba(82, 199, 186, 0.22), transparent 62%)",
    accent: "#52C7BA",
  },
  {
    bg: "linear-gradient(155deg, #211822 0%, #38273B 55%, #141016 100%)",
    glow: "radial-gradient(circle at 76% 26%, rgba(232, 136, 100, 0.24), transparent 62%)",
    accent: "#E88864",
  },
  {
    bg: "linear-gradient(155deg, #191B26 0%, #2C3048 55%, #12131A 100%)",
    glow: "radial-gradient(circle at 74% 22%, rgba(167, 139, 250, 0.22), transparent 62%)",
    accent: "#A78BFA",
  },
];

export function cinemaPosterPalette(seed: string | number): CinemaPosterPalette {
  const text = String(seed ?? "");
  let hash = 0;
  for (let i = 0; i < text.length; i += 1) {
    hash = (hash * 31 + text.charCodeAt(i)) | 0;
  }
  const index = Math.abs(hash) % POSTER_PALETTES.length;
  return POSTER_PALETTES[index];
}

export function shouldShowCinemaRecentShelf(loadedCount: number, nextCursor: number): boolean {
  return nextCursor > 0 || loadedCount > 8;
}

export function normalizeCinemaTitleKey(title: string): string {
  return title
    .trim()
    .toLowerCase()
    .replace(/[\s:：·・\-_—–.。!！?？()（）[\]【】]+/g, "");
}

export function cinemaIdentityKey(film: {
  title: string;
  kind?: string;
  series?: string;
  titleSource?: string;
  season?: number;
  episode?: number;
}): string {
  const display =
    film.titleSource === "manual"
      ? film.title
      : film.kind === "series" && film.series
        ? film.series
        : film.title;
  const base = normalizeCinemaTitleKey(display || "");
  if (!base) return "";
  if (film.kind === "series" && ((film.season || 0) > 0 || (film.episode || 0) > 0)) {
    return `${base}#s${film.season || 0}e${film.episode || 0}`;
  }
  return base;
}

export function duplicateCinemaTitleKeys(
  films: ReadonlyArray<{
    title: string;
    kind?: string;
    series?: string;
    titleSource?: string;
    season?: number;
    episode?: number;
  }>,
): Set<string> {
  const counts = new Map<string, number>();
  for (const film of films) {
    const key = cinemaIdentityKey(film);
    if (!key) continue;
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  const duplicates = new Set<string>();
  for (const [key, count] of counts) {
    if (count > 1) duplicates.add(key);
  }
  return duplicates;
}

export function filmFolderBadge(filePath: string): string {
  const clean = (filePath || "").replace(/^\/+|\/+$/g, "");
  if (!clean || !clean.includes("/")) return "根目录";
  if (/^users\/u\d+(\/|$)/i.test(clean)) {
    const parts = clean.split("/");
    if (parts.length > 4) return `个人空间 · ${parts[parts.length - 2]}`;
    return "个人空间";
  }
  const parts = clean.split("/");
  return parts.length >= 2 ? parts[parts.length - 2] : parts[0];
}

export function resolveCinemaFilmPosterUrl(
  film: { id: number; posterURL?: string },
  mediaPath: (p: string) => string,
  directFallback: Record<number, boolean>,
): string {
  if (film.posterURL && directFallback[film.id]) return film.posterURL;
  const suffix = film.posterURL ? "?v=" + encodeURIComponent(film.posterURL) : "";
  return mediaPath("/api/v2/cinema/" + film.id + "/poster" + suffix);
}

export function isCinemaFilmPosterReady(
  film: { id: number; posterURL?: string; probeStatus?: string },
  failed: Record<number, boolean>,
): boolean {
  return (
    Boolean(film.posterURL || film.probeStatus === "ready" || film.probeStatus === "unsupported") &&
    !failed[film.id]
  );
}

export function resolveCinemaSeriesPosterUrl(
  seriesId: number,
  rawUrl: string | undefined,
  mediaPath: (p: string) => string,
): string {
  return mediaPath("/api/v2/series/" + seriesId + "/poster" + (rawUrl ? "?v=" + encodeURIComponent(rawUrl) : ""));
}

export function resolveTmdbCandidatePosterUrl(
  rawUrl: string | undefined,
  mediaPath: (p: string) => string,
  useDirect: boolean,
): string {
  if (!rawUrl) return "";
  if (useDirect) return rawUrl;
  return mediaPath("/api/v2/cinema/tmdb-poster?url=" + encodeURIComponent(rawUrl));
}

