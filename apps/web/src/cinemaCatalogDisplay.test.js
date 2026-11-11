import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  duplicateCinemaTitleKeys,
  filmFolderBadge,
  formatCinemaClock,
  normalizeCinemaTitleKey,
  shouldShowCinemaRecentShelf,
} from "./cinemaCatalogDisplay.ts";

test("formatCinemaClock formats seconds into Flutter-aligned MM:SS and H:MM:SS", () => {
  assert.equal(formatCinemaClock(0), "0:00");
  assert.equal(formatCinemaClock(-5), "0:00");
  assert.equal(formatCinemaClock(Number.NaN), "0:00");
  assert.equal(formatCinemaClock(4), "0:04");
  assert.equal(formatCinemaClock(125), "2:05");
  assert.equal(formatCinemaClock(9678), "2:41:18");
});

test("shouldShowCinemaRecentShelf hides redundant shelf when entire library fits in grid", () => {
  assert.equal(shouldShowCinemaRecentShelf(0, 0), false);
  assert.equal(shouldShowCinemaRecentShelf(4, 0), false);
  assert.equal(shouldShowCinemaRecentShelf(8, 0), false);
  assert.equal(shouldShowCinemaRecentShelf(8, 24), true);
  assert.equal(shouldShowCinemaRecentShelf(9, 0), true);
});

test("duplicateCinemaTitleKeys detects exact and punctuation-variant duplicates and filmFolderBadge disambiguates folders", () => {
  const films = [
    { title: "杀戮都市 O" },
    { title: "杀戮都市：O" },
    { title: "黑豹2" },
    { title: "黑豹2" },
    { title: "星际穿越" },
  ];
  const dupes = duplicateCinemaTitleKeys(films);
  assert.equal(dupes.has(normalizeCinemaTitleKey("杀戮都市 O")), true);
  assert.equal(dupes.has(normalizeCinemaTitleKey("杀戮都市：O")), true);
  assert.equal(dupes.has(normalizeCinemaTitleKey("黑豹2")), true);
  assert.equal(dupes.has(normalizeCinemaTitleKey("星际穿越")), false);

  assert.equal(filmFolderBadge("Users/u1/videos/黑豹2.mkv"), "个人空间");
  assert.equal(filmFolderBadge("Users/u1/videos/漫威/黑豹2.mkv"), "个人空间 · 漫威");
  assert.equal(filmFolderBadge("影视/黑豹2.mkv"), "影视");
  assert.equal(filmFolderBadge("黑豹2.mkv"), "根目录");
});

test("Web cinema player renders a single unified bottom transport bar without native video controls", () => {
  const stageSfc = readFileSync(new URL("./CinemaPlayerStage.vue", import.meta.url), "utf8");
  const viewSfc = readFileSync(new URL("./CinemaView.vue", import.meta.url), "utf8");

  assert.doesNotMatch(stageSfc, /<video[^>]*\bcontrols\b/);
  assert.doesNotMatch(viewSfc, /cinema-seek-controls/);
  assert.doesNotMatch(viewSfc, /cinema-absolute-progress/);
  assert.match(stageSfc, /class="cinema-seek-slider"/);
  assert.match(viewSfc, /<CinemaPlayerStage\b/);
});
