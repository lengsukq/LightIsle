import assert from "node:assert/strict";
import test from "node:test";
import {
  fingerprintFile,
  isWithinUploadSizeLimit,
  maxUploadSizeBytes,
  uploadSessionIdentity,
  uploadFingerprintChunkSize,
} from "../src/uploadIdentity.js";

function asFile(bytes, { name = "same.bin", lastModified = 1700000000000 } = {}) {
  const blob = new Blob([bytes]);
  return {
    name,
    size: blob.size,
    lastModified,
    slice: blob.slice.bind(blob),
  };
}

test("same path and size with changed middle bytes gets a different complete-content identity", async () => {
  const firstBytes = new Uint8Array(uploadFingerprintChunkSize * 2 + 19);
  const changedBytes = firstBytes.slice();
  changedBytes[uploadFingerprintChunkSize + 7] = 1;
  const first = asFile(firstBytes);
  const changed = asFile(changedBytes);

  const [firstFingerprint, changedFingerprint] = await Promise.all([
    fingerprintFile(first),
    fingerprintFile(changed),
  ]);
  const [firstIdentity, changedIdentity] = await Promise.all([
    uploadSessionIdentity("member", "photos/same.bin", first, firstFingerprint),
    uploadSessionIdentity("member", "photos/same.bin", changed, changedFingerprint),
  ]);

  assert.equal(first.size, changed.size);
  assert.equal(first.lastModified, changed.lastModified);
  assert.equal(firstIdentity.prefix, changedIdentity.prefix);
  assert.notEqual(firstIdentity.key, changedIdentity.key);
});

test("the session identity includes the user, destination, size, and last modified time", async () => {
  const file = asFile(new Uint8Array([1, 2, 3]));
  const fingerprint = await fingerprintFile(file);
  const original = await uploadSessionIdentity("alice", "family/same.bin", file, fingerprint);
  const otherUser = await uploadSessionIdentity("bob", "family/same.bin", file, fingerprint);
  const otherPath = await uploadSessionIdentity("alice", "private/same.bin", file, fingerprint);
  const otherTimestamp = await uploadSessionIdentity("alice", "family/same.bin", { ...file, lastModified: 1 }, fingerprint);
  const otherSize = await uploadSessionIdentity("alice", "family/same.bin", asFile(new Uint8Array([1, 2])), fingerprint);

  for (const identity of [otherUser, otherPath, otherTimestamp, otherSize]) {
    assert.notEqual(identity.prefix, original.prefix);
  }
});

test("fingerprinting reports bounded progress and can be cancelled between chunks", async () => {
  const file = asFile(new Uint8Array(uploadFingerprintChunkSize * 2 + 1));
  const controller = new AbortController();
  const progress = [];

  await assert.rejects(
    fingerprintFile(file, {
      signal: controller.signal,
      onProgress: (processedBytes, totalBytes) => {
        progress.push([processedBytes, totalBytes]);
        controller.abort();
      },
    }),
    { name: "AbortError" },
  );
  assert.deepEqual(progress, [[uploadFingerprintChunkSize, file.size]]);
});

test("the upload size gate accepts 32 GiB and rejects anything above it", () => {
  assert.equal(isWithinUploadSizeLimit(maxUploadSizeBytes), true);
  assert.equal(isWithinUploadSizeLimit(maxUploadSizeBytes + 1), false);
});
