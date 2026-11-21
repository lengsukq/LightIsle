import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const webSrc = path.resolve(import.meta.dirname, "../src");
const themeSource = fs.readFileSync(path.join(webSrc, "styles/theme.ts"), "utf8");
const presetsSource = fs.readFileSync(path.join(webSrc, "styles/themePresets.ts"), "utf8");
const auroraCss = fs.readFileSync(path.join(webSrc, "styles/fluid-aurora.css"), "utf8");
const controlsCss = fs.readFileSync(path.join(webSrc, "styles/fluid-controls.css"), "utf8");
const appearanceSource = fs.readFileSync(path.join(webSrc, "styles/useShellAppearance.ts"), "utf8");

const EXPECTED_PRESETS = [
  "warm_gallery",
  "nordic_glass",
  "swiss_editorial",
  "neo_brutal_pop",
  "cyber_terminal",
];

test("Web theme presets align 1-to-1 with all 5 Flutter IsleThemePresets", () => {
  for (const id of EXPECTED_PRESETS) {
    assert.match(presetsSource, new RegExp(`id:\\s*"${id}"`), `themePresets.ts missing preset ${id}`);
    assert.match(
      auroraCss,
      new RegExp(`\\[data-theme-preset="${id}"\\]`),
      `fluid-aurora.css missing backdrop rules for ${id}`,
    );
  }
});

test("applyTheme updates preset variables and datasets instead of static tokens.json colors", () => {
  assert.doesNotMatch(themeSource, /tokens\.color\[theme\]/);
  assert.match(themeSource, /root\.dataset\.theme\s*=\s*theme/);
  assert.match(themeSource, /root\.dataset\.themePreset\s*=\s*resolvedPreset/);
  assert.match(themeSource, /getThemeVariables\(theme,\s*resolvedPreset\)/);
  assert.match(themeSource, /"--brand-blue":\s*p\.brandBlue/);
});

test("Full-page theme rules cover auth, overview, files, photos, cinema, apps, cards, and mobile nav", () => {
  for (const selector of [
    ".auth-scene",
    ".sanctuary-card",
    ".vitality-card",
    ".files-panel",
    ".photos-nav-bar",
    ".cinema-featured",
    ".cinema-tile",
    ".app-card",
    ".isle-card",
    ".mobile-nav",
  ]) {
    assert.ok(auroraCss.includes(selector), `fluid-aurora.css missing full-page rule for ${selector}`);
  }
  assert.match(controlsCss, /\.auth-scene[\s\S]*var\(--fluid-canvas-top/);
});

test("useShellAppearance persists both light/dark theme and preset selection", () => {
  assert.match(appearanceSource, /localStorage\.setItem\(THEME_STORAGE_KEY/);
  assert.match(appearanceSource, /localStorage\.getItem\(THEME_STORAGE_KEY\)/);
  assert.match(appearanceSource, /localStorage\.setItem\(PRESET_STORAGE_KEY/);
  assert.match(appearanceSource, /applyTheme\(next,\s*atmosphere\.value\)/);
  assert.match(appearanceSource, /applyTheme\(theme\.value,\s*resolved\)/);
});
