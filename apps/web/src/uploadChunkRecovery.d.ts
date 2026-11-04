export function recoverUploadOffset<T>(
  response: Response,
  reloadCurrentTask: () => Promise<T>,
): Promise<T>;
