import { ref, type Ref } from "vue";
import type { Movie } from "./cinemaTypes";

export type SubtitleSizePreset = "sm" | "md" | "lg";

export const SUBTITLE_SIZE_OPTIONS: Array<{ value: SubtitleSizePreset; label: string }> = [
  { value: "sm", label: "小" },
  { value: "md", label: "标准" },
  { value: "lg", label: "大" },
];

export type SubtitleCue = {
  start: number;
  end: number;
  text: string;
};

function stripBom(text: string): string {
  return text.replace(/^\uFEFF/, "");
}

function parseClockSeconds(raw: string): number {
  const normalized = raw.trim().replace(",", ".");
  const parts = normalized.split(":");
  if (parts.length === 2) {
    const mins = Number(parts[0]);
    const secs = Number(parts[1]);
    return Number.isFinite(mins) && Number.isFinite(secs) ? mins * 60 + secs : NaN;
  }
  if (parts.length === 3) {
    const hrs = Number(parts[0]);
    const mins = Number(parts[1]);
    const secs = Number(parts[2]);
    return Number.isFinite(hrs) && Number.isFinite(mins) && Number.isFinite(secs)
      ? hrs * 3600 + mins * 60 + secs
      : NaN;
  }
  return NaN;
}

export function formatVttTimestamp(seconds: number): string {
  const safe = Math.max(0, Number.isFinite(seconds) ? seconds : 0);
  const totalMs = Math.round(safe * 1000);
  const hrs = Math.floor(totalMs / 3_600_000);
  const mins = Math.floor((totalMs % 3_600_000) / 60_000);
  const secs = Math.floor((totalMs % 60_000) / 1000);
  const ms = totalMs % 1000;
  return `${String(hrs).padStart(2, "0")}:${String(mins).padStart(2, "0")}:${String(secs).padStart(2, "0")}.${String(ms).padStart(3, "0")}`;
}

function shiftAndFormatVtt(cues: SubtitleCue[], offsetSeconds: number): string {
  const delta = Number.isFinite(offsetSeconds) ? offsetSeconds : 0;
  const lines: string[] = ["WEBVTT", ""];
  for (const cue of cues) {
    const start = Math.max(0, cue.start + delta);
    const end = Math.max(start + 0.05, cue.end + delta);
    if (!cue.text.trim() || cue.end + delta <= 0) continue;
    lines.push(`${formatVttTimestamp(start)} --> ${formatVttTimestamp(end)}`);
    lines.push(cue.text.trim());
    lines.push("");
  }
  return lines.join("\n");
}

function parseSrtOrVttCues(rawText: string, isVtt: boolean): SubtitleCue[] {
  const lines = stripBom(rawText).replace(/\r\n?/g, "\n").split("\n");
  const cues: SubtitleCue[] = [];
  let i = 0;
  if (isVtt && lines[0]?.trim().toUpperCase().startsWith("WEBVTT")) {
    i = 1;
  }
  while (i < lines.length) {
    const line = lines[i].trim();
    if (!line) {
      i += 1;
      continue;
    }
    if (isVtt && (/^(NOTE|STYLE|REGION)\b/i.test(line))) {
      i += 1;
      while (i < lines.length && lines[i].trim() !== "") i += 1;
      continue;
    }
    let timeLine = line;
    if (!timeLine.includes("-->") && i + 1 < lines.length && lines[i + 1].includes("-->")) {
      i += 1;
      timeLine = lines[i].trim();
    }
    if (!timeLine.includes("-->")) {
      i += 1;
      continue;
    }
    const arrowIdx = timeLine.indexOf("-->");
    const startRaw = timeLine.slice(0, arrowIdx).trim();
    const endPart = timeLine.slice(arrowIdx + 3).trim().split(/\s+/)[0] || "";
    const start = parseClockSeconds(startRaw);
    const end = parseClockSeconds(endPart);
    i += 1;
    const textLines: string[] = [];
    while (i < lines.length && lines[i].trim() !== "") {
      textLines.push(lines[i].replace(/<[^>]+>/g, (tag) => (/^<\/?(b|i|u|c(\.[^>]*)?)>$/i.test(tag) ? tag : "")));
      i += 1;
    }
    if (Number.isFinite(start) && Number.isFinite(end) && end > start && textLines.length) {
      cues.push({ start, end, text: textLines.join("\n") });
    }
  }
  return cues;
}

function cleanAssDialogueText(raw: string): string {
  return raw
    .replace(/\{[^}]*\}/g, "")
    .replace(/\\N/gi, "\n")
    .replace(/\\n/g, "\n")
    .replace(/\\h/g, " ")
    .trim();
}

function parseAssOrSsaCues(rawText: string): SubtitleCue[] {
  const lines = stripBom(rawText).replace(/\r\n?/g, "\n").split("\n");
  const cues: SubtitleCue[] = [];
  let inEvents = false;
  let formatCols = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"];
  for (const rawLine of lines) {
    const trimmed = rawLine.trim();
    if (!trimmed) continue;
    if (trimmed.startsWith("[")) {
      inEvents = trimmed.toLowerCase() === "[events]";
      continue;
    }
    if (!inEvents) continue;
    if (trimmed.toLowerCase().startsWith("format:")) {
      formatCols = trimmed
        .slice("format:".length)
        .split(",")
        .map((c) => c.trim().toLowerCase());
      continue;
    }
    if (!trimmed.toLowerCase().startsWith("dialogue:")) continue;
    const body = trimmed.slice("dialogue:".length).trimStart();
    const fields: string[] = [];
    let startIdx = 0;
    const maxSplit = Math.max(0, formatCols.length - 1);
    for (let k = 0; k < maxSplit; k += 1) {
      const comma = body.indexOf(",", startIdx);
      if (comma < 0) break;
      fields.push(body.slice(startIdx, comma).trim());
      startIdx = comma + 1;
    }
    fields.push(body.slice(startIdx));
    const startCol = formatCols.indexOf("start");
    const endCol = formatCols.indexOf("end");
    const textCol = formatCols.indexOf("text");
    if (startCol < 0 || endCol < 0 || textCol < 0) continue;
    const start = parseClockSeconds(fields[startCol] || "");
    const end = parseClockSeconds(fields[endCol] || "");
    const text = cleanAssDialogueText(fields[textCol] || "");
    if (Number.isFinite(start) && Number.isFinite(end) && end > start && text) {
      cues.push({ start, end, text });
    }
  }
  return cues;
}

export function parseSubtitleToWebVtt(rawText: string, fileName: string, offsetSeconds = 0): string {
  const lower = fileName.toLowerCase();
  let cues: SubtitleCue[];
  if (lower.endsWith(".ass") || lower.endsWith(".ssa")) {
    cues = parseAssOrSsaCues(rawText);
  } else if (lower.endsWith(".vtt")) {
    cues = parseSrtOrVttCues(rawText, true);
  } else {
    cues = parseSrtOrVttCues(rawText, false);
  }
  return shiftAndFormatVtt(cues, offsetSeconds);
}

export function formatCinemaEpisodeCode(season?: number, episode?: number): string {
  if (!season && !episode) return "";
  const s = season && season > 0 ? `S${String(season).padStart(2, "0")}` : "";
  const e = episode && episode > 0 ? `E${String(episode).padStart(2, "0")}` : "";
  return `${s}${e}`;
}

export function formatCinemaResumeLabel(input: {
  season?: number;
  episode?: number;
  position?: number;
  duration?: number;
}): string {
  const code = formatCinemaEpisodeCode(input.season, input.episode);
  const pos = Number(input.position || 0);
  const dur = Number(input.duration || 0);
  const remainMins = dur > pos && dur > 0 ? Math.max(1, Math.round((dur - pos) / 60)) : 0;
  const parts = ["继续播放"];
  if (code) parts[0] = `继续播放 ${code}`;
  if (remainMins > 0) parts.push(`剩余 ${remainMins} 分钟`);
  return parts.join(" · ");
}

export function pickInitialSeriesSeason(films: Movie[], nextFilmId?: number): number {
  if (!films.length) return 0;
  if (nextFilmId) {
    const target = films.find((item) => item.id === nextFilmId);
    if (target?.season && target.season > 0) return target.season;
  }
  const inProgress = films.find((item) => (item.position || 0) > 5 && !item.completed && (item.season || 0) > 0);
  if (inProgress?.season) return inProgress.season;
  const unwatched = films.find((item) => !item.completed && (item.season || 0) > 0);
  if (unwatched?.season) return unwatched.season;
  const firstWithSeason = films.find((item) => (item.season || 0) > 0);
  return firstWithSeason?.season || 0;
}

export type CueBaselineMap = WeakMap<TextTrackCue, { start: number; end: number }>;

export function applyTextTracksOffset(
  video: { textTracks?: ArrayLike<{ cues?: ArrayLike<{ startTime: number; endTime: number }> | null }> } | null | undefined,
  offsetSeconds: number,
  baselines: WeakMap<object, { start: number; end: number }>,
) {
  if (!video?.textTracks) return;
  const delta = Number.isFinite(offsetSeconds) ? offsetSeconds : 0;
  for (const track of Array.from(video.textTracks)) {
    const cues = track.cues;
    if (!cues) continue;
    for (const cue of Array.from(cues)) {
      let base = baselines.get(cue);
      if (!base) {
        base = { start: cue.startTime, end: cue.endTime };
        baselines.set(cue, base);
      }
      const nextStart = Math.max(0, base.start + delta);
      const minDur = Math.max(0.05, base.end - base.start);
      const nextEnd = Math.max(nextStart + minDur, base.end + delta);
      try {
        cue.startTime = nextStart;
        cue.endTime = nextEnd;
      } catch {
        /* Read-only cue implementations ignore live mutation. */
      }
    }
  }
}

function readSubSizePref(): SubtitleSizePreset {
  try {
    const val = window.localStorage.getItem("lightisle-cinema-sub-size");
    return val === "sm" || val === "lg" || val === "md" ? val : "md";
  } catch {
    return "md";
  }
}

export function useCinemaSubtitles({
  caption,
  player,
  hlsPlayer,
  changeCaption,
  baseTrack,
}: {
  caption: Ref<string>;
  player: Ref<HTMLVideoElement | null>;
  hlsPlayer: Ref<HTMLVideoElement | null>;
  changeCaption: () => Promise<void>;
  baseTrack: (v: Movie) => string;
}) {
  const subtitleSize = ref<SubtitleSizePreset>(readSubSizePref());
  const subtitleOffset = ref(0);
  const localSubtitleName = ref("");
  const localSubtitleError = ref("");
  const localSubtitleRaw = ref("");
  const localSubtitleUrl = ref("");
  const cueBaselines = new WeakMap<object, { start: number; end: number }>();

  function revokeLocalSubtitleUrl() {
    if (localSubtitleUrl.value) {
      URL.revokeObjectURL(localSubtitleUrl.value);
      localSubtitleUrl.value = "";
    }
  }

  function rebuildLocalSubtitleBlob() {
    revokeLocalSubtitleUrl();
    if (!localSubtitleRaw.value || !localSubtitleName.value) return;
    const vtt = parseSubtitleToWebVtt(localSubtitleRaw.value, localSubtitleName.value, subtitleOffset.value);
    localSubtitleUrl.value = URL.createObjectURL(new Blob([vtt], { type: "text/vtt;charset=utf-8" }));
  }

  function applySubtitleCueOffsets() {
    if (caption.value === "local") return;
    for (const video of [player.value, hlsPlayer.value]) {
      applyTextTracksOffset(video, subtitleOffset.value, cueBaselines);
    }
  }

  async function loadLocalSubtitleFile(file: File) {
    localSubtitleError.value = "";
    if (!/\.(srt|ass|ssa|vtt)$/i.test(file.name)) {
      localSubtitleError.value = "仅支持 .srt、.ass、.ssa 或 .vtt 字幕文件。";
      return;
    }
    try {
      const text = await file.text();
      const vtt = parseSubtitleToWebVtt(text, file.name, subtitleOffset.value);
      if (!vtt.includes("-->")) {
        localSubtitleError.value = "未能从字幕文件中识别有效时间轴，请检查编码（推荐 UTF-8）。";
        return;
      }
      localSubtitleRaw.value = text;
      localSubtitleName.value = file.name;
      rebuildLocalSubtitleBlob();
      caption.value = "local";
      await changeCaption();
    } catch {
      localSubtitleError.value = "读取本地字幕失败，请确认文件可读。";
    }
  }

  function clearLocalSubtitle() {
    revokeLocalSubtitleUrl();
    localSubtitleRaw.value = "";
    localSubtitleName.value = "";
    localSubtitleError.value = "";
    if (caption.value === "local") {
      caption.value = "off";
      void changeCaption();
    }
  }

  function setSubtitleSize(size: SubtitleSizePreset) {
    subtitleSize.value = size;
    try {
      window.localStorage.setItem("lightisle-cinema-sub-size", size);
    } catch {
      /* Ignore storage quota limits. */
    }
  }

  function adjustSubtitleOffset(deltaSeconds: number) {
    subtitleOffset.value = Math.max(-30, Math.min(30, Math.round((subtitleOffset.value + deltaSeconds) * 10) / 10));
    if (localSubtitleRaw.value) {
      rebuildLocalSubtitleBlob();
      if (caption.value === "local") void changeCaption();
    } else {
      applySubtitleCueOffsets();
    }
  }

  function resetSubtitleOffset() {
    subtitleOffset.value = 0;
    if (localSubtitleRaw.value) {
      rebuildLocalSubtitleBlob();
      if (caption.value === "local") void changeCaption();
    } else {
      applySubtitleCueOffsets();
    }
  }

  function track(v: Movie): string {
    return caption.value === "local" && localSubtitleUrl.value ? localSubtitleUrl.value : baseTrack(v);
  }

  function captionLoaded() {
    void changeCaption();
    applySubtitleCueOffsets();
  }

  return {
    subtitleSize,
    subtitleOffset,
    localSubtitleName,
    localSubtitleError,
    applySubtitleCueOffsets,
    loadLocalSubtitleFile,
    clearLocalSubtitle,
    setSubtitleSize,
    adjustSubtitleOffset,
    resetSubtitleOffset,
    track,
    captionLoaded,
  };
}
