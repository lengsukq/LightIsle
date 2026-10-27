export type RootDiscoveryRoot = {
  rootID: string;
  name: string;
  generation: number;
  online: boolean;
};

export type RootDiscoveryResult =
  | { kind: "roots"; roots: RootDiscoveryRoot[] }
  | { kind: "error"; message: string };

export function readRootDiscoveryResponse(response: Response): Promise<RootDiscoveryResult>;
export function rootDiscoveryNetworkError(error: unknown): string;
export function describeRootOperationFailure(error: unknown): string;
export function describeRootContext(input: {
  state: "unknown" | "multi" | "error";
  error?: string;
  hasContext?: boolean;
  rootCount?: number;
  selectedRoot?: Pick<RootDiscoveryRoot, "name" | "online"> | null;
}): {
  kind: "error" | "loading" | "offline" | "choose" | "ready";
  title: string;
  message: string;
  role: "alert" | "status";
  action: string;
};
