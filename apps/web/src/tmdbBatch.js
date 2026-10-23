const TMDB_AUTH_ERRORS = new Set(["tmdb_auth_failed", "tmdb_access_denied"]);

/** @param {unknown} error */
export function isTMDBAuthenticationFailure(error) {
  return error instanceof Error && TMDB_AUTH_ERRORS.has(error.message);
}

/**
 * Run searches sequentially and stop as soon as TMDB rejects the supplied
 * credentials. `isCurrent` prevents results from an old root/view being used.
 *
 * @template T, R
 * @param {T[]} items
 * @param {(item: T, index: number) => Promise<R>} search
 * @param {{
 *   isCurrent?: () => boolean,
 *   onProgress?: (item: T, index: number, total: number) => void,
 *   onResult?: (item: T, result: R, index: number) => void
 * }=} options
 * @returns {Promise<{status: "completed" | "auth-rejected" | "cancelled", hadFailures: boolean}>}
 */
export async function runSequentialTMDBBatch(items, search, options = {}) {
  const isCurrent = options.isCurrent ?? (() => true);
  let hadFailures = false;
  for (let index = 0; index < items.length; index += 1) {
    if (!isCurrent()) return {status: "cancelled", hadFailures};
    const item = items[index];
    options.onProgress?.(item, index, items.length);
    try {
      const result = await search(item, index);
      if (!isCurrent()) return {status: "cancelled", hadFailures};
      options.onResult?.(item, result, index);
    } catch (error) {
      if (!isCurrent()) return {status: "cancelled", hadFailures};
      if (isTMDBAuthenticationFailure(error)) {
        return {status: "auth-rejected", hadFailures};
      }
      hadFailures = true;
    }
  }
  return {status: "completed", hadFailures};
}
