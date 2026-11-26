// Preserve the safe machine-readable code returned by Core. Never expose
// response bodies, URLs, cookies or arbitrary upstream text as error details.
import { diagnosticID, diagnosticResponseGeneration, newLocalDiagnosticID, recordDiagnostic } from "../features/settings/betaDiagnostics.ts";

const SAFE_CODE = /^[a-z][a-z0-9_.-]{1,63}$/;
const SAFE_LOCALIZED_TEXT = /^[^\x00-\x1f\x7f<>]{1,240}$/;

function safeLocalizedServerText(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!trimmed || !SAFE_LOCALIZED_TEXT.test(trimmed)) return null;
  // Preserve only localized Chinese guidance from Core; never surface arbitrary ASCII/HTML/tokens.
  if (!/[\u3400-\u9fff]/.test(trimmed)) return null;
  return trimmed;
}

export type ApiFailure = Error & {
  code: string | null;
  status: number | null;
  requestID: string | null;
  serverMessage?: string | null;
  nextAction?: string | null;
};

export function apiErrorFromResponse(
  response: (Pick<Response, "status"> & Partial<Pick<Response, "headers">>) | null | undefined,
  payload: unknown = {},
): ApiFailure {
  const obj = payload && typeof payload === "object" ? (payload as Record<string, unknown>) : null;
  const raw = obj && "error" in obj ? obj.error : null;
  const code = typeof raw === "string" && SAFE_CODE.test(raw) ? raw : null;
  const serverMessage = obj ? safeLocalizedServerText(obj.message) : null;
  const nextAction = obj ? safeLocalizedServerText(obj.nextAction) : null;
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
      serverMessage,
      nextAction,
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
