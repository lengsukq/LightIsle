import assert from "node:assert/strict";
import test from "node:test";
import {
  describeRootContext,
  describeRootOperationFailure,
  readRootDiscoveryResponse,
  rootDiscoveryNetworkError,
} from "../src/rootDiscovery.js";

const root = { rootID: "root-1", name: "家庭资料", generation: 3, online: true };

test("disabled discovery API selects the supported single-root contract only on 404", async () => {
  assert.deepEqual(await readRootDiscoveryResponse(new Response("{}", { status: 404 })), { kind: "legacy" });

  const html = await readRootDiscoveryResponse(new Response("<!doctype html><html></html>", {
    status: 200,
    headers: { "content-type": "text/html" },
  }));
  assert.equal(html.kind, "error");
  assert.match(html.message, /无法识别/);
});

test("malformed discovery payloads and HTTP failures remain explicit errors", async () => {
  for (const body of ["{}", "{\"roots\":null}", "{\"roots\":[{}]}"]) {
    const result = await readRootDiscoveryResponse(new Response(body, { status: 200 }));
    assert.equal(result.kind, "error");
  }

  const expired = await readRootDiscoveryResponse(new Response(JSON.stringify({ error: "authentication_required" }), { status: 401 }));
  assert.deepEqual(expired, { kind: "error", message: "登录状态已失效，请重新登录。" });

  const unavailable = await readRootDiscoveryResponse(new Response(JSON.stringify({ error: "root_services_unavailable" }), { status: 503 }));
  assert.deepEqual(unavailable, { kind: "error", message: "共享目录服务暂时不可用，请稍后重试。" });
});

test("an empty v2 root list keeps the v1 compatibility choice instead of asserting no access", async () => {
  const result = await readRootDiscoveryResponse(new Response(JSON.stringify({ roots: [] }), { status: 200 }));
  assert.deepEqual(result, { kind: "roots", roots: [] });

  const noV2Roots = describeRootContext({ state: "multi", hasContext: false, rootCount: 0 });
  assert.equal(noV2Roots.kind, "choose");
  assert.match(noV2Roots.message, /原共享目录（兼容）/);
  assert.doesNotMatch(noV2Roots.message, /没有可访问的共享目录/);

  const loading = describeRootContext({ state: "unknown", loading: true });
  assert.equal(loading.kind, "loading");
  assert.equal(loading.role, "status");

  const failed = describeRootContext({ state: "error", error: "无法连接到轻屿服务。" });
  assert.equal(failed.kind, "error");
  assert.equal(failed.role, "alert");
  assert.match(failed.message, /无法连接/);

  const offline = describeRootContext({ state: "multi", hasContext: true, rootCount: 1, selectedRoot: { ...root, online: false }, isAdmin: false });
  assert.equal(offline.kind, "offline");
  assert.match(offline.message, /家庭资料.*离线|家庭资料.*不可用/);
});

test("network and root-operation errors use recovery instructions instead of permission guesses", () => {
  assert.match(rootDiscoveryNetworkError(new TypeError("Failed to fetch")), /检查 Mac.*网络/);
  assert.match(describeRootOperationFailure(new Error("root_unavailable")), /磁盘.*离线/);
  assert.match(describeRootOperationFailure(new Error("file_permission_denied")), /无权访问/);
  assert.match(describeRootOperationFailure(new Error("HTTP 401")), /登录状态已失效/);
  assert.match(describeRootOperationFailure(new Error("HTTP 403")), /无权访问/);
  assert.match(describeRootOperationFailure(new Error("HTTP 503")), /服务暂时不可用/);
  assert.match(describeRootOperationFailure(new Error("root_services_unavailable")), /服务暂时不可用/);
});

test("media service and disk failures retain actionable recovery guidance", () => {
  assert.match(describeRootOperationFailure(new Error("service_unavailable")), /暂时不可用.*重试/);
  assert.match(describeRootOperationFailure(new Error("shared_directory_unavailable")), /磁盘.*离线/);
  assert.match(describeRootOperationFailure(new SyntaxError("Unexpected token")), /数据无法读取.*重试/);
});
