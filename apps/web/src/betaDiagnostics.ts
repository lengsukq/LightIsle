type FailureEvent = {
  time: string;
  requestID: string;
  status: number | null;
  code: string | null;
};

const key = "lightisle.beta.diagnostics.v1";
const accountKey = key + ".account";
const idPattern = /^(?:web-)?[a-f0-9]{32}$/;
const safeCodes = new Set([
  "authentication_required", "file_permission_denied", "root_unavailable", "volume_offline",
  "root_generation_changed", "default_root_not_configured", "storage_quota_exceeded",
  "storage_accounting_uncertain", "storage_operation_uncertain", "offset_mismatch",
  "upload_outcome_uncertain", "upload_begin_uncertain", "insufficient_storage_space",
  "transcode_unavailable", "download_unavailable", "network_request_failed",
]);
const limit = 200;
let generation = 0;
let events: FailureEvent[] | undefined;
let activeAccount: string | undefined;
const responseGenerations = new WeakMap<Response, number>();

export function diagnosticGeneration() { return generation; }

export function markDiagnosticResponse(response: Response, epoch: number) {
  responseGenerations.set(response, epoch);
  return response;
}

export function diagnosticResponseGeneration(response: Response) {
  return responseGenerations.get(response) ?? generation;
}

export function newLocalDiagnosticID(): string {
  const bytes = globalThis.crypto.getRandomValues(new Uint8Array(16));
  return "web-" + Array.from(bytes, byte => byte.toString(16).padStart(2, "0")).join("");
}

export function diagnosticID(value: unknown): string | null {
  return typeof value === "string" && idPattern.test(value) ? value : null;
}

function readEvents(): FailureEvent[] {
  if (events) return events;
  try {
    const raw = sessionStorage.getItem(key);
    if (!raw || raw.length > 100_000) return events = [];
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) return events = [];
    return events = parsed.slice(-limit).flatMap(event => {
      if (!event || typeof event !== "object" || !diagnosticID(event.requestID) ||
          typeof event.time !== "string" || !/^\d{4}-\d{2}-\d{2}T[\d:.]+Z$/.test(event.time) ||
          event.time.length > 30) return [];
      return [{
        time: event.time, requestID: event.requestID,
        code: typeof event.code === "string" && safeCodes.has(event.code) ? event.code : null,
        status: Number.isInteger(event.status) && event.status >= 100 && event.status <= 599 ? event.status : null,
      }];
    });
  } catch {
    return events = [];
  }
}

export function recordDiagnostic(requestID: string, status: number | null, code: string | null, epoch = generation) {
  if (epoch !== generation || !diagnosticID(requestID)) return;
  const buffer = readEvents();
  if (buffer.at(-1)?.requestID === requestID) return;
  buffer.push({ time: new Date().toISOString(), requestID, status, code: code && safeCodes.has(code) ? code : null });
  if (buffer.length > limit) buffer.shift();
  try { sessionStorage.setItem(key, JSON.stringify(buffer)); } catch { /* memory-only fallback */ }
}

export function resetDiagnostics() {
  generation++;
  events = [];
  activeAccount = undefined;
  try {
    sessionStorage.removeItem(key);
    sessionStorage.removeItem(accountKey);
  } catch { /* memory state already cleared */ }
}

export function bindDiagnosticAccount(id: number) {
  if (!Number.isSafeInteger(id) || id < 1) return;
  const account = String(id);
  let previous = activeAccount;
  try { previous ??= sessionStorage.getItem(accountKey) ?? undefined; } catch { /* memory-only */ }
  if (previous !== account) resetDiagnostics();
  activeAccount = account;
  try { sessionStorage.setItem(accountKey, account); } catch { /* memory-only */ }
}

export function localDiagnosticReport() {
  return JSON.stringify({ schema: 1, source: "web", exportedAt: new Date().toISOString(), events: readEvents() }, null, 2);
}
