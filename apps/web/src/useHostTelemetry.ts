import {readApiFailure} from "./apiFailure.ts";
import { computed, onUnmounted, ref } from "vue";
import { describeUserFacingError } from "./userFacingError.ts";

export type ServerStats = {
  timestamp: string;
  hostname: string;
  architecture: string;
  cpuCount: number;
  cpuPercent: number | null;
  memoryTotal: number;
  memoryUsed: number;
  diskTotal: number;
  diskFree: number;
  corePid?: number;
  coreRssBytes?: number | null;
  diskIo?: { device: string; readBps?: number | null; writeBps?: number | null }[] | null;
  power?: {
    available: boolean;
    source: string;
    onBattery: boolean;
    upsPresent: boolean;
    deviceName?: string;
    percent?: number;
    remainingMinute?: number;
    charging?: boolean;
    lowBattery?: boolean;
  } | null;
};

export const percent = (value: number) =>
  Math.min(100, Math.max(0, Math.round(value)));

export function bytes(value: number): string {
  if (!Number.isFinite(value)) return "—";
  const units = ["B", "GB", "TB", "PB"];
  if (value < 1024 * 1024 * 1024) return (value / (1024 * 1024)).toFixed(1) + " MB";
  let n = value / (1024 * 1024 * 1024), i = 1;
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
  return n.toFixed(n < 10 ? 1 : 0) + " " + units[i];
}

/**
 * Keeps host diagnostics separate from page state. Members receive a health
 * check only; their UI must never retain a previous administrator's telemetry.
 */
export function useHostTelemetry(getRole: () => "admin" | "member" | undefined) {
  const stats = ref<ServerStats | null>(null);
  const error = ref<string | null>(null);
  const polling = ref(false);
  let controller: AbortController | undefined;
  let epoch = 0;

  const usedMemory = computed(() =>
    stats.value && !error.value && stats.value.memoryTotal > 0
      ? stats.value.memoryUsed / stats.value.memoryTotal * 100
      : null);
  const usedDisk = computed(() =>
    stats.value && !error.value && stats.value.diskTotal > 0
      ? (stats.value.diskTotal - stats.value.diskFree) / stats.value.diskTotal * 100
      : null);
  const cpu = computed(() => stats.value && !error.value ? stats.value.cpuPercent ?? null : null);
  const diskActivity = computed(() => {
    const entries = stats.value && !error.value ? stats.value.diskIo : null;
    if (!entries?.length) return null;
    let read = 0, write = 0;
    for (const item of entries) {
      read += item.readBps ?? 0;
      write += item.writeBps ?? 0;
    }
    return read <= 0 && write <= 0 ? null : "读 " + bytes(read) + "/s · 写 " + bytes(write) + "/s";
  });

  function clear() {
    epoch++;
    controller?.abort();
    controller = undefined;
    polling.value = false;
    stats.value = null;
    error.value = null;
  }

  async function update() {
    const role = getRole();
    if (!role || polling.value) return;
    const requestEpoch = ++epoch;
    controller?.abort();
    const requestController = new AbortController();
    controller = requestController;
    polling.value = true;
    try {
      const response = await fetch(role === "admin" ? "/api/v2/system" : "/api/v2/health", {
        cache: "no-store",
        credentials: "same-origin",
        signal: requestController.signal,
      });
      if (!response.ok) throw await readApiFailure(response);
      const reading: unknown = await response.json();
      if (requestEpoch !== epoch || getRole() !== role) return;
      stats.value = role === "admin" ? reading as ServerStats : null;
      error.value = null;
    } catch (cause) {
      if (requestEpoch === epoch && getRole() === role && !requestController.signal.aborted) {
        stats.value = null;
        error.value = describeUserFacingError(cause);
      }
    } finally {
      if (requestEpoch === epoch) {
        controller = undefined;
        polling.value = false;
      }
    }
  }

  onUnmounted(clear);
  return { stats, error, polling, cpu, usedMemory, usedDisk, diskActivity, update, clear, bytes, percent };
}
