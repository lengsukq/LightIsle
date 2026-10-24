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

export function createUploadContinuation<T>(
  files: T[],
  firstUnfinishedIndex: number,
  context: UploadBatchContext,
): UploadContinuation<T> | null;

export function uploadContextMatches(
  targetContext: UploadBatchContext,
  currentContext: UploadBatchContext,
): boolean;

export function uploadContinuationIsCurrent<T>(
  continuation: UploadContinuation<T> | null,
  currentContext: UploadBatchContext,
): boolean;

export function trashPresentationState(
  state: { loading: boolean; error: string; entries: unknown[] },
): "loading" | "error" | "items" | "empty";
