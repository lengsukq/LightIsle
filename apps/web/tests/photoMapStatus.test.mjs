import test from "node:test";
import assert from "node:assert/strict";
import { describePhotoMapFailure } from "../src/photoMapStatus.js";

test("offline volume prompts reattaching the original volume instead of claiming an empty library", () => {
  const message = describePhotoMapFailure(new Error("volume_offline"));
  assert.match(message, /原硬盘/);
  assert.match(message, /重新连接/);
  assert.doesNotMatch(message, /没有.*照片/);
});

test("map failures distinguish permissions, authentication and root changes", () => {
  assert.match(describePhotoMapFailure(new Error("file_permission_denied")), /权限/);
  assert.match(describePhotoMapFailure(new Error("authentication_required")), /重新登录/);
  assert.match(describePhotoMapFailure(new Error("root_context_changed")), /共享目录/);
  assert.match(describePhotoMapFailure(new Error("gallery_unavailable")), /Core/);
});

test("map errors keep unknown failure codes visible and name network failures", () => {
  assert.match(describePhotoMapFailure(new Error("unexpected_backend_error")), /unexpected_backend_error/);
  assert.match(describePhotoMapFailure(new TypeError("Failed to fetch")), /网络/);
});
