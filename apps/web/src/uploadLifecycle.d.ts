export type UploadTaskState = { id: string; offset: number; size: number };

export function adoptUploadTask<T extends UploadTaskState>(
  state: T,
  rememberTaskID: (id: string) => void,
  ensureCurrent: () => void,
): T;

export function refreshAfterPublishedUpload(
  completedCount: number,
  refreshFiles: () => void | Promise<void>,
): Promise<void>;
