export type PublishedDownloadFile = { target: string; size: number; status: string };

export type DownloadEngine = "aria2" | "ytdlp" | "webarchive";
export type VideoQualityFormat = "best" | "1080p" | "720p" | "audio";

export type DownloadEngineOptions = {
  allowPlaylist?: boolean;
  playlistMaxItems?: number;
  format?: VideoQualityFormat | string;
};

export type DownloadTask = {
  id: string;
  engine?: DownloadEngine | string;
  options?: DownloadEngineOptions;
  url: string;
  destination: string;
  status: "queued" | "running" | "paused" | "completed" | "failed" | "cancelled";
  phase?: string;
  filename?: string;
  totalBytes: number;
  completedBytes: number;
  maxBytes: number;
  error?: string;
  createdAt: number;
  updatedAt: number;
  completedAt?: number;
  partialPublish?: boolean;
  recoveryRequired?: boolean;
  publishedFiles?: PublishedDownloadFile[];
  publishedFilesTotal?: number;
  publishedFilesTruncated?: boolean;
};

export type DownloadStatus = {
  available: boolean;
  networkAllowed?: boolean;
  version?: string;
  reason?: string;
  aria2Available?: boolean;
  aria2Version?: string;
  aria2Reason?: string;
  ytdlpAvailable?: boolean;
  ytdlpVersion?: string;
  ytdlpReason?: string;
  webArchiveAvailable?: boolean;
};

export type EngineAvailability = {
  aria2: boolean;
  aria2Version: string;
  aria2Reason: string;
  ytdlp: boolean;
  ytdlpVersion: string;
  ytdlpReason: string;
  webarchive: boolean;
  anyAvailable: boolean;
};

export const DOWNLOAD_ENGINE_MODES: ReadonlyArray<{
  id: DownloadEngine;
  label: string;
  shortLabel: string;
  badgeText: string;
  placeholder: string;
  submitLabel: string;
}> = [
  {
    id: "aria2",
    label: "常规/磁力 (aria2)",
    shortLabel: "常规/磁力",
    badgeText: "aria2",
    placeholder: "粘贴直链（HTTP / HTTPS / FTP）或磁力链接…",
    submitLabel: "开始下载",
  },
  {
    id: "ytdlp",
    label: "视频归档 (yt-dlp)",
    shortLabel: "视频归档",
    badgeText: "yt-dlp",
    placeholder: "粘贴视频页面链接（YouTube / Bilibili 等 HTTP / HTTPS 链接）…",
    submitLabel: "归档视频",
  },
  {
    id: "webarchive",
    label: "网页离线保存 (webarchive)",
    shortLabel: "网页离线保存",
    badgeText: "网页归档",
    placeholder: "粘贴文章或网页链接（HTTP / HTTPS），保存为离线单文件 HTML…",
    submitLabel: "离线保存网页",
  },
];

export const YTDLP_FORMAT_OPTIONS: ReadonlyArray<{ value: VideoQualityFormat; label: string }> = [
  { value: "best", label: "最佳画质（默认）" },
  { value: "1080p", label: "1080p 高清" },
  { value: "720p", label: "720p 流畅" },
  { value: "audio", label: "仅提取音频" },
];

export const YTDLP_INSTALL_COMMAND = "brew install yt-dlp";

export function normalizeDownloadEngine(engine?: string): DownloadEngine {
  if (engine === "ytdlp" || engine === "webarchive" || engine === "aria2") {
    return engine;
  }
  return "aria2";
}

export function downloadEngineLabel(engine?: string): string {
  const normalized = normalizeDownloadEngine(engine);
  return DOWNLOAD_ENGINE_MODES.find((m) => m.id === normalized)?.shortLabel ?? "常规/磁力";
}

export function formatVideoQualityLabel(format?: string): string {
  switch (format) {
    case "1080p":
      return "1080p";
    case "720p":
      return "720p";
    case "audio":
      return "仅音频";
    case "best":
      return "最佳画质";
    default:
      return "";
  }
}

export function resolveEngineAvailability(status: DownloadStatus): EngineAvailability {
  const aria2 = typeof status.aria2Available === "boolean" ? status.aria2Available : Boolean(status.available);
  const ytdlp = status.ytdlpAvailable === true;
  const webarchive = status.webArchiveAvailable === true;
  return {
    aria2,
    aria2Version: status.aria2Version || status.version || "",
    aria2Reason: status.aria2Reason || status.reason || "",
    ytdlp,
    ytdlpVersion: status.ytdlpVersion || "",
    ytdlpReason: status.ytdlpReason || (ytdlp ? "" : "ytdlp_not_installed"),
    webarchive,
    anyAvailable: aria2 || ytdlp || webarchive,
  };
}

export function isEngineRunnable(engine: DownloadEngine, status: DownloadStatus): boolean {
  if (status.networkAllowed === false) return false;
  const avail = resolveEngineAvailability(status);
  if (engine === "ytdlp") return avail.ytdlp;
  if (engine === "webarchive") return avail.webarchive;
  return avail.aria2;
}

export function validateDownloadUrlForEngine(engine: DownloadEngine, rawUrl: string): string {
  const trimmed = rawUrl.trim();
  if (!trimmed) {
    if (engine === "ytdlp") return "请输入视频页面 HTTP/HTTPS 链接。";
    if (engine === "webarchive") return "请输入需要离线保存的 HTTP/HTTPS 网页链接。";
    return "请输入 http/https/ftp 或磁力链接。";
  }
  const lower = trimmed.toLowerCase();
  if (engine === "aria2") {
    if (
      lower.startsWith("http://") ||
      lower.startsWith("https://") ||
      lower.startsWith("ftp://") ||
      lower.startsWith("magnet:?")
    ) {
      return "";
    }
    return "常规下载仅支持 http://、https://、ftp:// 或 magnet:? 链接。";
  }
  if (lower.startsWith("http://") || lower.startsWith("https://")) {
    return "";
  }
  return engine === "ytdlp"
    ? "视频归档仅支持 http:// 或 https:// 网页链接。"
    : "网页离线保存仅支持 http:// 或 https:// 网页链接。";
}

export function buildDownloadCreatePayload(input: {
  engine: DownloadEngine;
  url: string;
  destination: string;
  maxBytes: number;
  format?: VideoQualityFormat;
  allowPlaylist?: boolean;
  playlistMaxItems?: number;
}): {
  url: string;
  destination: string;
  maxBytes: number;
  engine: DownloadEngine;
  options?: DownloadEngineOptions;
} {
  const payload: {
    url: string;
    destination: string;
    maxBytes: number;
    engine: DownloadEngine;
    options?: DownloadEngineOptions;
  } = {
    url: input.url.trim(),
    destination: input.destination.trim() || ".",
    maxBytes: input.maxBytes,
    engine: input.engine,
  };
  if (input.engine === "ytdlp") {
    const options: DownloadEngineOptions = {
      format: input.format || "best",
    };
    if (input.allowPlaylist) {
      options.allowPlaylist = true;
      const clamped = Math.max(1, Math.min(20, Math.round(Number(input.playlistMaxItems) || 10)));
      options.playlistMaxItems = clamped;
    }
    payload.options = options;
  }
  return payload;
}

// Read status first so an absent optional download service is distinct from
// a connection failure. Historical records remain useful without aria2.
export async function readDownloadCenter(
  api: (path: string, init?: RequestInit) => Promise<unknown>,
  signal?: AbortSignal,
): Promise<{ status: DownloadStatus; tasks: DownloadTask[] }> {
  const status = (await api("/api/v2/downloads/status", { signal })) as DownloadStatus | null;
  if (!status || typeof status.available !== "boolean") {
    throw new Error("invalid_download_status");
  }
  let tasks: DownloadTask[];
  try {
    const result = (await api("/api/v2/downloads", { signal })) as { tasks?: unknown } | null;
    const rawTasks = result?.tasks ?? [];
    if (
      !Array.isArray(rawTasks) ||
      rawTasks.some(
        (task) =>
          !task ||
          typeof (task as Record<string, unknown>).id !== "string" ||
          typeof (task as Record<string, unknown>).status !== "string",
      )
    ) {
      throw new Error("invalid_download_tasks");
    }
    tasks = rawTasks as DownloadTask[];
  } catch (error) {
    // Older cores without a journal endpoint return this when unavailable.
    if (
      status.available ||
      !(error instanceof Error) ||
      error.message !== "download_unavailable"
    ) {
      throw error;
    }
    tasks = [];
  }
  return { status, tasks };
}
