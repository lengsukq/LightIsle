// Preserve the safe machine-readable code returned by Core. Never expose
// response bodies, URLs, cookies or arbitrary upstream text as error details.
import { diagnosticID, diagnosticResponseGeneration, newLocalDiagnosticID, recordDiagnostic } from "./betaDiagnostics.ts";

const SAFE_CODE = /^[a-z][a-z0-9_.-]{1,63}$/;

export type ApiFailure = Error & { code: string | null; status: number | null; requestID: string | null };

export function apiErrorFromResponse(
  response: (Pick<Response, "status"> & Partial<Pick<Response, "headers">>) | null | undefined,
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
      requestID: diagnosticID(response?.headers?.get("X-Request-ID")),
    },
  );
  return error;
}

export async function readApiFailure(response: Response): Promise<ApiFailure> {
  const epoch = diagnosticResponseGeneration(response);
  const payload = await response.json().catch(() => null);
  const error = apiErrorFromResponse(response, payload);
  error.requestID ??= newLocalDiagnosticID();
  recordDiagnostic(error.requestID, error.status, error.code, epoch);
  return error;
}

export function networkApiFailure(epoch: number): ApiFailure {
  const error = apiErrorFromResponse(null, { error: "network_request_failed" });
  error.requestID = newLocalDiagnosticID();
  recordDiagnostic(error.requestID, null, error.code, epoch);
  return error;
}
