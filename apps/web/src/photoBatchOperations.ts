import { rootMediaPath } from "./rootApi.ts";

export type PhotoBatchItem = { id: number; path: string; name: string };

export type PhotoBatchResult = {
  completed: PhotoBatchItem[];
  stopped: boolean;
  remaining: PhotoBatchItem[];
  failure: { item: PhotoBatchItem; error: unknown } | null;
};

export function photoShareUrl(
  origin: string,
  rootId: string | undefined,
  generation: number,
  token: string,
): string {
  if (typeof token !== "string" || !/^[A-Za-z0-9_-]{20,256}$/.test(token)) {
    throw new Error("share_result_uncertain");
  }
  return (
    origin + rootMediaPath(rootId, generation, "/api/v2/public/file/" + encodeURIComponent(token))
  );
}

export function photoArchivePath(ids: number[]): string {
  if (
    !Array.isArray(ids) ||
    !ids.length ||
    ids.length > 50 ||
    ids.some((id) => !Number.isSafeInteger(id) || id < 1) ||
    new Set(ids).size !== ids.length
  ) {
    throw new Error("invalid_archive_selection");
  }
  return "/api/v2/photos/archive?" + new URLSearchParams({ ids: ids.join(",") }).toString();
}

// A delayed preflight must never start a download after switching roots or
// changing the selection. Browsers report the actual transfer outcome.
export async function preparePhotoArchive(
  url: string,
  stillCurrent: () => boolean,
  head: (url: string) => Promise<{ ok: boolean; status: number }>,
  startDownload: (url: string) => void,
): Promise<{ started: boolean; stopped: boolean; status: number | null }> {
  if (!stillCurrent()) return { started: false, stopped: true, status: null };
  const response = await head(url);
  if (!stillCurrent()) return { started: false, stopped: true, status: null };
  if (!response.ok) return { started: false, stopped: false, status: response.status };
  startDownload(url);
  return { started: true, stopped: false, status: null };
}

// Each request is individually committed. Freeze the original selection and
// stop as soon as a request or the surrounding root/view becomes uncertain.
export async function runPhotoBatch(
  items: PhotoBatchItem[],
  perform: (item: PhotoBatchItem) => Promise<void>,
  stillCurrent: () => boolean,
): Promise<PhotoBatchResult> {
  const frozen = items.map((item) => ({ id: item.id, path: item.path, name: item.name }));
  if (
    !frozen.length ||
    frozen.length > 50 ||
    frozen.some(
      (item) =>
        !Number.isSafeInteger(item.id) ||
        item.id < 1 ||
        typeof item.path !== "string" ||
        !item.path ||
        typeof item.name !== "string" ||
        !item.name,
    ) ||
    new Set(frozen.map((item) => item.id)).size !== frozen.length
  ) {
    throw new Error("请选择 1–50 个有效且不重复的媒体文件。");
  }
  const completed: PhotoBatchItem[] = [];
  for (let index = 0; index < frozen.length; index++) {
    if (!stillCurrent()) {
      return { completed, stopped: true, remaining: frozen.slice(index), failure: null };
    }
    try {
      await perform(frozen[index]);
    } catch (error) {
      return {
        completed,
        stopped: !stillCurrent(),
        remaining: frozen.slice(index + 1),
        failure: { item: frozen[index], error },
      };
    }
    // Even after a success response the old view may have been replaced.
    // Count the confirmed item but never start the next write in that case.
    completed.push(frozen[index]);
    if (!stillCurrent()) {
      return { completed, stopped: true, remaining: frozen.slice(index + 1), failure: null };
    }
  }
  return { completed, stopped: false, remaining: [], failure: null };
}
