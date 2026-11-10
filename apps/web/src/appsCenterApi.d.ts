export const DEFAULT_MCP_COMMAND: string;
export const DEFAULT_MCP_PROMPT: string;

export type AccessPolicyType = "admin_only" | "selected_members" | "all_members";

export function normalizeAccessPolicy(policy?: string): AccessPolicyType;
export function hasWebModule(app: unknown): boolean;
export function hasCronModule(app: unknown): boolean;
export function buildAccessPutPayload(
  app: { revision?: string },
  policy: string,
  allowedUserIDs: number[]
): Record<string, unknown>;
export function buildConfigPutPayload(
  app: { revision?: string; web?: unknown; mode?: string; cron?: unknown },
  webDraft?: {
    enabled: boolean;
    mode: "static" | "on-demand" | "persistent";
    idleTimeoutSeconds: number;
    autoRestart: boolean;
  },
  cronDraft?: {
    enabled: boolean;
    cron: string;
    timezone: string;
    events: string[];
    channels: string[];
  }
): Record<string, unknown>;
export function normalizeLogsResponse(res: unknown): {
  webOutput: string;
  cronRuns: Array<Record<string, any>>;
};
export function getAppDataBackupUrl(id: string): string;
export function createAppsCenterClient(fetchImpl?: typeof fetch): {
  request(url: string, options?: RequestInit): Promise<any>;
  fetchApps(refresh?: boolean): Promise<any>;
  setMcpEnabled(enabled: boolean): Promise<any>;
  launchApp(id: string): Promise<any>;
  runAction(id: string, action: "start" | "stop" | "restart" | "run_cron"): Promise<any>;
  saveAccess(app: { id: string; revision?: string }, policy: string, allowedUserIDs: number[]): Promise<any>;
  saveConfig(
    app: { id: string; revision?: string; web?: unknown; mode?: string; cron?: unknown },
    webDraft: {
      enabled: boolean;
      mode: "static" | "on-demand" | "persistent";
      idleTimeoutSeconds: number;
      autoRestart: boolean;
    },
    cronDraft: {
      enabled: boolean;
      cron: string;
      timezone: string;
      events: string[];
      channels: string[];
    }
  ): Promise<any>;
  fetchLogs(id: string): Promise<{ webOutput: string; cronRuns: Array<Record<string, any>> }>;
  deleteApp(id: string): Promise<any>;
  restoreAppData(id: string, archiveBody: BodyInit): Promise<any>;
};
