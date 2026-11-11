// Preserve the safe machine-readable code returned by Core. Never expose
// response bodies, URLs, cookies or arbitrary upstream text as error details.
const SAFE_CODE = /^[a-z][a-z0-9_.-]{1,63}$/;

export type ApiFailure = Error & { code: string | null; status: number | null };

export function apiErrorFromResponse(
  response: Pick<Response, "status"> | null | undefined,
  payload: unknown = {},
): ApiFailure {
  const raw =
    payload && typeof payload === "object" && "error" in payload
      ? (payload as { error?: unknown }).error
      : null;
  const code = typeof raw === "string" && SAFE_CODE.test(raw) ? raw : null;
  const rawStatus = response?.status;
  const status =
    typeof rawStatus === "number" &&
    Number.isInteger(rawStatus) &&
    rawStatus >= 100 &&
    rawStatus <= 599
      ? rawStatus
      : null;
  const error = Object.assign(
    new Error(code ?? (status ? `HTTP ${status}` : "request_failed")),
    {
      name: "ApiFailureError",
      code,
      status,
    },
  );
  return error;
}

export async function readApiFailure(response: Response): Promise<ApiFailure> {
  const payload = await response.json().catch(() => null);
  return apiErrorFromResponse(response, payload);
}
