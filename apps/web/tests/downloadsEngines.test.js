import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { parse } from "@vue/compiler-sfc";
import { compile } from "@vue/compiler-dom";
import {
  buildDownloadCreatePayload,
  DOWNLOAD_ENGINE_MODES,
  downloadEngineLabel,
  formatVideoQualityLabel,
  isEngineRunnable,
  readDownloadCenter,
  resolveEngineAvailability,
  validateDownloadUrlForEngine,
  YTDLP_INSTALL_COMMAND,
} from "../src/features/downloads/downloadCenterTransport.ts";

test("resolveEngineAvailability & isEngineRunnable decouple aria2, yt-dlp, and webarchive cleanly", () => {
  const statusNoYtdlp = {
    available: true,
    networkAllowed: true,
    aria2Available: true,
    aria2Version: "1.37.0",
    ytdlpAvailable: false,
    ytdlpReason: "ytdlp_not_installed",
    webArchiveAvailable: true,
  };
  const avail = resolveEngineAvailability(statusNoYtdlp);
  assert.equal(avail.aria2, true);
  assert.equal(avail.aria2Version, "1.37.0");
  assert.equal(avail.ytdlp, false);
  assert.equal(avail.webarchive, true);
  assert.equal(avail.anyAvailable, true);

  assert.equal(isEngineRunnable("aria2", statusNoYtdlp), true);
  assert.equal(isEngineRunnable("ytdlp", statusNoYtdlp), false);
  assert.equal(isEngineRunnable("webarchive", statusNoYtdlp), true);

  // Even when aria2 is missing, webarchive stays usable
  const statusWebOnly = {
    available: false,
    networkAllowed: true,
    aria2Available: false,
    aria2Reason: "aria2_not_installed",
    ytdlpAvailable: false,
    webArchiveAvailable: true,
  };
  assert.equal(resolveEngineAvailability(statusWebOnly).anyAvailable, true);
  assert.equal(isEngineRunnable("aria2", statusWebOnly), false);
  assert.equal(isEngineRunnable("webarchive", statusWebOnly), true);

  // Non-admin network restriction blocks all engines from creating new jobs
  assert.equal(isEngineRunnable("webarchive", { ...statusWebOnly, networkAllowed: false }), false);
});

test("validateDownloadUrlForEngine enforces per-engine URL schemes", () => {
  assert.equal(validateDownloadUrlForEngine("aria2", "magnet:?xt=urn:btih:abc"), "");
  assert.equal(validateDownloadUrlForEngine("aria2", "ftp://example.com/a.iso"), "");
  assert.match(validateDownloadUrlForEngine("aria2", "file:///etc/passwd"), /仅支持/);

  assert.equal(validateDownloadUrlForEngine("ytdlp", "https://www.bilibili.com/video/BV1xx"), "");
  assert.match(validateDownloadUrlForEngine("ytdlp", "magnet:?xt=urn:btih:abc"), /http:\/\/ 或 https:\/\//);

  assert.equal(validateDownloadUrlForEngine("webarchive", "https://example.org/article"), "");
  assert.match(validateDownloadUrlForEngine("webarchive", "ftp://example.org/file"), /http:\/\/ 或 https:\/\//);
});

test("buildDownloadCreatePayload includes engine and bounded yt-dlp options", () => {
  const aria2Payload = buildDownloadCreatePayload({
    engine: "aria2",
    url: " https://example.com/a.zip ",
    destination: "Downloads",
    maxBytes: 1024,
  });
  assert.deepEqual(aria2Payload, {
    url: "https://example.com/a.zip",
    destination: "Downloads",
    maxBytes: 1024,
    engine: "aria2",
  });

  const webPayload = buildDownloadCreatePayload({
    engine: "webarchive",
    url: "https://example.com/post",
    destination: "",
    maxBytes: 0,
  });
  assert.deepEqual(webPayload, {
    url: "https://example.com/post",
    destination: ".",
    maxBytes: 0,
    engine: "webarchive",
  });

  const ytdlpPayload = buildDownloadCreatePayload({
    engine: "ytdlp",
    url: "https://example.com/watch?v=1",
    destination: "Videos",
    maxBytes: 0,
    format: "1080p",
    allowPlaylist: true,
    playlistMaxItems: 99,
  });
  assert.deepEqual(ytdlpPayload, {
    url: "https://example.com/watch?v=1",
    destination: "Videos",
    maxBytes: 0,
    engine: "ytdlp",
    options: {
      format: "1080p",
      allowPlaylist: true,
      playlistMaxItems: 20,
    },
  });

  assert.equal(downloadEngineLabel("aria2"), "常规/磁力");
  assert.equal(downloadEngineLabel("ytdlp"), "视频归档");
  assert.equal(downloadEngineLabel("webarchive"), "网页离线保存");
  assert.equal(formatVideoQualityLabel("audio"), "仅音频");
  assert.equal(YTDLP_INSTALL_COMMAND, "brew install yt-dlp");
  assert.equal(DOWNLOAD_ENGINE_MODES.length, 3);
});

test("readDownloadCenter preserves multi-engine status and task engine options", async () => {
  const result = await readDownloadCenter(async (path) => {
    if (path.endsWith("/status")) {
      return {
        available: true,
        aria2Available: true,
        ytdlpAvailable: true,
        ytdlpVersion: "2026.03.01",
        webArchiveAvailable: true,
      };
    }
    return {
      tasks: [
        {
          id: "dl-1",
          engine: "ytdlp",
          options: { format: "1080p", allowPlaylist: false },
          url: "https://example.com/v",
          destination: "Videos",
          status: "completed",
          totalBytes: 100,
          completedBytes: 100,
          maxBytes: 0,
          createdAt: 1000,
          updatedAt: 1001,
        },
      ],
    };
  });
  assert.equal(result.status.ytdlpAvailable, true);
  assert.equal(result.status.ytdlpVersion, "2026.03.01");
  assert.equal(result.status.webArchiveAvailable, true);
  assert.equal(result.tasks[0].engine, "ytdlp");
  assert.equal(result.tasks[0].options?.format, "1080p");
});

test("DownloadsView & DownloadEngineIntakeCard compile cleanly with 3-engine UI and brew install yt-dlp guide", () => {
  for (const rel of [
    "../src/features/downloads/DownloadsView.vue",
    "../src/features/downloads/DownloadEngineIntakeCard.vue",
  ]) {
    const src = readFileSync(new URL(rel, import.meta.url), "utf8");
    const lines = src.split("\n").length;
    assert.ok(lines < 800, `${rel} has ${lines} lines; must be < 800`);
    const parsed = parse(src, { filename: rel });
    assert.equal(parsed.errors.length, 0, `${rel} parse errors: ${parsed.errors.join("; ")}`);
    const compiled = compile(parsed.descriptor.template.content, { mode: "function" });
    assert.ok(compiled.code.length > 0);
    assert.doesNotMatch(src, /<select[\s>]/i);
    assert.doesNotMatch(src, /window\.(confirm|alert|prompt)\s*\(/);
    assert.doesNotMatch(src, /:deep\(/);
  }
  const intakeSrc = readFileSync(new URL("../src/features/downloads/DownloadEngineIntakeCard.vue", import.meta.url), "utf8");
  assert.match(intakeSrc, /YTDLP_INSTALL_COMMAND/);
  assert.match(intakeSrc, /AppleSelect/);
  assert.match(intakeSrc, /允许抓取播放列表/);
  assert.doesNotMatch(intakeSrc, /color-mix\([^)]*--fluid-card-item-fill/);
  assert.match(intakeSrc, /@blur="normalizePlaylistMaxItems"/);

  const downloadsSrc = readFileSync(new URL("../src/features/downloads/DownloadsView.vue", import.meta.url), "utf8");
  assert.doesNotMatch(downloadsSrc, /--brand-cyan/);
  assert.match(downloadsSrc, /requestDefaultRootFiles\("\/api\/v2\/files\?"/);
});
