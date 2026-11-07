/**
 * Move actual media originals into the same NAS trash used by File Manager.
 * Keep the physical-root selection frozen until the request completes.
 *
 * @param {string[]} paths
 * @param {(paths: string[]) => Promise<{results: Array<{path?:string,success:boolean,error?:string}>}>} request
 * @param {() => boolean} stillCurrent
 */
export async function trashMediaOriginals(paths, request, stillCurrent) {
  const frozen = [...paths];
  if (!frozen.length || frozen.length > 50 ||
      frozen.some(path => !path || path.length > 1024) ||
      new Set(frozen).size !== frozen.length) {
    throw new Error("每次只能选择 1–50 个不重复的原文件。");
  }
  if (!stillCurrent()) return { completed: 0, cancelled: true, failed: frozen, needsRootCheck: false };
  const reply = await request(frozen);
  if (!stillCurrent()) return { completed: 0, cancelled: true, failed: frozen, needsRootCheck: false };
  if (!Array.isArray(reply?.results) || reply.results.length !== frozen.length) {
    throw new Error("服务器未返回完整结果，请检查原目录和回收站。");
  }
  const completed = reply.results.filter(row => row?.success === true).length;
  const failed = reply.results.filter(row => row?.success !== true).map(row => row.path ?? "");
  const needsRootCheck = reply.results.some(row => row?.error === "storage_operation_uncertain" || row?.error === "root_unavailable");
  return { completed, cancelled: false, failed, needsRootCheck };
}
