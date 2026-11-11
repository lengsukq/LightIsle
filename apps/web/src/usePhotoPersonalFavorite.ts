import type { Ref } from "vue";
import { describeUserFacingError } from "./userFacingError.ts";

type Options<T> = {
  pendingFavorites: Ref<Record<number, boolean>>;
  assets: Ref<T[]>;
  selected: Ref<T | null>;
  selectedIndex: Ref<number>;
  personalOnly: Ref<boolean>;
  message: Ref<string>;
  generation: () => number;
  save: (id: number, value: boolean) => Promise<unknown>;
  reload: () => Promise<unknown>;
  closeModal: (history: boolean) => void;
  focusTile: (index: number) => Promise<unknown>;
};

export function usePhotoPersonalFavorite<T extends { id: number; personalFavorite?: boolean }>(options: Options<T>) {
  const { pendingFavorites, assets, selected, selectedIndex, personalOnly, message, generation, save, reload, closeModal, focusTile } = options;
  return async function togglePersonalFavorite(asset: T) {
    if (pendingFavorites.value[asset.id]) return;
    const selection = generation();
    pendingFavorites.value[asset.id] = true;
    try {
      const next = !asset.personalFavorite;
      await save(asset.id, next);
      const current = assets.value.find((item) => item.id === asset.id);
      if (current) current.personalFavorite = next;
      if (selected.value?.id === asset.id) selected.value.personalFavorite = next;
      if (personalOnly.value && !next) {
        const selectedID = selected.value?.id, previousIndex = selectedIndex.value;
        if (selectedID === asset.id) closeModal(false);
        await reload();
        if (selectedID && selectedID !== asset.id) {
          const nextIndex = assets.value.findIndex((item) => item.id === selectedID);
          if (nextIndex >= 0) selectedIndex.value = nextIndex;
        } else if (selectedID === asset.id && assets.value.length) {
          await focusTile(Math.min(previousIndex, assets.value.length - 1));
        }
      }
    } catch (e) {
      if (selection === generation() && selected.value?.id === asset.id) {
        message.value = "个人收藏失败：" + describeUserFacingError(e);
      }
    } finally {
      delete pendingFavorites.value[asset.id];
    }
  };
}
