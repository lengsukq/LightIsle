import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";

async function readTemplate(rel = "../src/AppShell.html") {
  return readFile(new URL(rel, import.meta.url), "utf8");
}

test("the move/copy dialog renders inside the logged-in shell, not the auth splash", async () => {
  const [template, authScene] = await Promise.all([
    readTemplate(),
    readTemplate("../src/AuthScene.vue"),
  ]);

  const authBranch = authScene.indexOf('v-if="authChecking"');
  const nextBranch = authScene.indexOf('v-else-if="authServiceError"');
  assert.ok(authBranch >= 0 && nextBranch > authBranch, "auth branch markers not found");
  assert.equal(authScene.indexOf("<FileOperationDialog"), -1, "FileOperationDialog must not live in AuthScene");

  const authHost = template.indexOf("<AuthScene");
  const shell = template.indexOf('v-else class="shell"');
  const dialog = template.indexOf("<FileOperationDialog");
  assert.ok(authHost >= 0 && shell > authHost, "AuthScene must precede logged-in shell");
  assert.ok(dialog > shell, "FileOperationDialog must render inside the logged-in shell");
});

test("the move/copy dialog renders alongside the other shell dialogs", async () => {
  const [template, mobileDrawer] = await Promise.all([
    readTemplate(),
    readTemplate("../src/MobileNavDrawer.vue"),
  ]);

  const shell = template.indexOf('v-else class="shell"');
  const dialog = template.indexOf("<FileOperationDialog");
  const mobileNavHost = template.indexOf("<MobileNavDrawer");
  assert.ok(shell >= 0, "shell branch not found");
  assert.ok(mobileDrawer.includes('class="mobile-nav'), "mobile nav marker missing in MobileNavDrawer");
  assert.ok(mobileNavHost > shell, "MobileNavDrawer marker not found after shell");
  assert.ok(
    dialog > shell && dialog < mobileNavHost,
    "FileOperationDialog should be mounted in the shell dialog area (with trashTarget/previewItem/sharingFile), inside the logged-in branch",
  );
});
