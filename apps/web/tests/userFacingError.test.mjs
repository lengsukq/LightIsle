import test from "node:test";
import assert from "node:assert/strict";
import { describeUserFacingError } from "../src/userFacingError.ts";

test("common storage and permission codes provide specific corrective action", () => {
  assert.match(describeUserFacingError(new Error("volume_offline")), /原硬盘.*重新连接/);
  assert.match(describeUserFacingError(new Error("file_permission_denied")), /授权/);
  assert.match(describeUserFacingError(new Error("download_unavailable")), /aria2/);
});

test("HTTP failures and network errors are not bare statuses", () => {
  assert.match(describeUserFacingError(new Error("HTTP 503")), /没有提供可识别的原因/);
  assert.match(describeUserFacingError(new Error("HTTP 401")), /重新登录/);
  assert.match(describeUserFacingError(new TypeError("Failed to fetch")), /检查网络/);
  assert.doesNotMatch(describeUserFacingError(new Error("HTTP 503")), /^HTTP /);
});

test("JSON API errors are translated and natural-language messages survive", () => {
  assert.match(
    describeUserFacingError(new Error('{"error":"drive_identity_changed_refresh_required"}')),
    /确认是原设备/
  );
  assert.equal(describeUserFacingError(new Error("操作未授权，请重新选择。")), "操作未授权，请重新选择。");
});

test("file_too_large_to_share reflects the 32 GiB backend limit", () => {
  const msg = describeUserFacingError(new Error("file_too_large_to_share"));
  assert.match(msg, /\b32 GiB\b/);
  assert.doesNotMatch(msg, /\b2 GiB\b/);
});

test("all SMB management and App Center activation codes translate cleanly", () => {
  const smbCodes = [
    "invalid_smb_request",
    "smb_share_not_found",
    "smb_share_already_exists",
    "smb_elevation_required",
    "smb_protected_path_rejected",
    "smb_personal_guest_forbidden",
    "smb_personal_confirmation_required",
    "smb_root_offline",
    "smb_operation_failed",
  ];
  for (const code of smbCodes) {
    const msg = describeUserFacingError(new Error(code));
    assert.doesNotMatch(msg, /排查标识：/, `Expected explicit label for ${code}`);
    assert.ok(msg.length > 6, `Expected descriptive message for ${code}`);
  }

  assert.equal(
    describeUserFacingError(new Error("app_pending_activation")),
    "该轻应用由外部工具创建或修改，需先在应用中心由管理员确认激活后才能运行。"
  );
  assert.doesNotMatch(describeUserFacingError(new Error("app_disabled")), /排查标识：/);
  assert.doesNotMatch(describeUserFacingError(new Error("app_running")), /排查标识：/);
});

test("unknown codes remain diagnosable, not just a raw identifier", () => {
  const description = describeUserFacingError(new Error("unexpected_domain_code"));
  assert.match(description, /刷新确认状态/);
  assert.match(description, /排查标识：unexpected_domain_code/);
});
