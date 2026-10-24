export async function performFileOperationAndRefresh(operation, refreshFiles) {
  await operation();
  await refreshFiles();
}
