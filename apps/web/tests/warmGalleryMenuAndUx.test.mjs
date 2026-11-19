import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";

const SRC_DIR = new URL("../src/", import.meta.url).pathname;

function readSrc(rel) {
  return readFileSync(join(SRC_DIR, rel), "utf8");
}

test("Web menu bars (sidebar, topbar, segmented tabs, overflow action menu, mobile nav) maintain clean alignment & styling", () => {
  const fluidCss = readSrc("fluid.css");
  assert.match(fluidCss, /\.side-nav\s+button\s*\{[\s\S]*?width:\s*100%;[\s\S]*?text-align:\s*left;/);
  assert.match(fluidCss, /\.sidebar\.dock-collapsed\s+\.side-nav\s+button\s*\+\s*button::before\s*\{\s*display:\s*none;\s*\}/);
  assert.match(fluidCss, /\.topbar\s*\{[\s\S]*?z-index:\s*45;/);

  const controlsCss = readSrc("fluid-controls.css");
  assert.doesNotMatch(
    controlsCss,
    /\.album-tabs button,\s*\.cinema-tabs button,\s*\.circle-action\s*\{[\s\S]*?border-radius:\s*9px/,
    "fluid-controls.css must not force 9px rectangular borders onto .album-tabs / .cinema-tabs IsleChip pills",
  );

  const cinemaCss = readSrc("CinemaView.css");
  assert.match(cinemaCss, /\.cinema-tabs\s+\.isle-chip\.is-selected/);

  const photosCss = readSrc("PhotosView.css");
  assert.match(photosCss, /\.type-tabs\s+\.isle-chip\.is-selected/);

  const mediaResponsiveCss = readSrc("style-media-responsive.css");
  assert.doesNotMatch(mediaResponsiveCss, /@media\s*\(max-width:\s*768px\)\s*\{\s*\.sidebar\s*\{\s*display:\s*none/);
  assert.match(mediaResponsiveCss, /\.nav-icon-box\[data-color="blue"\]/);

  const dashboardCss = readSrc("fluid-dashboard.css");
  assert.match(dashboardCss, /\.vitality-metrics-row\s*\{[\s\S]*?grid-auto-rows:\s*1fr;/);
  assert.match(dashboardCss, /\.mobile-nav\s*\{[\s\S]*?left:\s*50%;[\s\S]*?right:\s*auto;/);

  const filesCss = readSrc("fluid-files.css");
  assert.match(filesCss, /\.files-panel\s*\{[\s\S]*?overflow:\s*visible;/);

  const actionMenuVue = readSrc("IsleActionMenu.vue");
  assert.match(actionMenuVue, /<Teleport to="body">/);

  const helpBtnVue = readSrc("IsleHelpButton.vue");
  assert.match(helpBtnVue, /<IsleModal/);
});
