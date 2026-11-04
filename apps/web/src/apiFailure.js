// Preserve the safe machine-readable code returned by Core. Never expose
// response bodies, URLs, cookies or arbitrary upstream text as error details.
const SAFE_CODE = /^[a-z][a-z0-9_.-]{1,63}$/;

export function apiErrorFromResponse(response, payload = {}) {
  const raw = payload && typeof payload === "object" ? payload.error : null;
  const code = typeof raw === "string" && SAFE_CODE.test(raw) ? raw : null;
  const status = Number.isInteger(response?.status) &&
    response.status >= 100 && response.status <= 599 ? response.status : null;
  const error = new Error(code ?? (status ? `HTTP ${status}` : "request_failed"));
  error.name = "ApiFailureError";
  error.code = code;
  error.status = status;
  return error;
}

export async function readApiFailure(response) {
  const payload = await response.json().catch(() => null);
  return apiErrorFromResponse(response, payload);
}
