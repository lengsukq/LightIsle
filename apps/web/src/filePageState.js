const uploadContextFields = ["username", "rootID", "rootGeneration", "rootEpoch", "directory"];

export function createUploadContinuation(files, firstUnfinishedIndex, context) {
  if (!Array.isArray(files) || !Number.isInteger(firstUnfinishedIndex) || firstUnfinishedIndex < 0) return null;
  const unfinishedFiles = files.slice(firstUnfinishedIndex);
  return unfinishedFiles.length ? { files: unfinishedFiles, context } : null;
}

export function uploadContextMatches(targetContext, currentContext) {
  return uploadContextFields.every((field) => targetContext[field] === currentContext[field]);
}

export function uploadContinuationIsCurrent(continuation, currentContext) {
  return Boolean(continuation?.files.length) && uploadContextMatches(continuation.context, currentContext);
}

export function trashPresentationState({ loading, error, entries }) {
  if (loading) return "loading";
  if (error) return "error";
  return entries.length ? "items" : "empty";
}
