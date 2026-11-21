import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { TIMINGS_MS } from "../src/constants/timings.ts";

const WEB_DIR = new URL("../", import.meta.url).pathname;
const SRC_DIR = new URL("../src/", import.meta.url).pathname;

function walk(dir) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) out.push(...walk(full));
    else out.push(full);
  }
  return out;
}

function countNonReducedMotionImportant(cssText) {
  const lines = cssText.split("\n");
  let inReducedMotion = false;
  let depth = 0;
  let count = 0;
  for (const line of lines) {
    if (line.includes("prefers-reduced-motion")) inReducedMotion = true;
    if (inReducedMotion) {
      depth += (line.match(/\{/g) ?? []).length - (line.match(/\}/g) ?? []).length;
      if (depth <= 0 && line.includes("}")) {
        inReducedMotion = false;
        depth = 0;
      }
      continue;
    }
    if (line.includes("!important")) count += 1;
  }
  return count;
}

test("all Web tests live in the single apps/web/tests directory", () => {
  const srcTestFiles = walk(SRC_DIR).filter((file) => /\.test\.[cm]?[jt]s$/.test(file));
  assert.deepEqual(srcTestFiles, [], "apps/web/src must not contain scattered *.test.* files");
  assert.equal(existsSync(join(WEB_DIR, "test")), false, "legacy apps/web/test directory must not exist");
});

test("App.vue and AppShell.html delegate Files and Settings workbenches via typed contexts without inline style clutter", () => {
  const appVue = readFileSync(join(SRC_DIR, "App.vue"), "utf8");
  const appShell = readFileSync(join(SRC_DIR, "AppShell.html"), "utf8");
  const filesView = readFileSync(join(SRC_DIR, "features/files/FilesView.vue"), "utf8");
  const settingsView = readFileSync(join(SRC_DIR, "features/settings/SettingsView.vue"), "utf8");

  assert.match(appVue, /createShellLifecycleBridge\(/);
  assert.match(appVue, /provide\(FILES_VIEW_CTX,/);
  assert.match(appVue, /provide\(SETTINGS_VIEW_CTX,/);
  assert.ok(appShell.split("\n").length < 260, "AppShell.html should stay lean (<260 lines)");
  assert.doesNotMatch(appShell, /\bstyle="/, "AppShell.html must not contain static inline styles");
  assert.match(appShell, /<FilesView\b/);
  assert.match(appShell, /<SettingsView\b/);
  assert.match(filesView, /inject\(FILES_VIEW_CTX\)/);
  assert.match(settingsView, /inject\(SETTINGS_VIEW_CTX\)/);
  assert.doesNotMatch(settingsView, /\bstyle="/, "SettingsView.vue must not contain static inline styles");
});

test("PhotosView and CinemaView use typed provide/inject contexts and eliminate TDZ circular hacks", () => {
  const photosView = readFileSync(join(SRC_DIR, "features/photos/PhotosView.vue"), "utf8");
  const cinemaView = readFileSync(join(SRC_DIR, "features/cinema/CinemaView.vue"), "utf8");

  assert.doesNotMatch(photosView, /computed\(\{\s*get:\s*\(\)\s*=>\s*albumBusy\.value/);
  assert.match(photosView, /provide\(PHOTO_TIMELINE_CTX,/);
  assert.match(photosView, /provide\(PHOTO_ALBUMS_OVERVIEW_CTX,/);
  assert.match(photosView, /provide\(PHOTO_BATCH_CTX,/);
  assert.match(photosView, /provide\(PHOTO_VIEWER_CTX,/);
  assert.match(photosView, /<PhotosTimelineToolbar\s*\/>/);
  assert.match(photosView, /<PhotosBatchBar\s*\/>/);
  assert.match(photosView, /<PhotoViewerModal\s*\/>/);

  assert.match(cinemaView, /provide\(CINEMA_BROWSE_CTX,/);
  assert.match(cinemaView, /provide\(CINEMA_DETAIL_CTX,/);
  assert.match(cinemaView, /provide\(CINEMA_PLAYER_CTX,/);
  assert.match(cinemaView, /<CinemaBrowseGrids\s*\/>/);
  assert.match(cinemaView, /<CinemaDetailMetadataPanels\s+v-if="!viewerPlaying"\s*\/>/);
  assert.match(cinemaView, /<CinemaPlayerStage\s+v-if="viewerPlaying"\s+ref="playerStageRef"\s*\/>/);
});

test("core fluid CSS layers eliminate redundant !important rules and expose shared timing constants", () => {
  for (const name of ["styles/fluid.css", "styles/fluid-files.css", "styles/fluid-controls.css", "styles/style-content.css"]) {
    const css = readFileSync(join(SRC_DIR, name), "utf8");
    assert.equal(
      countNonReducedMotionImportant(css),
      0,
      `${name} must have 0 !important declarations outside prefers-reduced-motion`,
    );
  }
  assert.equal(TIMINGS_MS.FAST_POLL, 5_000);
  assert.equal(TIMINGS_MS.SLOW_POLL, 30_000);
  assert.equal(TIMINGS_MS.COPIED_FEEDBACK, 1_800);
});

test("apps/web/src keeps root entry files lean (<= 8) and preserves CSS cascade order in main.ts", () => {
  const rootFiles = readdirSync(SRC_DIR)
    .filter((name) => !statSync(join(SRC_DIR, name)).isDirectory())
    .sort();
  assert.ok(
    rootFiles.length <= 8,
    `apps/web/src root has ${rootFiles.length} files (${rootFiles.join(", ")}), expected <= 8`,
  );
  assert.ok(rootFiles.includes("main.ts"));
  assert.ok(rootFiles.includes("generated-fluid.css"));

  const mainTs = readFileSync(join(SRC_DIR, "main.ts"), "utf8");
  const styleIdx = mainTs.indexOf('import "./styles/style.css";');
  const genIdx = mainTs.indexOf('import "./generated-fluid.css";');
  const fluidIdx = mainTs.indexOf('import "./styles/fluid.css";');
  assert.ok(styleIdx >= 0 && genIdx > styleIdx && fluidIdx > genIdx, "main.ts must preserve style.css -> generated-fluid.css -> fluid.css cascade order");
});
