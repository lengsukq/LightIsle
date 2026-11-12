export type AccessPolicyType = "admin_only" | "selected_members" | "all_members";

export type AppWebMode = "none" | "static" | "on-demand" | "persistent" | "daemon";

export interface AppWebDraft {
  enabled: boolean;
  mode: "static" | "on-demand" | "persistent";
  idleTimeoutSeconds: number;
  autoRestart: boolean;
}

export interface AppCronDraft {
  enabled: boolean;
  cron: string;
  timezone: string;
  events: string[];
  channels: string[];
}

export interface AppCronRunEntry {
  id?: number;
  startedAt: number;
  finishedAt: number;
  state: string;
  exitCode: number;
  output?: string;
  deliveries?: Record<string, string>;
}

export interface AppDiagnostic {
  summary: string;
  reason: string;
  logExcerpt?: string;
  checks?: string[];
  solutions?: string[];
  dataSafe?: string;
}

export interface PublicAppWebView {
  enabled?: boolean;
  mode?: "static" | "on-demand" | "persistent" | "daemon";
  entry?: string;
  idleTimeoutSeconds?: number;
  autoRestart?: boolean;
  status?: string;
  pid?: number;
  rssBytes?: number;
  memoryMB?: number;
  lastError?: string;
}

export interface PublicAppCronView {
  hasCron?: boolean;
  enabled?: boolean;
  entry?: string;
  cron?: string;
  timezone?: string;
  schedule?: { cron?: string; timezone?: string };
  events?: string[];
  channels?: string[];
  notification?: { events?: string[]; channels?: string[] };
  running?: boolean;
  nextRun?: number;
  nextRunAt?: number;
  lastRun?: AppCronRunEntry;
}

export interface PublicAppAccessView {
  policy: AccessPolicyType;
  allowedUserIDs?: number[];
  allowedUserIds?: number[];
}

export interface PublicAppItem {
  id: string;
  name: string;
  description?: string;
  version?: string;
  category?: string;
  iconUrl?: string;
  revision?: string;
  status?: string;
  mode?: string;
  pid?: number;
  rssBytes?: number;
  memoryMB?: number;
  launchUrl?: string;
  lastError?: string;
  validationError?: string;
  diagnostic?: AppDiagnostic;
  pendingActivation?: boolean;
  access?: PublicAppAccessView;
  web?: PublicAppWebView;
  cron?: PublicAppCronView;
}

export interface AppMemberSummary {
  id: number;
  username: string;
  role: string;
}

export interface McpCallLogEntry {
  id?: string | number;
  transport?: string;
  method?: string;
  target?: string;
  remoteAddr?: string;
  durationMs?: number;
  timestamp?: string;
  status?: string;
  error?: string;
  [key: string]: unknown;
}

export interface OfficialAppTemplateItem {
  id: string;
  name: string;
  description: string;
  category: string;
  version: string;
  mode: string;
  installed: boolean;
}

export interface AppsOverviewResponse {
  apps: PublicAppItem[];
  templates?: OfficialAppTemplateItem[];
  isAdmin?: boolean;
  mcpEnabled?: boolean;
  mcpLanEnabled?: boolean;
  mcpToken?: string;
  mcpPrompt?: string;
  lanMcpPrompt?: string;
  mcpConfigJson?: string;
  lanHttpUrl?: string;
  lanSseUrl?: string;
  mcpLogs?: McpCallLogEntry[];
  members: AppMemberSummary[];
  configuredChannels: string[];
  [key: string]: unknown;
}

export interface McpConfigResponse {
  enabled?: boolean;
  mcpEnabled?: boolean;
  mcpLanEnabled?: boolean;
  mcpPrompt?: string;
  lanMcpPrompt?: string;
  mcpConfigJson?: string;
  [key: string]: unknown;
}

export interface McpTokenRotateResponse {
  mcpToken?: string;
  token?: string;
  mcpPrompt?: string;
  lanMcpPrompt?: string;
  mcpConfigJson?: string;
  [key: string]: unknown;
}

export interface McpDebugExecPayload {
  method?: string;
  tool?: string;
  uri?: string;
  args?: unknown;
  rawRpc?: string;
}

export interface McpDebugExecResponse {
  requestJson: string;
  responseJson: string;
  durationMs: number;
  isError: boolean;
  logs?: McpCallLogEntry[];
  [key: string]: unknown;
}

export interface AppProbePayload {
  method?: string;
  path?: string;
  body?: string;
  role?: string;
}

export interface AppProbeExecution {
  statusCode: number;
  durationMs: number;
  status: string;
  bodyPreview?: string;
  headers?: Record<string, string>;
  [key: string]: unknown;
}

export interface AppProbeResponse extends AppProbeExecution {
  probe?: AppProbeExecution;
}

export interface AppLaunchResponse {
  app?: PublicAppItem;
  appId?: string;
  status?: string;
  ticket?: string;
  launchUrl?: string;
  url?: string;
  [key: string]: unknown;
}

export interface AppLogsNormalizedResponse {
  webOutput: string;
  cronRuns: AppCronRunEntry[];
}

export interface AppMutationResult {
  app?: PublicAppItem;
  apps?: PublicAppItem[];
  templates?: OfficialAppTemplateItem[];
  ok?: boolean;
  createdFiles?: string[];
  [key: string]: unknown;
}
