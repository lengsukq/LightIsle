export type AccessPolicyType = "admin_only" | "selected_members" | "all_members";

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

interface PublicAppWebView {
  enabled?: boolean;
  mode?: "static" | "on-demand" | "persistent";
  entry?: string;
  idleTimeoutSeconds?: number;
  autoRestart?: boolean;
  status?: string;
  pid?: number;
  rssBytes?: number;
  memoryMB?: number;
  lastError?: string;
}

interface PublicAppCronView {
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
  lastRun?: AppCronRunEntry;
}

interface PublicAppAccessView {
  policy: AccessPolicyType;
  allowedUserIDs?: number[];
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
  locationId?: string;
  locationKind?: string;
  locationName?: string;
  pluginsDir?: string;
  pluginDataDir?: string;
  access?: PublicAppAccessView;
  web?: PublicAppWebView;
  cron?: PublicAppCronView;
}

export interface AppMemberSummary {
  id: number;
  username: string;
  role: string;
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

export interface AppStorageLocationItem {
  id: string;
  kind: "internal" | "external" | string;
  name: string;
  path: string;
  pluginsDir: string;
  pluginDataDir: string;
  isDefault: boolean;
  isCustomPath: boolean;
  online: boolean;
  writable: boolean;
  error?: string;
  volumeName?: string;
  volumeMount?: string;
  volumeUuid?: string;
  freeBytes?: number;
  totalBytes?: number;
  appCount: number;
}

interface AppStorageVolumeOption {
  name: string;
  mount: string;
  suggestedPath: string;
  filesystem?: string;
  totalBytes: number;
  freeBytes: number;
  readOnly: boolean;
  volumeUuid?: string;
}

export interface AppStorageSnapshot {
  defaultLocationId: string;
  maxInternal: number;
  maxExternal: number;
  maxLocations: number;
  hasExternal: boolean;
  locations: AppStorageLocationItem[];
  availableVolumes: AppStorageVolumeOption[];
}

export interface AppStorageMutationPayload {
  action: "add" | "set" | "set_default" | "reset_internal" | "remove_external";
  kind?: "internal" | "external";
  path?: string;
  name?: string;
  defaultLocationId?: string;
  setDefault?: boolean;
}

export interface AppsOverviewResponse {
  apps: PublicAppItem[];
  templates?: OfficialAppTemplateItem[];
  appStorage?: AppStorageSnapshot;
  isAdmin?: boolean;
  members: AppMemberSummary[];
  configuredChannels: string[];
  [key: string]: unknown;
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
