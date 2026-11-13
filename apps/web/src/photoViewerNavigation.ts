import type { Ref } from "vue";

export type ViewerRemovalSyncOptions<T extends { id: number }> = {
  removedIds: number[];
  wasViewerOpenForRemoved: boolean;
  previousIndex: number;
  assets: Ref<T[]>;
  selected: Ref<T | null>;
  selectedIndex: Ref<number>;
  showAssetAt: (index: number) => void;
  closeModal: (restoreFocus: boolean) => void;
  reload: () => Promise<unknown>;
  focusFallback?: (removedIndex: number) => Promise<unknown>;
  shouldStillRestore?: () => boolean;
};

/**
 * Refreshes the gallery grid after item removal or deletion while keeping the
 * fullscreen viewer open on the next remaining item (closing only when empty).
 */
export async function syncViewerAfterItemRemoval<T extends { id: number }>(
  opts: ViewerRemovalSyncOptions<T>,
): Promise<void> {
  const retainedId = opts.wasViewerOpenForRemoved ? 0 : (opts.selected.value?.id ?? 0);
  await opts.reload();
  if (opts.shouldStillRestore && !opts.shouldStillRestore()) return;

  if (opts.wasViewerOpenForRemoved) {
    const currentId = opts.selected.value?.id ?? 0;
    const stillWaitingOnRemoved = currentId === 0 || opts.removedIds.includes(currentId);
    if (!stillWaitingOnRemoved) {
      const movedIdx = opts.assets.value.findIndex((item) => item.id === currentId);
      if (movedIdx >= 0) opts.selectedIndex.value = movedIdx;
      return;
    }
    if (opts.assets.value.length > 0) {
      const nextIndex = Math.max(0, Math.min(opts.previousIndex, opts.assets.value.length - 1));
      opts.showAssetAt(nextIndex);
    } else {
      opts.closeModal(false);
      await opts.focusFallback?.(opts.previousIndex);
    }
    return;
  }

  if (retainedId) {
    const nextIdx = opts.assets.value.findIndex((item) => item.id === retainedId);
    if (nextIdx >= 0) opts.selectedIndex.value = nextIdx;
  }
}

/**
 * Toggles a single id or a Shift+Click inclusive range (capped at maxCount items).
 */
export function applyPhotoRangeSelection(opts: {
  assets: ReadonlyArray<{ id: number }>;
  currentSelection: ReadonlySet<number>;
  targetId: number;
  anchorId: number | null;
  shiftKey: boolean;
  maxCount?: number;
}): { next: Set<number>; anchorId: number } {
  const maxCount = opts.maxCount ?? 50;
  const next = new Set(opts.currentSelection);
  if (opts.shiftKey && opts.anchorId !== null && opts.anchorId !== opts.targetId) {
    const startIdx = opts.assets.findIndex((item) => item.id === opts.anchorId);
    const endIdx = opts.assets.findIndex((item) => item.id === opts.targetId);
    if (startIdx >= 0 && endIdx >= 0) {
      const from = Math.min(startIdx, endIdx);
      const to = Math.max(startIdx, endIdx);
      const shouldAdd = !next.has(opts.targetId);
      for (let i = from; i <= to; i += 1) {
        const candidate = opts.assets[i];
        if (!candidate) continue;
        if (shouldAdd) {
          if (next.size < maxCount) next.add(candidate.id);
        } else {
          next.delete(candidate.id);
        }
      }
      return { next, anchorId: opts.targetId };
    }
  }
  if (next.has(opts.targetId)) next.delete(opts.targetId);
  else if (next.size < maxCount) next.add(opts.targetId);
  return { next, anchorId: opts.targetId };
}
