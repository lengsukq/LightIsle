export interface MediaStatusPoller<T> {
  refresh(): Promise<void>;
  invalidate(): void;
  dispose(): void;
}

export function createMediaStatusPoller<T>(
  readStatus: (signal: AbortSignal) => Promise<T>,
  callbacks?: { onValue?: (value: T) => void; onError?: (error: unknown) => void },
): MediaStatusPoller<T>;
