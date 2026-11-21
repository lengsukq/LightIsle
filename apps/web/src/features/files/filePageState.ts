export type UploadBatchContext = {
  username: string;
  rootID: string;
  rootGeneration: number;
  rootEpoch: number;
  directory: string;
};

export type UploadContinuation<T = File> = {
  files: T[];
  context: UploadBatchContext;
};

const uploadContextFields: Array<keyof UploadBatchContext> = [
  "username",
  "rootID",
  "rootGeneration",
  "rootEpoch",
  "directory",
];

export function createUploadContinuation<T>(
  files: T[],
  firstUnfinishedIndex: number,
  context: UploadBatchContext,
): UploadContinuation<T> | null {
  if (!Array.isArray(files) || !Number.isInteger(firstUnfinishedIndex) || firstUnfinishedIndex < 0) {
    return null;
  }
  const unfinishedFiles = files.slice(firstUnfinishedIndex);
  return unfinishedFiles.length ? { files: unfinishedFiles, context } : null;
}

export function uploadContextMatches(
  targetContext: UploadBatchContext,
  currentContext: UploadBatchContext,
): boolean {
  return uploadContextFields.every((field) => targetContext[field] === currentContext[field]);
}

export function uploadContinuationIsCurrent<T>(
  continuation: UploadContinuation<T> | null | undefined,
  currentContext: UploadBatchContext,
): boolean {
  return (
    Boolean(continuation?.files.length) &&
    Boolean(continuation && uploadContextMatches(continuation.context, currentContext))
  );
}

export function trashPresentationState({
  loading,
  error,
  entries,
}: {
  loading: boolean;
  error: string;
  entries: unknown[];
}): "loading" | "error" | "items" | "empty" {
  if (loading) return "loading";
  if (error) return "error";
  return entries.length ? "items" : "empty";
}
