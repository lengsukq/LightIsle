export type MediaBackstack = {
  readonly depth: number;
  push(): void;
  back(steps?: number): boolean;
  reset(): void;
  dispose(): void;
};
export function createBrowserMediaBackstack(
  host: Window,
  owner: string,
  onBack: (oldDepth: number, targetDepth: number) => Promise<boolean>,
): MediaBackstack;
