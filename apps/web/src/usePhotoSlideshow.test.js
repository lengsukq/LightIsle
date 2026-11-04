import assert from "node:assert/strict";
import test from "node:test";
import { ref } from "vue";
import { usePhotoSlideshow } from "./usePhotoSlideshow.ts";

test("slideshow skips videos, pauses in background and clears its timer", () => {
  const oldWindow = globalThis.window;
  const oldDocument = globalThis.document;
  let tick;
  let cleared;
  globalThis.window = {
    setInterval(callback, delay) { tick = callback; assert.equal(delay, 4000); return 42; },
    clearInterval(id) { cleared = id; },
  };
  globalThis.document = { hidden: false };
  try {
    const modalAssets = ref([{type:"photo"}, {type:"video"}, {type:"photo"}]);
    const selected = ref(modalAssets.value[0]);
    const selectedIndex = ref(0);
    const slideshow = usePhotoSlideshow({
      selected, selectedIndex, modalAssets,
      showAssetAt(index) { selectedIndex.value = index; selected.value = modalAssets.value[index]; },
    });
    slideshow.toggleSlideshow();
    assert.equal(slideshow.slideshow.value, true);
    tick();
    assert.equal(selectedIndex.value, 2);
    globalThis.document.hidden = true;
    tick();
    assert.equal(selectedIndex.value, 2);
    slideshow.stopSlideshow();
    assert.equal(cleared, 42);
    assert.equal(slideshow.slideshow.value, false);
  } finally {
    globalThis.window = oldWindow;
    globalThis.document = oldDocument;
  }
});
