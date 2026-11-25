import { ref } from "vue";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import type { MetadataEditPayload } from "./PhotoMetadataEditModal.vue";
import type { BatchAsset } from "./usePhotoBatchActions.ts";

export function usePhotoMetadataEditor(options: {
  api: (url: string, method?: string, body?: object) => Promise<unknown>;
  rootPath: (path: string) => string;
  onUpdated: () => Promise<void> | void;
}) {
  const open = ref(false);
  const busy = ref(false);
  const error = ref("");
  const targetIds = ref<number[]>([]);
  const initialTakenAt = ref<number | undefined>(undefined);
  const initialLatitude = ref<number | null>(null);
  const initialLongitude = ref<number | null>(null);

  function openForAssets(assets: BatchAsset[]) {
    const valid = assets.filter((a) => a && a.id > 0);
    if (!valid.length) return;
    targetIds.value = valid.map((a) => a.id);
    initialTakenAt.value = valid[0].takenAt;
    if (valid.length === 1) {
      initialLatitude.value = valid[0].latitude ?? null;
      initialLongitude.value = valid[0].longitude ?? null;
    } else {
      initialLatitude.value = null;
      initialLongitude.value = null;
    }
    error.value = "";
    open.value = true;
  }

  function close() {
    open.value = false;
    error.value = "";
  }

  async function submit(payload: MetadataEditPayload) {
    if (busy.value || !payload.ids.length) return;
    busy.value = true;
    error.value = "";
    try {
      await options.api(options.rootPath("/api/v2/photos/metadata"), "PATCH", payload);
      open.value = false;
      await options.onUpdated();
    } catch (e) {
      error.value = "修正时间或地点失败：" + describeUserFacingError(e);
    } finally {
      busy.value = false;
    }
  }

  return {
    open,
    busy,
    error,
    targetIds,
    initialTakenAt,
    initialLatitude,
    initialLongitude,
    openForAssets,
    close,
    submit,
  };
}
