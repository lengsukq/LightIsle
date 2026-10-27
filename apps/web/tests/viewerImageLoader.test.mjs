import test from "node:test";
import assert from "node:assert/strict";
import { createViewerImageLoader } from "../src/viewerImageLoader.js";

function setup() {
  const images = [];
  const loader = createViewerImageLoader(() => {
    const image = { src: "", onload: null, onerror: null, removeAttribute() { this.src = ""; } };
    images.push(image);
    return image;
  });
  return { loader, images };
}
test("replacing and closing photos settles old loads and releases callbacks", async () => {
  const { loader, images } = setup();
  const first = loader.load("first");
  const stale = images[0].onload;
  const second = loader.load("second");
  assert.equal(await first, false);
  assert.equal(images[0].src, "");
  assert.equal(images[0].onload, null);
  stale(); // an already queued event cannot finish the new request
  loader.cancel();
  assert.equal(await second, false);
  assert.equal(images[1].src, "");
  assert.equal(images[1].onerror, null);
  loader.cancel();
});
test("failed previews do not promote the stage, and retry remains possible", async () => {
  const { loader, images } = setup();
  const failed = loader.load("broken");
  images[0].onerror();
  assert.equal(await failed, false);
  const retry = loader.load("retry");
  images[1].onload();
  assert.equal(await retry, true);
  assert.equal(images[1].onload, null);
  assert.equal(images[1].onerror, null);
});
