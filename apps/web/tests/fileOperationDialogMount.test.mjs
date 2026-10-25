import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

async function readTemplate() {
  const source = await readFile(new URL("../src/App.vue", import.meta.url), "utf8");
  const start = source.indexOf("<template>");
  const end = source.lastIndexOf("</template>");
  assert.ok(start >= 0 && end > start, "App.vue template block not found");
  return source.slice(start, end);
}

test("the move/copy dialog renders inside the logged-in shell, not the auth splash", async () => {
  const template = await readTemplate();

  const authBranch = template.indexOf('v-if="authChecking"');
  const nextBranch = template.indexOf('v-else-if="authServiceError"');
  assert.ok(authBranch >= 0 && nextBranch > authBranch, "auth branch markers not found");
  const dialog = template.indexOf("<FileOperationDialog");
  assert.ok(dialog >= 0, "FileOperationDialog has no render point");
  assert.ok(
    dialog < authBranch || dialog > nextBranch,
    "FileOperationDialog must not live in the authChecking splash branch: it only renders while authChecking is true, so the move/copy button would silently do nothing after login",
  );
});

test("the move/copy dialog renders alongside the other shell dialogs", async () => {
  const template = await readTemplate();

  const shell = template.indexOf('v-else class="shell"');
  const dialog = template.indexOf("<FileOperationDialog");
  const mobileNav = template.indexOf('class="mobile-nav');
  assert.ok(shell >= 0, "shell branch not found");
  assert.ok(mobileNav > shell, "mobile nav marker not found after shell");
  assert.ok(
    dialog > shell && dialog < mobileNav,
    "FileOperationDialog should be mounted in the shell dialog area (with trashTarget/previewItem/sharingFile), inside the logged-in branch",
  );
});
