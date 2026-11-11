import assert from "node:assert/strict";
import test from "node:test";
import {apiErrorFromResponse,readApiFailure} from "../src/apiFailure.ts";
import {describeUserFacingError} from "../src/userFacingError.ts";
import {describeRootOperationFailure,readRootDiscoveryResponse} from "../src/rootDiscovery.ts";

test("Core error reason wins over HTTP 503 and remains safely diagnosable", async () => {
  const response = new Response('{"error":"default_root_not_configured"}',{
    status:503, headers:{"content-type":"application/json"},
  });
  const error = await readApiFailure(response);
  assert.equal(error.status,503);
  assert.equal(error.code,"default_root_not_configured");
  assert.match(describeUserFacingError(error),/默认 NAS 存储目录/);
  assert.match(describeUserFacingError(error),/HTTP 503 · default_root_not_configured/);
  assert.doesNotMatch(describeUserFacingError(error),/硬盘离线/);
});

test("API security guard failures are not mistaken for file permission errors", () => {
  const missingHeader=describeUserFacingError(apiErrorFromResponse(
    {status:403},{error:"request_header_required"},
  ));
  const crossOrigin=describeUserFacingError(apiErrorFromResponse(
    {status:403},{error:"cross_origin_request_rejected"},
  ));
  assert.match(missingHeader,/安全请求标识/);
  assert.match(crossOrigin,/跨站请求/);
  assert.doesNotMatch(missingHeader,/文件.*权限/);
  assert.doesNotMatch(crossOrigin,/硬盘.*不可写/);
});

test("unknown service error retains safe diagnostic rather than inventing disk failure", async () => {
  const error = await readApiFailure(new Response('{"error":"ledger_retry_required"}',{status:503}));
  const message = describeUserFacingError(error);
  assert.match(message,/HTTP 503 · ledger_retry_required/);
  assert.match(message,/排查标识：ledger_retry_required/);
  assert.doesNotMatch(message,/原硬盘.*离线/);
});

test("malicious or malformed API payload never appears in error message", async () => {
  for (const body of [
    '{"error":"secret=private cookie token"}',
    '{"error":"invalid_token\nsecret"}',
    '<html><body>private credential=abc</body></html>',
  ]) {
    const error=await readApiFailure(new Response(body,{status:503}));
    const message=describeUserFacingError(error);
    assert.doesNotMatch(message,/secret=|private|credential=|invalid_token/);
    assert.match(message,/HTTP 503/);
  }
});

test("root-discovery response cannot erase a known storage setup reason", async () => {
  const discovered = await readRootDiscoveryResponse(new Response(
    '{"error":"default_root_not_configured"}',{status:503},
  ));
  assert.equal(discovered.kind,"error");
  assert.match(discovered.message,/默认 NAS 存储目录/);
  assert.match(describeRootOperationFailure(apiErrorFromResponse(
    {status:503},{error:"storage_registry_unavailable"},
  )),/存储硬盘登记/);
});

test("explicit permission and account failures never collapse into generic 503", () => {
  for (const [status,code,expected] of [
    [401,"authentication_required",/重新登录/],
    [403,"file_permission_denied",/权限/],
    [409,"root_generation_changed",/目录已发生变化/],
    [507,"insufficient_storage_space",/空间不足/],
  ]) {
    const message=describeUserFacingError(apiErrorFromResponse({status},{error:code}));
    assert.match(message,expected);
    assert.match(message,new RegExp(`HTTP ${status}`));
  }
});
