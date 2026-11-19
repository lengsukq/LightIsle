import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { ref } from "vue";
import { useFileActionsAndGrants } from "../src/useFileActionsAndGrants.ts";

test("PhotoViewerModal supports fileBrowserMode and AppShell routes file media through it", () => {
  const modalSfc = readFileSync(new URL("../src/PhotoViewerModal.vue", import.meta.url), "utf8");
  const shellHtml = readFileSync(new URL("../src/AppShell.html", import.meta.url), "utf8");
  assert.match(modalSfc, /fileBrowserMode\?:\s*boolean/);
  assert.match(modalSfc, /v-if="!fileBrowserMode"/);
  assert.match(modalSfc, /title="下载原文件"/);
  assert.match(shellHtml, /<PhotoViewerModal\s+v-bind="fileMediaModalProps"\s+v-on="fileMediaModalEvents"\s*\/>/);
});

test("useFileActionsAndGrants upgrades cinema-indexed videos and reuses mixed lightbox for unindexed media", async () => {
  const entries = ref([
    { name: "clip.mp4", path: "Media/clip.mp4", type: "file", size: 2048, modified: "2026-11-17T00:00:00Z", canWrite: false },
    { name: "movie.mkv", path: "Media/movie.mkv", type: "file", size: 4096, modified: "2026-11-17T00:00:00Z", canWrite: false },
    { name: "photo.jpg", path: "Media/photo.jpg", type: "file", size: 1024, modified: "2026-11-17T00:00:00Z", canWrite: false },
  ]);
  const matchedFilms = [];
  const actions = useFileActionsAndGrants({
    userRole: () => "member",
    selectedRootID: () => "root-1",
    rootFeatureContextReady: () => true,
    rootContextEpoch: () => 1,
    currentRootContextKey: () => "root-1:1",
    filesPath: ref("Media"),
    sharedRootName: ref("共享盘"),
    currentFolderCanWrite: ref(false),
    fileDirectoryLoaded: ref(true),
    fileEntries: entries,
    checkedFiles: ref([]),
    filesError: ref(""),
    showingTrash: ref(false),
    searchingFiles: ref(false),
    failedThumbnails: ref(new Set()),
    scopedApiPath: (p) => p,
    scopedMediaPath: (p) => p,
    rootFetch: async (url) => {
      if (url.startsWith("/api/v2/cinema/lookup?path=" + encodeURIComponent("Media/movie.mkv"))) {
        return new Response(JSON.stringify({ id: 88, title: "Movie", path: "Media/movie.mkv", kind: "movie" }), { status: 200 });
      }
      return new Response(JSON.stringify({ error: "film_not_found" }), { status: 404 });
    },
    jsonGet: async () => ({}),
    jsonWrite: async () => ({}),
    loadFiles: async () => {},
    loadTrash: async () => {},
    isAbortError: () => false,
    onCinemaFilmMatched: (film) => matchedFilms.push(film),
  });

  await actions.previewFile(entries.value[1]);
  assert.equal(matchedFilms.length, 1);
  assert.equal(matchedFilms[0].id, 88);
  assert.equal(actions.fileMediaSelected.value, null);

  await actions.previewFile(entries.value[0]);
  assert.equal(actions.fileMediaSelected.value?.path, "Media/clip.mp4");
  assert.deepEqual(actions.fileMediaAssets.value.map((a) => a.path), [
    "Media/clip.mp4",
    "Media/movie.mkv",
    "Media/photo.jpg",
  ]);
  assert.equal(actions.fileMediaIndex.value, 0);
  assert.equal(actions.showFileMediaAt(2), true);
  assert.equal(actions.fileMediaSelected.value?.type, "photo");
  actions.closeFileMedia();
  assert.equal(actions.fileMediaSelected.value, null);
});
