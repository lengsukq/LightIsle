const MAX_FORMAT_CACHE_SIZE = 512;

const dateTimeFormatter = new Intl.DateTimeFormat("zh-CN", {
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
  hour12: false,
});

const shortDateFormatter = new Intl.DateTimeFormat("zh-CN", {
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
});

const dateTimeCache = new Map<string, string>();
const shortDateCache = new Map<number, string>();

function rememberFormat<K>(cache: Map<K, string>, key: K, formatted: string): string {
  if (cache.size >= MAX_FORMAT_CACHE_SIZE) {
    const oldest = cache.keys().next().value;
    if (oldest !== undefined) cache.delete(oldest);
  }
  cache.set(key, formatted);
  return formatted;
}

/** Format an ISO timestamp or epoch milliseconds value with a shared Intl formatter and bounded cache. */
export function formatDateTime(value: string | number | null | undefined): string {
  if (value === "" || value === null || value === undefined) return "";
  const cacheKey = typeof value === "number" ? `n:${value}` : `s:${value}`;
  const cached = dateTimeCache.get(cacheKey);
  if (cached !== undefined) return cached;

  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) return "";
  return rememberFormat(dateTimeCache, cacheKey, dateTimeFormatter.format(date));
}

/** Format Unix epoch seconds into a short date string with a shared Intl formatter and bounded cache. */
export function formatShortDate(unixSeconds?: number | null): string {
  if (unixSeconds === null || unixSeconds === undefined || !Number.isFinite(unixSeconds) || unixSeconds <= 0) {
    return "";
  }
  const normalized = Math.trunc(unixSeconds);
  const cached = shortDateCache.get(normalized);
  if (cached !== undefined) return cached;

  const date = new Date(normalized * 1000);
  if (!Number.isFinite(date.getTime())) return "";
  return rememberFormat(shortDateCache, normalized, shortDateFormatter.format(date));
}
