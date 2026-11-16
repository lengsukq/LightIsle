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
