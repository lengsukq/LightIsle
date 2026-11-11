import { readApiFailure } from "./apiFailure.ts";

// A stale generation/ACL/quota 409 is NOT an offset conflict. Only an
// explicit offset_mismatch means the server permits reading and continuing
// the same upload session.
export async function recoverUploadOffset<T>(
  response: Response,
  reloadCurrentTask: () => Promise<T>,
): Promise<T> {
  const failure = await readApiFailure(response);
  if (response.status !== 409 || failure.code !== "offset_mismatch") throw failure;
  return reloadCurrentTask();
}
