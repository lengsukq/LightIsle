const TMDB_AUTH_ERRORS = new Set(["tmdb_auth_failed", "tmdb_access_denied"]);

export function isTMDBAuthenticationFailure(error: unknown): boolean {
  return error instanceof Error && TMDB_AUTH_ERRORS.has(error.message);
}

/**
 * Run searches sequentially and stop as soon as TMDB rejects the supplied
 * credentials. `isCurrent` prevents results from an old root/view being used.
 */
export async function runSequentialTMDBBatch<T, R>(
  items: T[],
  search: (item: T, index: number) => Promise<R>,
  options: {
    isCurrent?: () => boolean;
    onProgress?: (item: T, index: number, total: number) => void;
    onResult?: (item: T, result: R, index: number) => void;
  } = {},
): Promise<{ status: "completed" | "auth-rejected" | "cancelled"; hadFailures: boolean }> {
  const isCurrent = options.isCurrent ?? (() => true);
  let hadFailures = false;
  for (let index = 0; index < items.length; index += 1) {
    if (!isCurrent()) return { status: "cancelled", hadFailures };
    const item = items[index];
    options.onProgress?.(item, index, items.length);
    try {
      const result = await search(item, index);
      if (!isCurrent()) return { status: "cancelled", hadFailures };
      options.onResult?.(item, result, index);
    } catch (error) {
      if (!isCurrent()) return { status: "cancelled", hadFailures };
      if (isTMDBAuthenticationFailure(error)) {
        return { status: "auth-rejected", hadFailures };
      }
      hadFailures = true;
    }
  }
  return { status: "completed", hadFailures };
}
