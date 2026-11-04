export type ApiFailure = Error & { code: string | null; status: number | null };
export function apiErrorFromResponse(
  response: Pick<Response, "status">,
  payload?: unknown,
): ApiFailure;
export function readApiFailure(response: Response): Promise<ApiFailure>;
