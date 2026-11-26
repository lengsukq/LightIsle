import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { parse } from "@vue/compiler-sfc";
import {
  buildCollectPublicUrl,
  parseAllowedExtensions,
  useCollectLinks,
  validateCollectLinkDraft,
} from "../src/features/files/fileCollectLinksApi.ts";
import {
  buildInsightsQueryParams,
  pinDisplayLabel,
  useFileInsights,
  useFilePins,
} from "../src/features/files/filePinsAndInsights.ts";

test("parseAllowedExtensions normalizes tokens and flags invalid extensions", () => {
  const { exts, invalid } = parseAllowedExtensions("jpg, .PNG; heic  .mp4  .jpg  ../bad");
  assert.deepEqual(exts, [".jpg", ".png", ".heic", ".mp4"]);
  assert.deepEqual(invalid, ["../bad"]);
});

test("validateCollectLinkDraft enforces folder path, hours 1..720, password bytes and quota hierarchy", () => {
  const base = {
    path: "Family/Photos",
    hours: 72,
    title: "春节照片收集",
    password: "",
    maxFiles: 50,
    maxFileBytes: 100 * 1024 * 1024,
    maxTotalBytes: 1024 * 1024 * 1024,
    allowedExtsText: ".jpg, .png",
  };
  assert.equal(validateCollectLinkDraft(base), null);
  assert.match(validateCollectLinkDraft({ ...base, path: "." }) ?? "", /子文件夹/);
  assert.match(validateCollectLinkDraft({ ...base, hours: 721 }) ?? "", /720/);
  assert.match(validateCollectLinkDraft({ ...base, password: "123" }) ?? "", /口令/);
  assert.match(
    validateCollectLinkDraft({ ...base, maxFileBytes: 2 * 1024 ** 3, maxTotalBytes: 1024 ** 3 }) ?? "",
    /单文件上限/,
  );
});

test("useCollectLinks creates, lists, revokes and discards stale root responses", async () => {
  const state = { root: "root-a", authed: true };
  const calls = { post: [], del: [], list: 0 };
  let pendingCreate;

  const collect = useCollectLinks({
    canList: () => state.authed,
    context: () => state.root,
    apiPath: (p) => `/api/v2/roots/${state.root}${p.slice("/api/v2".length)}`,
    mediaPath: (p) => `/api/v2/roots/${state.root}${p.slice("/api/v2".length)}`,
    read: async () => {
      calls.list += 1;
      return {
        links: [
          {
            id: "col-1",
            rootId: state.root,
            rootGeneration: 1,
            targetPath: "Family/Drop",
            title: "亲友投递",
            hasPassword: false,
            maxFiles: 20,
            maxFileBytes: 0,
            maxTotalBytes: 0,
            uploadedFiles: 3,
            uploadedBytes: 1024 * 1024,
            createdAt: 1700000000,
            expiresAt: 1700086400,
          },
        ],
      };
    },
    write: async (path, body) => {
      calls.post.push({ path, body });
      if (pendingCreate) return pendingCreate;
      return {
        link: {
          id: "col-1",
          rootId: state.root,
          rootGeneration: 1,
          targetPath: "Family/Drop",
          title: "亲友投递",
          hasPassword: false,
          maxFiles: 20,
          maxFileBytes: 0,
          maxTotalBytes: 0,
          uploadedFiles: 0,
          uploadedBytes: 0,
          createdAt: 1700000000,
          expiresAt: 1700086400,
        },
        token: "tok-secret",
        publicPath: `/api/v2/roots/${state.root}/public/collect/tok-secret`,
      };
    },
    remove: async (path) => { calls.del.push(path); },
    confirm: () => true,
    origin: () => "https://nas.local",
  });

  const ok = await collect.createCollectLink({
    path: "Family/Drop",
    hours: 24,
    title: "亲友投递",
    password: "",
    maxFiles: 20,
    maxFileBytes: 0,
    maxTotalBytes: 0,
    allowedExtsText: "jpg png",
  });
  assert.equal(ok, true);
  assert.equal(calls.post[0].path, "/api/v2/roots/root-a/collect-links");
  assert.deepEqual(calls.post[0].body.allowedExts, [".jpg", ".png"]);
  assert.equal(collect.createdUrl.value, "https://nas.local/api/v2/roots/root-a/public/collect/tok-secret");
  assert.equal(collect.collectLinks.value.length, 1);

  await collect.revokeCollectLink(collect.collectLinks.value[0]);
  assert.deepEqual(calls.del, ["/api/v2/roots/root-a/collect-links/col-1"]);
  assert.equal(collect.createdUrl.value, "");

  // Stale response after root switch must be discarded
  let finish;
  pendingCreate = new Promise((resolve) => { finish = resolve; });
  const inFlight = collect.createCollectLink({
    path: "Family/Drop",
    hours: 24,
    title: "旧盘",
    password: "",
    maxFiles: 0,
    maxFileBytes: 0,
    maxTotalBytes: 0,
    allowedExtsText: "",
  });
  state.root = "root-b";
  collect.reset();
  finish({ link: { id: "stale" }, token: "stale-tok", publicPath: "/api/v2/roots/root-a/public/collect/stale-tok" });
  await inFlight;
  assert.equal(collect.createdUrl.value, "");
  assert.equal(buildCollectPublicUrl("https://nas.local/", "", "/api/v2/roots/r/public/collect", "abc"), "https://nas.local/api/v2/roots/r/public/collect/abc");
});

test("useFilePins manages pins, toggling, missing pins and root isolation", async () => {
  const state = { root: "disk-1", authed: true };
  const removed = [];
  const pins = useFilePins({
    canList: () => state.authed,
    context: () => state.root,
    apiPath: (p) => `/api/v2/roots/${state.root}${p.slice("/api/v2".length)}`,
    read: async () => ({
      pins: [
        { rootId: "disk-1", rootGeneration: 1, path: "Work", kind: "folder", label: "工作资料", pinnedAt: 1, exists: true, canWrite: true },
        { rootId: "disk-1", rootGeneration: 1, path: "Gone.md", kind: "file", label: "", pinnedAt: 2, exists: false, canWrite: false },
      ],
    }),
    write: async (_path, body) => ({
      pin: { rootId: "disk-1", rootGeneration: 1, path: body.path, kind: "folder", label: body.label || "", pinnedAt: 3, exists: true, canWrite: true },
    }),
    remove: async (path) => { removed.push(path); },
  });

  await pins.loadPins();
  assert.equal(pins.pins.value.length, 2);
  assert.equal(pins.isPinned("Work"), true);
  assert.equal(pinDisplayLabel(pins.pins.value[1]), "Gone.md");

  await pins.togglePin({ path: "Photos", name: "相册" });
  assert.equal(pins.isPinned("Photos"), true);

  await pins.removePin("Gone.md");
  assert.equal(pins.isPinned("Gone.md"), false);
  assert.deepEqual(removed, ["/api/v2/roots/disk-1/files/pins?path=Gone.md"]);
});

test("useFileInsights builds query params and updates stats safely on trash", async () => {
  assert.equal(
    buildInsightsQueryParams({ mode: "large", path: "Movies", minBytes: 52428800, limit: 50 }),
    "mode=large&path=Movies&minBytes=52428800&limit=50",
  );
  assert.equal(
    buildInsightsQueryParams({ mode: "recent", path: ".", days: 7, limit: 100 }),
    "mode=recent&path=.&days=7&limit=100",
  );

  const trashed = [];
  let refreshed = 0;
  const insights = useFileInsights({
    canList: () => true,
    context: () => "disk-1",
    apiPath: (p) => `/api/v2/roots/disk-1${p.slice("/api/v2".length)}`,
    read: async () => ({
      mode: "large",
      minBytes: 52428800,
      scannedFiles: 120,
      matchedFiles: 2,
      totalBytes: 300 * 1024 * 1024,
      truncated: false,
      items: [
        { name: "movie.mkv", path: "Media/movie.mkv", parentDir: "Media", size: 200 * 1024 * 1024, modified: "2026-11-26T00:00:00Z", modifiedAt: 1700000000, canWrite: true },
        { name: "readonly.iso", path: "ISO/readonly.iso", parentDir: "ISO", size: 100 * 1024 * 1024, modified: "2026-11-26T00:00:00Z", modifiedAt: 1700000000, canWrite: false },
      ],
    }),
    trashFile: async (p) => { trashed.push(p); },
    confirm: () => true,
    onFileTrashed: () => { refreshed += 1; },
  });

  await insights.loadInsights({ mode: "large" });
  assert.equal(insights.result.value?.items.length, 2);

  // Read-only item cannot be trashed
  assert.equal(await insights.trashInsightItem(insights.result.value.items[1]), false);
  assert.equal(trashed.length, 0);

  // Writable item is trashed after confirmation and decrements totalBytes
  assert.equal(await insights.trashInsightItem(insights.result.value.items[0]), true);
  assert.deepEqual(trashed, ["Media/movie.mkv"]);
  assert.equal(insights.result.value?.items.length, 1);
  assert.equal(insights.result.value?.totalBytes, 100 * 1024 * 1024);
  assert.equal(refreshed, 1);
});

test("CollectLinkModal, FilePinsBar, FileInsightsModal and FileShareModal parse cleanly and follow UI guardrails", () => {
  for (const name of ["CollectLinkModal.vue", "FilePinsBar.vue", "FileInsightsModal.vue", "FileShareModal.vue"]) {
    const src = readFileSync(new URL(`../src/features/files/${name}`, import.meta.url), "utf8");
    const parsed = parse(src, { filename: name });
    assert.deepEqual(parsed.errors, [], `${name} should parse cleanly`);
    assert.doesNotMatch(src, /<select[\s>]/i, `${name} must use AppleSelect instead of native <select>`);
    assert.doesNotMatch(src, /window\.confirm\(/, `${name} must use requestConfirm`);
    assert.doesNotMatch(src, /:deep\(/, `${name} must not use :deep()`);
    assert.doesNotMatch(src, /color-mix\([^)]*--fluid-card-item-fill/, `${name} must not pass gradient token into color-mix()`);
  }

  // Fallback collect URL must use apiPath (no ?rootGen= query param that breaks path concatenation)
  const collectApiSrc = readFileSync(new URL("../src/features/files/fileCollectLinksApi.ts", import.meta.url), "utf8");
  assert.match(collectApiSrc, /deps\.apiPath\("\/api\/v2\/public\/collect"\)/);
});
