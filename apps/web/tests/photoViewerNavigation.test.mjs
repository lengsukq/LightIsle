import assert from "node:assert/strict";
import test from "node:test";
import { ref } from "vue";
import {
  applyPhotoRangeSelection,
  syncViewerAfterItemRemoval,
} from "../src/photoViewerNavigation.ts";

test("applyPhotoRangeSelection toggles single items and Shift+Click inclusive ranges capped at maxCount", () => {
  const assets = Array.from({ length: 12 }, (_, idx) => ({ id: idx + 1 }));

  const first = applyPhotoRangeSelection({
    assets,
    currentSelection: new Set(),
    targetId: 3,
    anchorId: null,
    shiftKey: false,
  });
  assert.deepEqual([...first.next], [3]);
  assert.equal(first.anchorId, 3);

  const rangeAdd = applyPhotoRangeSelection({
    assets,
    currentSelection: first.next,
    targetId: 6,
    anchorId: first.anchorId,
    shiftKey: true,
  });
  assert.deepEqual([...rangeAdd.next], [3, 4, 5, 6]);
  assert.equal(rangeAdd.anchorId, 6);

  const rangeRemove = applyPhotoRangeSelection({
    assets,
    currentSelection: rangeAdd.next,
    targetId: 4,
    anchorId: rangeAdd.anchorId,
    shiftKey: true,
  });
  assert.deepEqual([...rangeRemove.next], [3]);

  const capped = applyPhotoRangeSelection({
    assets,
    currentSelection: new Set([1]),
    targetId: 10,
    anchorId: 1,
    shiftKey: true,
    maxCount: 4,
  });
  assert.equal(capped.next.size, 4);
});

test("syncViewerAfterItemRemoval advances smoothly to next remaining asset or closes only when empty", async () => {
  const assets = ref([{ id: 10 }, { id: 20 }, { id: 30 }]);
  const selected = ref({ id: 20 });
  const selectedIndex = ref(1);
  const shown = [];
  let closed = false;
  let fallbackFocused = -1;

  await syncViewerAfterItemRemoval({
    removedIds: [20],
    wasViewerOpenForRemoved: true,
    previousIndex: 1,
    assets,
    selected,
    selectedIndex,
    showAssetAt: (idx) => {
      shown.push(idx);
      selectedIndex.value = idx;
      selected.value = assets.value[idx] ?? null;
    },
    closeModal: () => {
      closed = true;
      selected.value = null;
    },
    reload: async () => {
      assets.value = [{ id: 10 }, { id: 30 }];
    },
  });

  assert.deepEqual(shown, [1]);
  assert.equal(selected.value?.id, 30);
  assert.equal(closed, false);

  // Removing the last remaining asset closes modal and invokes fallback focus.
  assets.value = [{ id: 30 }];
  selected.value = { id: 30 };
  selectedIndex.value = 0;
  await syncViewerAfterItemRemoval({
    removedIds: [30],
    wasViewerOpenForRemoved: true,
    previousIndex: 0,
    assets,
    selected,
    selectedIndex,
    showAssetAt: (idx) => shown.push(idx),
    closeModal: () => {
      closed = true;
      selected.value = null;
    },
    reload: async () => {
      assets.value = [];
    },
    focusFallback: async (idx) => {
      fallbackFocused = idx;
    },
  });

  assert.equal(closed, true);
  assert.equal(fallbackFocused, 0);
});
