import type { LoginSession } from "../auth/useAccountSessions.ts";
import { formatDateTime } from "../../utils/dateTimeFormat.ts";

export type SessionDeviceIconKind =
  | "laptop"
  | "monitor"
  | "smartphone"
  | "tablet"
  | "app"
  | "globe";

export interface SessionPresentation {
  displayName: string;
  iconKind: SessionDeviceIconKind;
  isRecent: boolean;
  activityLabel: string;
  metaLine: string;
  fullTooltip: string;
}

const MINUTE_MS = 60_000;
const HOUR_MS = 60 * MINUTE_MS;
const DAY_MS = 24 * HOUR_MS;
const RECENT_WINDOW_MS = 30 * MINUTE_MS;

function pad2(value: number): string {
  return String(value).padStart(2, "0");
}

function formatCompactDate(unixSeconds: number, nowDate: Date): string {
  if (!Number.isFinite(unixSeconds) || unixSeconds <= 0) return "";
  const date = new Date(unixSeconds * 1000);
  if (!Number.isFinite(date.getTime())) return "";
  const month = pad2(date.getMonth() + 1);
  const day = pad2(date.getDate());
  if (date.getFullYear() === nowDate.getFullYear()) {
    return `${month}/${day}`;
  }
  return `${date.getFullYear()}/${month}/${day}`;
}

function formatClock(unixSeconds: number): string {
  const date = new Date(unixSeconds * 1000);
  if (!Number.isFinite(date.getTime())) return "";
  return `${pad2(date.getHours())}:${pad2(date.getMinutes())}`;
}

export function classifySessionDevice(
  session: Pick<LoginSession, "deviceLabel" | "userAgent" | "current">,
): { displayName: string; iconKind: SessionDeviceIconKind } {
  const rawLabel = (session.deviceLabel || "").trim();
  const displayName = rawLabel || (session.current ? "当前设备" : "未知终端");
  const probe = `${rawLabel} ${session.userAgent || ""}`.toLowerCase();

  if (/\b(ipad|tablet)\b/.test(probe)) {
    return { displayName, iconKind: "tablet" };
  }
  if (/\b(iphone|android|mobile)\b/.test(probe)) {
    return { displayName, iconKind: "smartphone" };
  }
  if (probe.includes("轻屿客户端") || probe.includes("lightisle")) {
    return { displayName, iconKind: "app" };
  }
  if (/\b(mac|macbook|macos|darwin|imac)\b/.test(probe)) {
    return { displayName, iconKind: "laptop" };
  }
  if (/\b(windows|win32|win64|linux|desktop)\b/.test(probe)) {
    return { displayName, iconKind: "monitor" };
  }
  return { displayName, iconKind: "globe" };
}

export function formatRelativeActivity(
  unixSeconds: number,
  nowMs = Date.now(),
): { label: string; isRecent: boolean } {
  if (!Number.isFinite(unixSeconds) || unixSeconds <= 0) {
    return { label: "活跃时间未知", isRecent: false };
  }
  const targetMs = unixSeconds * 1000;
  const diffMs = Math.max(0, nowMs - targetMs);
  const nowDate = new Date(nowMs);

  if (diffMs < 5 * MINUTE_MS) {
    return { label: "刚刚活跃", isRecent: true };
  }
  if (diffMs < RECENT_WINDOW_MS) {
    return { label: `${Math.floor(diffMs / MINUTE_MS)} 分钟前活跃`, isRecent: true };
  }
  if (diffMs < HOUR_MS) {
    return { label: `${Math.floor(diffMs / MINUTE_MS)} 分钟前活跃`, isRecent: false };
  }
  if (diffMs < DAY_MS) {
    const targetDate = new Date(targetMs);
    if (
      targetDate.getFullYear() === nowDate.getFullYear() &&
      targetDate.getMonth() === nowDate.getMonth() &&
      targetDate.getDate() === nowDate.getDate()
    ) {
      return { label: `今天 ${formatClock(unixSeconds)} 活跃`, isRecent: false };
    }
    return { label: `${Math.floor(diffMs / HOUR_MS)} 小时前活跃`, isRecent: false };
  }
  if (diffMs < 7 * DAY_MS) {
    return { label: `${Math.floor(diffMs / DAY_MS)} 天前活跃`, isRecent: false };
  }
  return { label: `${formatCompactDate(unixSeconds, nowDate)} 活跃`, isRecent: false };
}

export function presentLoginSession(
  session: LoginSession,
  nowMs = Date.now(),
): SessionPresentation {
  const { displayName, iconKind } = classifySessionDevice(session);
  const activeUnix = session.lastSeenAt || session.createdAt;
  const activity = session.current
    ? { label: "正在使用", isRecent: true }
    : formatRelativeActivity(activeUnix, nowMs);
  const nowDate = new Date(nowMs);

  const metaParts: string[] = [];
  if (session.clientIp) {
    metaParts.push(session.clientIp);
  }
  if (session.current) {
    const loginShort = formatCompactDate(session.createdAt, nowDate);
    if (loginShort) metaParts.push(`${loginShort} 登录`);
  } else {
    metaParts.push(activity.label);
  }
  const expiryShort = formatCompactDate(session.expiresAt, nowDate);
  if (expiryShort) {
    metaParts.push(`${expiryShort} 到期`);
  }

  const tooltipParts = [`登录：${formatDateTime(session.createdAt * 1000)}`];
  if (session.lastSeenAt) {
    tooltipParts.push(`最近活跃：${formatDateTime(session.lastSeenAt * 1000)}`);
  }
  tooltipParts.push(`到期：${formatDateTime(session.expiresAt * 1000)}`);
  if (session.clientIp) {
    tooltipParts.push(`IP：${session.clientIp}`);
  }

  return {
    displayName,
    iconKind,
    isRecent: activity.isRecent,
    activityLabel: activity.label,
    metaLine: metaParts.join(" · "),
    fullTooltip: tooltipParts.join("\n"),
  };
}

export function partitionLoginSessions(sessions: LoginSession[]): {
  currentSessions: LoginSession[];
  otherSessions: LoginSession[];
} {
  const currentSessions: LoginSession[] = [];
  const otherSessions: LoginSession[] = [];
  for (const session of sessions) {
    if (session.current) currentSessions.push(session);
    else otherSessions.push(session);
  }
  otherSessions.sort((a, b) => {
    const timeA = a.lastSeenAt || a.createdAt || 0;
    const timeB = b.lastSeenAt || b.createdAt || 0;
    return timeB - timeA;
  });
  return { currentSessions, otherSessions };
}
