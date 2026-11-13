import test from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { describeUserFacingError } from "../src/userFacingError.ts";

const SRC_DIR = new URL("../src/", import.meta.url).pathname;

function walk(dir) {
  const files = [];
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) {
      files.push(...walk(full));
    } else {
      files.push(full);
    }
  }
  return files;
}

test("apps/web/src maintains Clean Code guardrails (0 native select/prompt/alert/confirm, 0 prod .js, <800 lines)", () => {
  const files = walk(SRC_DIR);
  const prodFiles = files.filter((file) => !/\.test\.[cm]?[jt]s$/.test(file));

  const prodJs = prodFiles.filter((file) => file.endsWith(".js"));
  assert.deepEqual(prodJs, [], "production .js files under apps/web/src must stay at 0");

  for (const file of prodFiles) {
    const content = readFileSync(file, "utf8");
    const lineCount = content.split("\n").length;
    assert.ok(lineCount < 800, `${file} has ${lineCount} lines, must remain strictly < 800`);
    assert.doesNotMatch(
      content,
      /\bwindow\.(confirm|alert|prompt)\s*\(/,
      `${file} must not call window.confirm/alert/prompt`,
    );
    if (file.endsWith(".vue") || file.endsWith(".html")) {
      assert.doesNotMatch(
        content,
        /<select[\s>]/i,
        `${file} must use AppleSelect instead of native <select>`,
      );
    }
  }
});

test("AppsCenterView, MobileNavDrawer, and UserStoragePanel maintain Beta UX & role isolation", () => {
  const appsView = readFileSync(join(SRC_DIR, "AppsCenterView.vue"), "utf8");
  assert.match(appsView, /<AppleSelect/);
  assert.match(appsView, /modalError/);
  assert.match(appsView, /确认激活/);
  assert.doesNotMatch(appsView, /writeAppsClipboard/);

  const mobileNav = readFileSync(join(SRC_DIR, "MobileNavDrawer.vue"), "utf8");
  assert.match(mobileNav, /["']computer["']/);
  assert.match(mobileNav, /showComputerFilesNav/);

  const storagePanel = readFileSync(join(SRC_DIR, "UserStoragePanel.vue"), "utf8");
  assert.doesNotMatch(storagePanel, /登记代次|历史账本/);
});

test("userFacingError maps newly aligned backend error codes to plain Chinese guidance", () => {
  for (const code of [
    "app_access_forbidden",
    "app_invalid",
    "app_unavailable",
    "app_already_exists",
    "app_template_not_found",
    "app_busy",
    "app_operation_failed",
    "automation_task_not_found",
    "automation_operation_failed",
    "invalid_strm_url",
    "forbidden_strm_url",
    "person_share_requires_owned_photos",
    "invalid_person_share",
    "admin_confirmation_required",
    "admin_confirmation_invalid",
    "tmdb_token_not_configured",
    "douban_web_unavailable",
    "transcode_insufficient_space",
    "transcode_busy",
    "transcode_failed",
  ]) {
    const message = describeUserFacingError(new Error(code));
    assert.doesNotMatch(
      message,
      /排查标识/,
      `expected explicit user-facing message for ${code}, got ${message}`,
    );
  }
});
