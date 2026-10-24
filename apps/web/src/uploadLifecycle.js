export function adoptUploadTask(state, rememberTaskID, ensureCurrent) {
  rememberTaskID(state.id);
  ensureCurrent();
  return state;
}

export async function refreshAfterPublishedUpload(completedCount, refreshFiles) {
  if (completedCount > 0) await refreshFiles();
}
