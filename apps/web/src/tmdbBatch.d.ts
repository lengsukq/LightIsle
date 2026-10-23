export function isTMDBAuthenticationFailure(error: unknown): boolean;

export function runSequentialTMDBBatch<T, R>(
  items: T[],
  search: (item: T, index: number) => Promise<R>,
  options?: {
    isCurrent?: () => boolean;
    onProgress?: (item: T, index: number, total: number) => void;
    onResult?: (item: T, result: R, index: number) => void;
  }
): Promise<{
  status: "completed" | "auth-rejected" | "cancelled";
  hadFailures: boolean;
}>;
