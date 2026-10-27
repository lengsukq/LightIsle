import test from "node:test";
import assert from "node:assert/strict";
import {describeUserFacingError} from "../src/userFacingError.js";

test("common storage and permission codes provide specific corrective action",()=>{
  assert.match(describeUserFacingError(new Error("volume_offline")),/原硬盘.*重新连接/);
  assert.match(describeUserFacingError(new Error("file_permission_denied")),/授权/);
  assert.match(describeUserFacingError(new Error("download_unavailable")),/aria2/);
});
test("HTTP failures and network errors are not bare statuses",()=>{
  assert.match(describeUserFacingError(new Error("HTTP 503")),/服务或存储/);
  assert.match(describeUserFacingError(new Error("HTTP 401")),/重新登录/);
  assert.match(describeUserFacingError(new TypeError("Failed to fetch")) ,/检查网络/);
  assert.doesNotMatch(describeUserFacingError(new Error("HTTP 503")),/^HTTP /);
});
test("JSON API errors are translated and natural-language messages survive",()=>{
  assert.match(describeUserFacingError(new Error('{"error":"drive_identity_changed_refresh_required"}')),/确认是原设备/);
  assert.equal(describeUserFacingError(new Error("操作未授权，请重新选择。")),"操作未授权，请重新选择。");
});
test("unknown codes remain diagnosable, not just a raw identifier",()=>{
  const description=describeUserFacingError(new Error("unexpected_domain_code"));
  assert.match(description,/刷新确认状态/);
  assert.match(description,/排查标识：unexpected_domain_code/);
});
