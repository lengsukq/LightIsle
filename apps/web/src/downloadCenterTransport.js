// Read status first so an absent optional download service is distinct from
// a connection failure. Historical records remain useful without aria2.
export async function readDownloadCenter(api, signal) {
  const status = await api('/api/v2/downloads/status', { signal });
  if (!status || typeof status.available !== 'boolean') throw new Error('invalid_download_status');
  let tasks;
  try {
    const result = await api('/api/v2/downloads', { signal });
    tasks = result?.tasks ?? [];
    if (!Array.isArray(tasks) || tasks.some(task => !task || typeof task.id !== 'string' || typeof task.status !== 'string')) {
      throw new Error('invalid_download_tasks');
    }
  } catch (error) {
    // Older cores without a journal endpoint return this when unavailable.
    if (status.available || !(error instanceof Error) || error.message !== 'download_unavailable') throw error;
    tasks = [];
  }
  return { status, tasks };
}
