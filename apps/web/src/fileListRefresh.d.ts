export function performFileOperationAndRefresh(
  operation: () => void | Promise<unknown>,
  refreshFiles: () => void | Promise<void>,
): Promise<void>;
