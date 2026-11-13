import assert from "node:assert/strict";
import test from "node:test";
import {
  FILE_SEARCH_HISTORY_MAX,
  buildFileSearchHistoryKey,
  clearFileSearchHistory,
  folderLabelOfPath,
  highlightSearchSegments,
  parentDirOfPath,
  rankSearchEntries,
  readFileSearchHistory,
  recordFileSearchHistory,
  removeFileSearchHistory,
  tokenizeSearchQuery,
} from "../src/fileSearchUtils.ts";

function makeMemoryStorage() {
  const map = new Map();
  return {
    getItem(k) {
      return map.has(k) ? map.get(k) : null;
    },
    setItem(k, v) {
      map.set(k, String(v));
    },
    removeItem(k) {
      map.delete(k);
    },
  };
}

test("tokenizeSearchQuery supports single-character CJK/ASCII tokens and deduplicates case-insensitively", () => {
  assert.deepEqual(tokenizeSearchQuery("猫"), ["猫"]);
  assert.deepEqual(tokenizeSearchQuery(" a  2026  A "), ["a", "2026"]);
  assert.deepEqual(tokenizeSearchQuery("   "), []);
});

test("highlightSearchSegments safely slices matched tokens without modifying literal characters", () => {
  const segs = highlightSearchSegments("旅行 <2026> 东京-攻略.pdf", "东京 2026");
  assert.deepEqual(segs, [
    { text: "旅行 <", match: false },
    { text: "2026", match: true },
    { text: "> ", match: false },
    { text: "东京", match: true },
    { text: "-攻略.pdf", match: false },
  ]);
});

test("rankSearchEntries orders exact, prefix, multi-token filename, and path matches", () => {
  const entries = [
    { name: "note.txt", path: "archive/tokyo/2026/note.txt" },
    { name: "2026_tokyo_album_backup.zip", path: "2026_tokyo_album_backup.zip" },
    { name: "tokyo-trip-2026.pdf", path: "docs/tokyo-trip-2026.pdf" },
    { name: "tokyo 2026.md", path: "docs/tokyo 2026.md" },
  ];
  const ranked = rankSearchEntries(entries, "tokyo 2026");
  assert.deepEqual(
    ranked.map((item) => item.name),
    ["tokyo 2026.md", "tokyo-trip-2026.pdf", "2026_tokyo_album_backup.zip", "note.txt"],
  );
});

test("parentDirOfPath and folderLabelOfPath normalize root and nested paths", () => {
  assert.equal(parentDirOfPath("report.pdf"), ".");
  assert.equal(parentDirOfPath("/photos/2026/spring/IMG_001.jpg"), "photos/2026/spring");
  assert.equal(folderLabelOfPath(".", "主硬盘"), "主硬盘");
  assert.equal(folderLabelOfPath("photos/2026/spring"), "spring");
});

test("search history isolates by account and root, caps length, and removes/clears cleanly", () => {
  const storage = makeMemoryStorage();
  const alicePrimary = buildFileSearchHistoryKey("alice", "disk-a");
  const aliceSecondary = buildFileSearchHistoryKey("alice", "disk-b");
  const bobPrimary = buildFileSearchHistoryKey("bob", "disk-a");

  assert.notEqual(alicePrimary, aliceSecondary);
  assert.notEqual(alicePrimary, bobPrimary);
  assert.equal(buildFileSearchHistoryKey("", "disk-a"), "");

  for (let i = 1; i <= FILE_SEARCH_HISTORY_MAX + 3; i += 1) {
    recordFileSearchHistory(alicePrimary, `term-${i}`, FILE_SEARCH_HISTORY_MAX, storage);
  }
  const aliceItems = readFileSearchHistory(alicePrimary, storage);
  assert.equal(aliceItems.length, FILE_SEARCH_HISTORY_MAX);
  assert.equal(aliceItems[0], `term-${FILE_SEARCH_HISTORY_MAX + 3}`);

  recordFileSearchHistory(alicePrimary, "TERM-5", FILE_SEARCH_HISTORY_MAX, storage);
  const reordered = readFileSearchHistory(alicePrimary, storage);
  assert.equal(reordered[0], "TERM-5");
  assert.equal(reordered.filter((item) => item.toLowerCase() === "term-5").length, 1);
  assert.deepEqual(readFileSearchHistory(bobPrimary, storage), []);

  removeFileSearchHistory(alicePrimary, "TERM-5", storage);
  assert.equal(readFileSearchHistory(alicePrimary, storage).includes("TERM-5"), false);

  clearFileSearchHistory(alicePrimary, storage);
  assert.deepEqual(readFileSearchHistory(alicePrimary, storage), []);
});
