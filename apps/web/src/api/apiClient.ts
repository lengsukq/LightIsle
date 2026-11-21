import { networkApiFailure, readApiFailure } from "./apiFailure.ts";
import { diagnosticGeneration, markDiagnosticResponse } from "../features/settings/betaDiagnostics.ts";
import { createRootRequestTransport } from "./rootRequestTransport.ts";

const SESSION_EXPIRED_MESSAGE = "登录状态已失效，请重新登录。";
const AUTH_EXEMPT_PATHS = new Set([
  "/api/v2/auth/me",
  "/api/v2/auth/login",
  "/api/v2/auth/logout",
  "/api/v2/auth/setup",
]);

let sessionIsAuthenticated: (() => boolean) | null = null;
let sessionExpiredCallback: ((message: string) => void) | null = null;

/** Register the global 401 session-expiry handler for all `apiFetch` callers. */
export function configureApiSessionHandler(
  config: {
    isAuthenticated: () => boolean;
    onSessionExpired: (message: string) => void;
  } | null,
) {
  sessionIsAuthenticated = config?.isAuthenticated ?? null;
  sessionExpiredCallback = config?.onSessionExpired ?? null;
}

/** Trigger global session expiry if an authenticated request receives HTTP 401 on a non-auth endpoint. */
export function notifyApiSessionExpiry(
  path: RequestInfo | URL,
  status: number,
  skipSessionExpiry = false,
) {
  if (status !== 401 || skipSessionExpiry) return;
  if (!sessionExpiredCallback || !sessionIsAuthenticated?.()) return;
  const raw = typeof path === "string" ? path : path instanceof URL ? path.pathname : path.url;
  let pathname = raw;
  try {
    pathname = new URL(raw, "http://localhost").pathname;
  } catch {
    /* keep raw path */
  }
  if (AUTH_EXEMPT_PATHS.has(pathname)) return;
  sessionExpiredCallback(SESSION_EXPIRED_MESSAGE);
}

export interface ApiRequestOptions extends Omit<RequestInit, "body"> {
  body?: BodyInit | null;
  json?: unknown;
  fetcher?: typeof fetch;
  /** Skip triggering the global 401 session-expiry logout handler for this call. */
  skipSessionExpiry?: boolean;
}

/**
 * Shared same-origin fetch wrapper that guarantees CSRF header (`X-LightIsle-Request: 1`),
 * `credentials: "same-origin"`, `cache: "no-store"`, diagnostic response tagging,
 * unified 401 session-expiry handling, and optional JSON body serialization.
 */
export async function apiFetch(
  path: RequestInfo | URL,
  options: ApiRequestOptions = {},
): Promise<Response> {
  const {
    json,
    fetcher = globalThis.fetch,
    headers: initHeaders,
    body: initBody,
    skipSessionExpiry = false,
    ...rest
  } = options;
  const headers = new Headers(initHeaders);
  headers.set("X-LightIsle-Request", "1");
  let body = initBody;
  if (json !== undefined) {
    if (!headers.has("Content-Type")) {
      headers.set("Content-Type", "application/json");
    }
    body = JSON.stringify(json);
  }
  const epoch = diagnosticGeneration();
  try {
    const response = await fetcher(path, {
      credentials: "same-origin",
      cache: "no-store",
      ...rest,
      headers,
      body,
    });
    markDiagnosticResponse(response, epoch);
    notifyApiSessionExpiry(path, response.status, skipSessionExpiry);
    return response;
  } catch (error) {
    if (rest.signal?.aborted || (error instanceof Error && error.name === "AbortError")) throw error;
    throw networkApiFailure(epoch);
  }
}

/**
 * Shared JSON request helper parsing error payloads through `readApiFailure`.
 */
export async function apiRequest<T = unknown>(
  path: string,
  options: ApiRequestOptions = {},
): Promise<T> {
  const response = await apiFetch(path, options);
  if (!response.ok) {
    throw await readApiFailure(response);
  }
  if (response.status === 204) {
    return undefined as T;
  }
  const raw = await response.text();
  return (raw ? JSON.parse(raw) : undefined) as T;
}

/**
 * Creates a root-scoped JSON API helper backed by `createRootRequestTransport` and `apiFetch`,
 * enforcing physical root generation headers, root-switch abort checks, and 409 generation change notifications.
 */
export function createScopedRootApi(input: {
  getRootId: () => string | undefined;
  getRootGeneration: () => number;
  getEpoch: () => number;
  getSignal: () => AbortSignal;
  onGenerationChanged?: () => void;
  fetcher?: typeof fetch;
}) {
  const transport = createRootRequestTransport({
    getContext: () => {
      const rootID = input.getRootId() ?? "";
      return {
        rootID,
        generation: input.getRootGeneration(),
        epoch: input.getEpoch(),
        multiRoot: true,
        legacySelected: !rootID,
        discoveryState: "multi",
        switching: false,
        signal: input.getSignal(),
      };
    },
    onGenerationChanged:
      input.onGenerationChanged ??
      (() => {
        if (typeof window !== "undefined") {
          window.dispatchEvent(new Event("lightisle-root-generation-changed"));
        }
      }),
    fetcher: (endpoint, init) => apiFetch(endpoint, { ...init, fetcher: input.fetcher }),
  });

  async function api<T>(
    url: string,
    method = "GET",
    body?: object,
    signal?: AbortSignal,
  ): Promise<T> {
    const captured = transport.snapshot(url);
    const response = await transport.request(url, {
      method,
      headers: body !== undefined ? { "Content-Type": "application/json" } : undefined,
      body: body !== undefined ? JSON.stringify(body) : undefined,
      signal,
    });
    if (!response.ok) {
      const failure = await readApiFailure(response);
      transport.assertCurrent(captured);
      throw failure;
    }
    if (response.status === 204) {
      transport.assertCurrent(captured);
      return undefined as T;
    }
    const raw = await response.text();
    const result = (raw ? JSON.parse(raw) : undefined) as T;
    transport.assertCurrent(captured);
    return result;
  }

  return { transport, api };
}
