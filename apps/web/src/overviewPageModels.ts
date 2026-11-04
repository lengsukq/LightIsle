import type { ServerStats } from "./useHostTelemetry.js";

export type PersonalSpaceSummary = {
  quotaBytes: number | null;
  rootQuotas: Array<{rootID:string;rootGeneration:number;quotaBytes:number|null;accountedBytes:number;reservedBytes:number}>;
  accountedBytes: number;
  reservedBytes: number;
  usageComplete: boolean;
  enforcement: string;
  locations: Array<{ category: string; rootID: string }>;
};

export type OverviewIdentity = { username: string; isAdmin: boolean };
export type OverviewSearch = {
  query: string;
  spotlight: boolean;
  filesLoading: boolean;
  searchingFiles: boolean;
};
export type OverviewTelemetry = {
  error: string | null;
  stats: ServerStats | null;
  polling: boolean;
  cpu: number | null;
  usedMemory: number | null;
  usedDisk: number | null;
  diskActivity: string | null;
  expanded: boolean;
  bytes: (value: number) => string;
  percent: (value: number) => number;
};
export type OverviewPersonalSpace = {
  summary: PersonalSpaceSummary | null;
  error: string;
  bytes: (value: number) => string;
};
