export type RootRequestScope = {
  rootID: string;
  generation: number;
  epoch: number;
  multiRoot: boolean;
  legacySelected: boolean;
  discoveryState: "unknown" | "legacy" | "multi" | "error";
  switching: boolean;
  signal: AbortSignal;
};
export type RootRequestSnapshot = {
  rootID: string;
  generation: number;
  epoch: number;
  contextKey: string;
  version: "v1" | "v2";
};
export function makeRootAbortError(): Error;
export function rootContextKey(scope: RootRequestScope): string;
export function createRootRequestTransport(input: {
  getContext: () => RootRequestScope;
  onGenerationChanged: () => void;
  fetcher?: typeof fetch;
}): {
  snapshot(endpoint: string): RootRequestSnapshot | null;
  assertCurrent(snapshot: RootRequestSnapshot | null): void;
  request(endpoint: string, init?: RequestInit, allowDuringRootSwitch?: boolean): Promise<Response>;
};
