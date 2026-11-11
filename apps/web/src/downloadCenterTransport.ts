export type PublishedDownloadFile = { target: string; size: number; status: string };

export type DownloadTask = {
  id: string;
  url: string;
  destination: string;
  status: "queued" | "running" | "paused" | "completed" | "failed" | "cancelled";
  phase?: string;
  filename?: string;
  totalBytes: number;
  completedBytes: number;
  maxBytes: number;
  error?: string;
  createdAt: number;
  updatedAt: number;
  completedAt?: number;
  partialPublish?: boolean;
  recoveryRequired?: boolean;
  publishedFiles?: PublishedDownloadFile[];
  publishedFilesTotal?: number;
  publishedFilesTruncated?: boolean;
};

export type DownloadStatus = {
  available: boolean;
  networkAllowed?: boolean;
  version?: string;
  reason?: string;
};

// Read status first so an absent optional download service is distinct from
// a connection failure. Historical records remain useful without aria2.
export async function readDownloadCenter(
  api: (path: string, init?: RequestInit) => Promise<unknown>,
  signal?: AbortSignal,
): Promise<{ status: DownloadStatus; tasks: DownloadTask[] }> {
  const status = (await api("/api/v2/downloads/status", { signal })) as DownloadStatus | null;
  if (!status || typeof status.available !== "boolean") {
    throw new Error("invalid_download_status");
  }
  let tasks: DownloadTask[];
  try {
    const result = (await api("/api/v2/downloads", { signal })) as { tasks?: unknown } | null;
    const rawTasks = result?.tasks ?? [];
    if (
      !Array.isArray(rawTasks) ||
      rawTasks.some(
        (task) =>
          !task ||
          typeof (task as Record<string, unknown>).id !== "string" ||
          typeof (task as Record<string, unknown>).status !== "string",
      )
    ) {
      throw new Error("invalid_download_tasks");
    }
    tasks = rawTasks as DownloadTask[];
  } catch (error) {
    // Older cores without a journal endpoint return this when unavailable.
    if (
      status.available ||
      !(error instanceof Error) ||
      error.message !== "download_unavailable"
    ) {
      throw error;
    }
    tasks = [];
  }
  return { status, tasks };
}
