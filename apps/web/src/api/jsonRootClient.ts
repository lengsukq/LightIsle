import { apiErrorFromResponse, readApiFailure } from "../apiFailure.ts";

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
 * Unified root-aware JSON HTTP client for the Web shell, eliminating duplicated
 * 401 session-expiry and `root_generation_changed` guards across GET/WRITE/Downloads.
 */
export function createJsonRootClient<TSnapshot>(options: JsonRootClientOptions<TSnapshot>) {
  async function handleJsonError(
    endpoint: string,
    response: Response,
    snapshot: TSnapshot,
    fallbackBody: { error?: string },
    skipSessionExpiryEndpoints: string[],
  ): Promise<never> {
    if (
      response.status === 401 &&
      options.isAuthenticated() &&
      !skipSessionExpiryEndpoints.includes(endpoint)
    ) {
      options.onSessionExpired(SESSION_EXPIRED_MESSAGE);
    }
    const result = (await response.json().catch(() => fallbackBody)) as { error?: string };
    options.assertSnapshotCurrent(snapshot);
    if (snapshot && result.error === "root_generation_changed") {
      options.onRootGenerationChanged();
      throw new Error(ROOT_GENERATION_CHANGED_MESSAGE);
    }
    throw apiErrorFromResponse(response, result);
  }

  async function jsonGet<T>(endpoint: string, signal?: AbortSignal): Promise<T> {
    const snapshot = options.snapshotEndpoint(endpoint);
    const response = await options.rootFetch(endpoint, {
      cache: "no-store",
      credentials: "same-origin",
      signal,
    });
    if (!response.ok) {
      return handleJsonError(endpoint, response, snapshot, {}, ["/api/v2/auth/me"]);
    }
    const result = (await response.json()) as T;
    options.assertSnapshotCurrent(snapshot);
    return result;
  }

  async function jsonWrite<T>(
    endpoint: string,
    method: "POST" | "PATCH" | "PUT" | "DELETE",
    body: object = {},
    signal?: AbortSignal,
  ): Promise<T> {
    const snapshot = options.snapshotEndpoint(endpoint);
    const response = await options.rootFetch(endpoint, {
      method,
      credentials: "same-origin",
      headers: {
        "Content-Type": "application/json",
        "X-LightIsle-Request": "1",
      },
      body: JSON.stringify(body),
      signal,
    });
    if (!response.ok) {
      return handleJsonError(
        endpoint,
        response,
        snapshot,
        { error: "request_failed" },
        ["/api/v2/auth/logout", "/api/v2/auth/login"],
      );
    }
    const result = (await response.json()) as T;
    options.assertSnapshotCurrent(snapshot);
    return result;
  }

  async function downloadsApi(path: string, init: RequestInit = {}): Promise<unknown> {
    const response = await options.rootFetch(path, init);
    if (!response.ok) {
      if (response.status === 401 && options.isAuthenticated()) {
        options.onSessionExpired(SESSION_EXPIRED_MESSAGE);
      }
      throw await readApiFailure(response);
    }
    return response.json();
  }

  return { jsonGet, jsonWrite, downloadsApi };
}
