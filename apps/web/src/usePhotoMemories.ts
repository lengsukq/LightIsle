import { ref } from "vue";

export type SmartMemoryItem = {
  id: string;
  kind: "live" | "trip" | "weekend" | "yearly";
  title: string;
  subtitle: string;
  count: number;
  coverAssetId: number;
  assetIds?: number[];
  takenFrom?: number;
  takenTo?: number;
};

export function usePhotoMemories(options: {
  api: <T>(url: string, method?: string, body?: object, signal?: AbortSignal) => Promise<T>;
  apiPath: (path: string) => string;
  getRootEpoch: () => number;
  isDisposed: () => boolean;
}) {
  const smartMemories = ref<SmartMemoryItem[]>([]);

  async function refreshSmartMemories() {
    const epoch = options.getRootEpoch();
    try {
      const res = await options.api<{ memories?: SmartMemoryItem[] }>(
        options.apiPath("/api/v2/photos/memories"),
      );
      if (options.isDisposed() || epoch !== options.getRootEpoch()) return;
      smartMemories.value = Array.isArray(res.memories) ? res.memories : [];
    } catch {
      if (epoch === options.getRootEpoch()) {
        smartMemories.value = [];
      }
    }
  }

  function resetSmartMemories() {
    smartMemories.value = [];
  }

  return {
    smartMemories,
    refreshSmartMemories,
    resetSmartMemories,
  };
}
