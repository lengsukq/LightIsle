export type PublishedDownloadFile = { target: string; size: number; status: string };
export type DownloadTask = {
  id: string; url: string; destination: string; status: 'queued' | 'running' | 'paused' | 'completed' | 'failed' | 'cancelled';
  phase?: string; filename?: string; totalBytes: number; completedBytes: number; maxBytes: number;
  error?: string; createdAt: number; updatedAt: number; completedAt?: number;
  partialPublish?: boolean; recoveryRequired?: boolean; publishedFiles?: PublishedDownloadFile[];
  publishedFilesTotal?: number; publishedFilesTruncated?: boolean;
};
export function readDownloadCenter(
  api: (path: string, init?: RequestInit) => Promise<unknown>, signal?: AbortSignal,
): Promise<{ status: { available: boolean; version?: string; reason?: string }; tasks: DownloadTask[] }>;
