import assert from "node:assert/strict";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import {
  describeUserFacingError,
  splitUserFacingErrorText,
} from "../src/api/userFacingError.ts";

const SRC_DIR = new URL("../src/", import.meta.url).pathname;

function walk(dir) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) out.push(...walk(full));
    else out.push(full);
  }
  return out;
}

test("userFacingError maps newly synced Go/Flutter error codes and removes dead codes", () => {
  const codes = [
    "transcode_unavailable",
    "album_name_exists",
    "private_album_limit",
    "invalid_album_name",
    "invalid_or_duplicate_album",
    "tmdb_auth_failed",
    "tmdb_access_denied",
    "tmdb_upstream_failed",
    "invalid_tmdb_request",
    "current_password_invalid",
    "invalid_new_password",
    "password_change_failed",
    "password_reset_failed",
    "username_exists",
    "too_many_attempts",
    "session_not_found",
    "download_unavailable",
    "download_publish_recovery_required",
    "upload_too_large",
    "upload_busy",
    "offset_mismatch",
    "browser_playback_unsupported",
    "film_not_found",
    "series_not_found",
    "nfo_not_found",
  ];
  for (const code of codes) {
    const msg = describeUserFacingError(new Error(code));
    assert.doesNotMatch(msg, /排查标识/, `expected friendly mapping for ${code}, got ${msg}`);
  }

  for (const deadCode of ["apps_unavailable", "storage_quota_is_per_disk_upgrade_client"]) {
    const msg = describeUserFacingError(new Error(deadCode));
    assert.match(msg, /排查标识/, `dead code ${deadCode} should no longer be hardcoded`);
  }
});

test("splitUserFacingErrorText separates technical HTTP/incident suffixes for collapsed UI details", () => {
  const split = splitUserFacingErrorText(
    "目录暂时离线，请重新连接硬盘。（HTTP 503 · share_root_offline）（故障编号 li-abc123）",
  );
  assert.equal(split.message, "目录暂时离线，请重新连接硬盘。");
  assert.match(split.technicalDetail, /HTTP 503 · share_root_offline/);
  assert.match(split.technicalDetail, /故障编号 li-abc123/);

  const plain = splitUserFacingErrorText("请检查网络连接后重试。");
  assert.equal(plain.message, "请检查网络连接后重试。");
  assert.equal(plain.technicalDetail, null);
});

test("apps/web/src routes all HTTP traffic through apiClient without raw fetch() calls", () => {
  const files = walk(SRC_DIR).filter(
    (f) => /\.(ts|vue)$/.test(f) && !/\.test\.[cm]?[jt]s$/.test(f) && !f.endsWith("/apiClient.ts"),
  );
  for (const file of files) {
    const content = readFileSync(file, "utf8");
    assert.doesNotMatch(
      content,
      /(?<![.\w])fetch\s*\(/,
      `${file} must use apiFetch/apiRequest instead of raw fetch()`,
    );
  }
});

test("Wave 1 P0 & Phase 2 UX invariants hold across FileOperationDialog, UserStorage, Cinema, Photos, and AppShell", () => {
  const fileOp = readFileSync(join(SRC_DIR, "features/files/FileOperationDialog.vue"), "utf8");
  assert.match(fileOp, /const initialDir = parentDirectoryOfPath\(props\.item\.path\)/);
  assert.match(fileOp, /const dir = ref\(initialDir\)/);
  assert.match(fileOp, /action: "rename" \| "copy" \| "move"/);

  const storageLogic = readFileSync(join(SRC_DIR, "features/storage/useUserStoragePanel.ts"), "utf8");
  assert.match(storageLogic, /async function abandonRemovedRoot[\s\S]*?requestConfirm\(/);
  const storagePanel = readFileSync(join(SRC_DIR, "features/storage/UserStoragePanel.vue"), "utf8");
  assert.doesNotMatch(storagePanel, /<DuplicateFilesPanel/);

  const shellHtml = readFileSync(join(SRC_DIR, "AppShell.html"), "utf8");
  const filesView = readFileSync(join(SRC_DIR, "features/files/FilesView.vue"), "utf8");
  const settingsView = readFileSync(join(SRC_DIR, "features/settings/SettingsView.vue"), "utf8");
  assert.match(shellHtml, /v-if="multiRootMode && user\.role === 'admin'" class="root-context-control topbar-root-control"/);
  assert.doesNotMatch(shellHtml, /style="/);
  assert.doesNotMatch(shellHtml, /brand-version-badge|宿主状态|computerGrantUser/);
  assert.equal((settingsView.match(/<UploadMaintenance/g) ?? []).length, 1);
  assert.doesNotMatch(settingsView, /computerGrantUser/);
  assert.match(settingsView, /<AuditLogView :accounts="accounts"/);
  assert.match(filesView, /空间整理/);

  const opsCenter = readFileSync(join(SRC_DIR, "features/settings/OpsTaskCenter.vue"), "utf8");
  assert.doesNotMatch(opsCenter, /<UploadMaintenance/);

  const photosView = readFileSync(join(SRC_DIR, "features/photos/PhotosView.vue"), "utf8");
  assert.match(photosView, /if \(props\.active !== false\)/);
  const cinemaView = readFileSync(join(SRC_DIR, "features/cinema/CinemaView.vue"), "utf8");
  assert.match(cinemaView, /if \(props\.active !== false\)/);
});
