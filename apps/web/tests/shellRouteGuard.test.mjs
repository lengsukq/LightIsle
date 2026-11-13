import test from "node:test";
import assert from "node:assert/strict";
import { resolvePermittedPage, resolvePermittedSettingsGroup } from "../src/shellRouteGuard.ts";

test("resolvePermittedPage blocks automation for members and clamps computer access once resolved", () => {
  assert.equal(
    resolvePermittedPage("automation", {
      isAdmin: false,
      computerFilesAllowed: true,
      computerFilesResolved: true,
    }),
    "overview",
  );
  assert.equal(
    resolvePermittedPage("automation", {
      isAdmin: true,
      computerFilesAllowed: false,
      computerFilesResolved: true,
    }),
    "automation",
  );

  // Do not boot members off ?page=computer before status loads, but clamp once known disallowed.
  assert.equal(
    resolvePermittedPage("computer", {
      isAdmin: false,
      computerFilesAllowed: false,
      computerFilesResolved: false,
    }),
    "computer",
  );
  assert.equal(
    resolvePermittedPage("computer", {
      isAdmin: false,
      computerFilesAllowed: false,
      computerFilesResolved: true,
    }),
    "overview",
  );
  assert.equal(
    resolvePermittedPage("computer", {
      isAdmin: false,
      computerFilesAllowed: true,
      computerFilesResolved: true,
    }),
    "computer",
  );
});

test("resolvePermittedSettingsGroup restricts admin-only groups for ordinary members", () => {
  assert.equal(resolvePermittedSettingsGroup("storage", false), "account");
  assert.equal(resolvePermittedSettingsGroup("ops", false), "account");
  assert.equal(resolvePermittedSettingsGroup("files", false), "files");
  assert.equal(resolvePermittedSettingsGroup("cache", false), "cache");
  assert.equal(resolvePermittedSettingsGroup("storage", true), "storage");
  assert.equal(resolvePermittedSettingsGroup("ops", true), "ops");
});
