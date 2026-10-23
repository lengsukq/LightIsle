import assert from "node:assert/strict";
import test from "node:test";
import { validateAlbumName } from "../src/albumNameValidation.js";

test("album name limit counts Unicode code points, including emoji", () => {
  assert.deepEqual(validateAlbumName("😀".repeat(60)), {
    valid: true,
    name: "😀".repeat(60),
    reason: null,
  });
  assert.equal(validateAlbumName("😀".repeat(61)).reason, "too_long");
  assert.equal(validateAlbumName("相".repeat(60)).valid, true);
});

test("album names are trimmed and reject empty or control characters", () => {
  assert.deepEqual(validateAlbumName("  假日  "), { valid: true, name: "假日", reason: null });
  assert.equal(validateAlbumName("  ").reason, "empty");
  assert.equal(validateAlbumName("a\u0007b").reason, "control_character");
});
