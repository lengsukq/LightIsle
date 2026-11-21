export type UploadTaskState = { id: string; offset: number; size: number };

export function adoptUploadTask<T extends UploadTaskState>(
  state: T,
  rememberTaskID: (id: string) => void,
  ensureCurrent: () => void,
): T {
  rememberTaskID(state.id);
  ensureCurrent();
  return state;
}

export async function refreshAfterPublishedUpload(
  completedCount: number,
  refreshFiles: () => void | Promise<unknown>,
): Promise<void> {
  if (completedCount > 0) await refreshFiles();
}
