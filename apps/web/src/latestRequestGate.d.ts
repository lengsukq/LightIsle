export interface LatestRequest {
  signal: AbortSignal;
  isCurrent(): boolean;
}

export interface LatestRequestGate {
  begin(): LatestRequest;
  cancel(): void;
}

export function createLatestRequestGate(): LatestRequestGate;
