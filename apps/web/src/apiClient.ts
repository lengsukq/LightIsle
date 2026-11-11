import { networkApiFailure, readApiFailure } from "./apiFailure.ts";
import { diagnosticGeneration, markDiagnosticResponse } from "./betaDiagnostics.ts";
import { createRootRequestTransport } from "./rootRequestTransport.ts";

export interface ApiRequestOptions extends Omit<RequestInit, "body"> {
  body?: BodyInit | null;
  json?: unknown;
  fetcher?: typeof fetch;
}

/**
 * Shared same-origin fetch wrapper that guarantees CSRF header (`X-LightIsle-Request: 1`),
 * `credentials: "same-origin"`, `cache: "no-store"`, and optional JSON body serialization.
 */
export async function apiFetch(
  path: RequestInfo | URL,
  options: ApiRequestOptions = {},
): Promise<Response> {
  const { json, fetcher = globalThis.fetch, headers: initHeaders, body: initBody, ...rest } = options;
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
    return markDiagnosticResponse(response, epoch);
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
  return (await response.json()) as T;
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
    const result = (await response.json()) as T;
    transport.assertCurrent(captured);
    return result;
  }

  return { transport, api };
}
