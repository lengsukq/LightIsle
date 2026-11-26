import test from "node:test";
import assert from "node:assert/strict";
import { apiErrorFromResponse, readApiFailure } from "../src/api/apiFailure.ts";
import { describeUserFacingError } from "../src/api/userFacingError.ts";

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

test("all WebDAV mount, write, and credential error codes translate cleanly", () => {
  const davCodes = [
    "invalid_dav_request",
    "dav_credential_limit_reached",
    "dav_credential_failed",
    "dav_credential_not_found",
    "dav_unauthorized",
    "dav_remount_required",
    "dav_mount_not_found",
    "dav_replace_unsupported_save_as",
    "dav_invalid_destination",
    "dav_copy_unavailable",
    "dav_destination_exists",
    "dav_source_destination_overlap",
    "dav_cross_owner_move",
    "dav_busy",
    "dav_upload_too_large",
    "dav_metadata_too_large",
    "dav_invalid_metadata",
    "dav_access_denied",
  ];
  for (const code of davCodes) {
    const msg = describeUserFacingError(new Error(code));
    assert.doesNotMatch(msg, /排查标识：/, `Expected explicit label for ${code}`);
    assert.ok(msg.length > 6, `Expected descriptive message for ${code}`);
  }
});

test("unknown codes remain diagnosable, not just a raw identifier", () => {
  const description = describeUserFacingError(new Error("unexpected_domain_code"));
  assert.match(description, /刷新确认状态/);
  assert.match(description, /排查标识：unexpected_domain_code/);
});

test("all new domain error codes (downloads, reminders, collect links, pins, readers, OCR) translate cleanly", () => {
  const newDomainCodes = [
    "download_list_failed",
    "download_staging_failed",
    "ytdlp_not_installed",
    "ytdlp_failed",
    "ytdlp_timeout",
    "webarchive_invalid_url",
    "webarchive_blocked_address",
    "webarchive_too_many_redirects",
    "webarchive_too_large",
    "webarchive_unsupported_content_type",
    "webarchive_http_error",
    "webarchive_timeout",
    "invalid_reminder_request",
    "invalid_reminder_id",
    "reminder_limit_reached",
    "reminder_permission_denied",
    "reminder_not_found",
    "family_reminder_error",
    "invalid_collect_link_request",
    "collect_target_must_be_folder",
    "too_many_collect_links",
    "collect_link_creation_failed",
    "collect_link_list_failed",
    "invalid_collect_link_id",
    "collect_link_revoke_failed",
    "collect_password_invalid",
    "collect_grant_unavailable",
    "collect_auth_required",
    "invalid_collect_upload",
    "collect_extension_not_allowed",
    "collect_file_too_large",
    "collect_limit_reached",
    "invalid_offset",
    "invalid_pin_request",
    "pin_limit_reached",
    "file_pin_error",
    "invalid_insights_mode",
    "text_edit_unsupported_type",
    "text_file_too_large",
    "text_file_invalid_utf8",
    "file_modified_conflict",
    "archive_reader_unsupported",
    "archive_entry_type_forbidden",
    "invalid_reading_progress",
    "reading_progress_error",
    "invalid_path_prefix",
    "ocr_priority_unsupported",
  ];
  for (const code of newDomainCodes) {
    const msg = describeUserFacingError(new Error(code));
    assert.doesNotMatch(msg, /排查标识：/, `Expected explicit Chinese label for ${code}`);
    assert.ok(msg.length > 8, `Expected descriptive message for ${code}`);
  }
});

test("ApiFailure preserves safe localized Chinese server message and nextAction as fallback for future codes", async () => {
  const res = new Response(
    JSON.stringify({
      error: "future_domain_error",
      message: "服务端暂不支持此新型操作。",
      nextAction: "请升级客户端后重试。",
    }),
    { status: 400, headers: { "content-type": "application/json" } },
  );
  const failure = await readApiFailure(res);
  assert.equal(failure.serverMessage, "服务端暂不支持此新型操作。");
  assert.equal(failure.nextAction, "请升级客户端后重试。");
  const text = describeUserFacingError(failure);
  assert.match(text, /服务端暂不支持此新型操作。请升级客户端后重试。/);
  assert.match(text, /HTTP 400 · future_domain_error/);

  // Raw English or HTML payloads in message/nextAction must still be stripped
  const unsafe = apiErrorFromResponse(
    { status: 500 },
    { error: "future_unsafe", message: "<script>alert(1)</script>", nextAction: "token=secret" },
  );
  assert.equal(unsafe.serverMessage, null);
  assert.equal(unsafe.nextAction, null);
});
