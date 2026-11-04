import assert from "node:assert/strict";
import test from "node:test";
import { nextTick, ref } from "vue";
import { usePhotoViewer } from "./usePhotoViewer.ts";

const asset = id => ({ id, name: `${id}.jpg`, path: `${id}.jpg`, type: "photo" });

test("switching photos cancels the previous preview and rejects stale completion", async () => {
  const previousImage = globalThis.Image;
  const images = [];
  globalThis.Image = class {
    constructor() { images.push(this); }
    removeAttribute() { this.removed = true; }
  };
  try {
    const selected = ref(asset(1));
    const viewer = usePhotoViewer({
      selected,
      mediaPath: path => `/root${path}`,
      thumb: photo => `/thumb/${photo.id}`,
      original: photo => `/original/${photo.id}`,
      move: () => false,
    });
    viewer.startViewerStages(selected.value);
    const staleLoad = images[0].onload;
    selected.value = asset(2);
    viewer.startViewerStages(selected.value);
    assert.equal(images[0].removed, true);
    staleLoad();
    await nextTick();
    assert.equal(viewer.viewerStage.value, "thumb");
    images[1].onload();
    await nextTick();
    assert.equal(viewer.viewerStage.value, "preview");
    assert.match(viewer.viewerSrc(selected.value), /2.jpg/);
    viewer.requestViewerOriginal();
    images[2].onload();
    await nextTick();
    assert.equal(viewer.viewerStage.value, "original");
    assert.equal(viewer.viewerSrc(selected.value), "/original/2");
    viewer.cancelViewerLoads();
  } finally {
    globalThis.Image = previousImage;
  }
});
