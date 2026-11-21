import { apiErrorFromResponse, readApiFailure } from "./apiFailure.ts";
import { diagnosticGeneration, markDiagnosticResponse } from "../features/settings/betaDiagnostics.ts";
import { notifyApiSessionExpiry } from "./apiClient.ts";

export interface JsonRootClientOptions<TSnapshot> {
  rootFetch: (endpoint: string, init?: RequestInit) => Promise<Response>;
  snapshotEndpoint: (endpoint: string) => TSnapshot;
  assertSnapshotCurrent: (snapshot: TSnapshot) => void;
  isAuthenticated: () => boolean;
  onSessionExpired: (message: string) => void;
  onRootGenerationChanged: () => void;
}

const SESSION_EXPIRED_MESSAGE = "登录状态已失效，请重新登录。";
const ROOT_GENERATION_CHANGED_MESSAGE = "共享目录已变化，请刷新根列表后重新选择。";

/**
 * Root-aware JSON HTTP client for the Web shell, reusing shared diagnostic response
 * tagging and unified 401 session-expiry semantics alongside `root_generation_changed` guards.
 */
export function createJsonRootClient<TSnapshot>(options: JsonRootClientOptions<TSnapshot>) {
  function handleSessionExpiry(endpoint: string, status: number, skipEndpoints: string[]) {
    if (status !== 401 || skipEndpoints.includes(endpoint)) return;
    notifyApiSessionExpiry(endpoint, status);
    if (options.isAuthenticated()) {
      options.onSessionExpired(SESSION_EXPIRED_MESSAGE);
    }
  }

  async function handleJsonError(
    endpoint: string,
    response: Response,
    snapshot: TSnapshot,
    fallbackBody: { error?: string },
    skipSessionExpiryEndpoints: string[],
  ): Promise<never> {
    handleSessionExpiry(endpoint, response.status, skipSessionExpiryEndpoints);
    const result = (await response.json().catch(() => fallbackBody)) as { error?: string };
    options.assertSnapshotCurrent(snapshot);
    if (snapshot && result.error === "root_generation_changed") {
      options.onRootGenerationChanged();
      throw new Error(ROOT_GENERATION_CHANGED_MESSAGE);
    }
    throw apiErrorFromResponse(response, result);
  }

  async function parseOptionalJson<T>(response: Response): Promise<T> {
    if (response.status === 204) return undefined as T;
    const raw = await response.text();
    return (raw ? JSON.parse(raw) : undefined) as T;
  }

  async function jsonGet<T>(endpoint: string, signal?: AbortSignal): Promise<T> {
    const epoch = diagnosticGeneration();
    const snapshot = options.snapshotEndpoint(endpoint);
    const response = markDiagnosticResponse(
      await options.rootFetch(endpoint, {
        cache: "no-store",
        credentials: "same-origin",
        signal,
      }),
      epoch,
    );
    if (!response.ok) {
      return handleJsonError(endpoint, response, snapshot, {}, ["/api/v2/auth/me"]);
    }
    const result = await parseOptionalJson<T>(response);
    options.assertSnapshotCurrent(snapshot);
    return result;
  }

  async function jsonWrite<T>(
    endpoint: string,
    method: "POST" | "PATCH" | "PUT" | "DELETE",
    body: object = {},
    signal?: AbortSignal,
  ): Promise<T> {
    const epoch = diagnosticGeneration();
    const snapshot = options.snapshotEndpoint(endpoint);
    const response = markDiagnosticResponse(
      await options.rootFetch(endpoint, {
        method,
        credentials: "same-origin",
        headers: {
          "Content-Type": "application/json",
          "X-LightIsle-Request": "1",
        },
        body: JSON.stringify(body),
        signal,
      }),
      epoch,
    );
    if (!response.ok) {
      return handleJsonError(
        endpoint,
        response,
        snapshot,
        { error: "request_failed" },
        ["/api/v2/auth/logout", "/api/v2/auth/login"],
      );
    }
    const result = await parseOptionalJson<T>(response);
    options.assertSnapshotCurrent(snapshot);
    return result;
  }

  async function downloadsApi(path: string, init: RequestInit = {}): Promise<unknown> {
    const epoch = diagnosticGeneration();
    const response = markDiagnosticResponse(await options.rootFetch(path, init), epoch);
    if (!response.ok) {
      handleSessionExpiry(path, response.status, []);
      throw await readApiFailure(response);
    }
    return parseOptionalJson<unknown>(response);
  }

  return { jsonGet, jsonWrite, downloadsApi };
}
