import test from "node:test";
import assert from "node:assert/strict";
import {
  appendAISearchParams,
  chooseDuplicateKeepPath,
  selectRecommendedWasteIds,
} from "../src/usePhotoAISearchAndPeople.ts";
import { describeUserFacingError } from "../src/userFacingError.ts";

test("appendAISearchParams attaches personId and non-default searchMode cleanly", () => {
  const q1 = new URLSearchParams();
  appendAISearchParams(q1, "", "ocr", 0);
  assert.equal(q1.toString(), "");

  const q2 = new URLSearchParams();
  appendAISearchParams(q2, "发票", "ocr", 7);
  assert.equal(q2.get("personId"), "7");
  assert.equal(q2.get("searchMode"), "ocr");

  const q3 = new URLSearchParams();
  appendAISearchParams(q3, "海边日落", "all", 0);
  assert.equal(q3.get("searchMode"), null);
});

test("selectRecommendedWasteIds keeps Best-Shot and respects canTrash permission", () => {
  const ids = selectRecommendedWasteIds({
    groupId: "burst-1",
    kind: "burst",
    takenAt: 1700000000,
    recommendedAssetId: 20,
    recommendReason: "清晰度更高 · 综合画质更佳",
    reclaimableBytes: 4096,
    items: [
      {
        assetId: 10,
        path: "SharedPhotos/a.jpg",
        name: "a.jpg",
        size: 2048,
        takenAt: 1700000000,
        width: 4000,
        height: 3000,
        sharpness: 0.41,
        qualityScore: 0.55,
        recommended: false,
        canTrash: true,
      },
      {
        assetId: 20,
        path: "SharedPhotos/b.jpg",
        name: "b.jpg",
        size: 2048,
        takenAt: 1700000001,
        width: 4000,
        height: 3000,
        sharpness: 0.88,
        qualityScore: 0.91,
        recommended: true,
        canTrash: true,
      },
      {
        assetId: 30,
        path: "SharedPhotos/readonly.jpg",
        name: "readonly.jpg",
        size: 2048,
        takenAt: 1700000002,
        width: 4000,
        height: 3000,
        sharpness: 0.3,
        qualityScore: 0.4,
        recommended: false,
        canTrash: false,
      },
    ],
  });
  assert.deepEqual(ids, [10]);
});

test("chooseDuplicateKeepPath honors shortest_path, newest, and oldest strategies", () => {
  const items = [
    {
      path: "Archive/2025/Backup/movie.mkv",
      name: "movie.mkv",
      size: 10485760,
      modified: 1700000100,
      identity: "1:10:1",
      canTrash: true,
    },
    {
      path: "Movies/movie.mkv",
      name: "movie.mkv",
      size: 10485760,
      modified: 1700000200,
      identity: "1:11:1",
      canTrash: true,
    },
    {
      path: "Downloads/movie-copy.mkv",
      name: "movie-copy.mkv",
      size: 10485760,
      modified: 1700000500,
      identity: "1:12:1",
      canTrash: true,
    },
  ];
  assert.equal(chooseDuplicateKeepPath(items, "shortest_path"), "Movies/movie.mkv");
  assert.equal(chooseDuplicateKeepPath(items, "newest"), "Downloads/movie-copy.mkv");
  assert.equal(chooseDuplicateKeepPath(items, "oldest"), "Archive/2025/Backup/movie.mkv");
});

test("AI album and duplicate cleanup error codes translate to actionable Chinese messages", () => {
  const codes = [
    "file_changed_rescan_required",
    "must_keep_one_photo",
    "must_keep_one_file",
    "invalid_person_name",
    "cannot_merge_same_person",
    "invalid_search_mode",
    "invalid_person_id",
  ];
  for (const code of codes) {
    const msg = describeUserFacingError(new Error(code));
    assert.doesNotMatch(msg, /排查标识：/, `Expected explicit label for ${code}`);
    assert.ok(msg.length > 8, `Expected actionable message for ${code}`);
  }
});
