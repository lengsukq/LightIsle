import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import {
  diskUsageSegments,
  formatDiskSize,
  isSystemDiskPartition,
  isSystemVolume,
} from "../src/diskManagementSupport.ts";

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

function loadCssRecursive(entryPath, seen = new Set()) {
  const abs = resolve(entryPath);
  if (seen.has(abs) || !existsSync(abs)) return "";
  seen.add(abs);
  const raw = readFileSync(abs, "utf8");
  let combined = "";
  for (const match of raw.matchAll(/@import\s+(?:url\()?["']([^"']+)["']\)?\s*;/g)) {
    const target = resolve(dirname(abs), match[1]);
    combined += "\n" + loadCssRecursive(target, seen);
  }
  return combined + "\n" + raw;
}

function collectMainGlobalCss() {
  const mainTs = readFileSync(join(SRC_DIR, "main.ts"), "utf8");
  const seen = new Set();
  let css = "";
  for (const match of mainTs.matchAll(/import\s+["'](\.[^"']+\.css)["']/g)) {
    css += "\n" + loadCssRecursive(resolve(SRC_DIR, match[1]), seen);
  }
  return css;
}

function extractCssClassSelectors(css) {
  const classes = new Set();
  const stripped = css.replace(/\/\*[\s\S]*?\*\//g, "");
  for (const match of stripped.matchAll(/\.([A-Za-z_-][A-Za-z0-9_-]*)/g)) {
    classes.add(match[1]);
  }
  return classes;
}

function extractVueStyleBlocks(vueContent, vuePath) {
  let localCss = "";
  let globalCss = "";
  for (const match of vueContent.matchAll(/<style(\b[^>]*)>([\s\S]*?)<\/style>/gi)) {
    const attrs = match[1] ?? "";
    const srcMatch = attrs.match(/\bsrc=["']([^"']+)["']/i);
    let body = match[2] ?? "";
    if (srcMatch) {
      body += "\n" + loadCssRecursive(resolve(dirname(vuePath), srcMatch[1]));
    }
    if (/\bscoped\b/i.test(attrs)) {
      localCss += "\n" + body;
    } else {
      globalCss += "\n" + body;
    }
  }
  return { localCss, globalCss };
}

function extractTemplateStaticClasses(markup) {
  const names = new Set();
  const templateMatch = markup.match(/<template>([\s\S]*)<\/template>/i);
  const body = templateMatch ? templateMatch[1] : markup;
  for (const match of body.matchAll(/(?:^|[\s<])class=["']([^"']+)["']/g)) {
    for (const token of match[1].trim().split(/\s+/)) {
      if (token && !token.includes("{")) {
        names.add(token);
      }
    }
  }
  return names;
}

test("standalone CSS files contain no Vue :deep() and SFCs never share CSS via <style scoped src>", () => {
  const files = walk(SRC_DIR);
  for (const file of files) {
    const content = readFileSync(file, "utf8");
    if (file.endsWith(".css")) {
      assert.doesNotMatch(
        content,
        /:deep\(|::v-deep/,
        `${file} is plain CSS and must not contain Vue :deep() selectors`,
      );
    }
    if (file.endsWith(".vue")) {
      assert.doesNotMatch(
        content,
        /<style[^>]*\bscoped\b[^>]*\bsrc=/i,
        `${file} must not use <style scoped src="...">; import shared module CSS in main.ts`,
      );
      assert.doesNotMatch(
        content,
        /<style[^>]*\bsrc=[^>]*\bscoped\b/i,
        `${file} must not use <style scoped src="...">; import shared module CSS in main.ts`,
      );
    }
  }
});

test("split components and module stylesheets resolve all critical layout/action class selectors", () => {
  const globalCss = collectMainGlobalCss();
  const vueFiles = walk(SRC_DIR).filter((file) => file.endsWith(".vue"));
  let allCss = globalCss;
  const vueStyleByPath = new Map();

  for (const file of vueFiles) {
    const content = readFileSync(file, "utf8");
    const { localCss, globalCss: extraGlobal } = extractVueStyleBlocks(content, file);
    allCss += "\n" + extraGlobal;
    vueStyleByPath.set(file, extractCssClassSelectors(localCss));
  }

  const globalClasses = extractCssClassSelectors(allCss);

  // Critical module class prefixes whose styling must never silently disappear after SFC splits
  const checkedPrefixes = [
    "cinema-",
    "photo-",
    "photos-",
    "gallery-load",
    "cache-",
    "disk-",
    "apps-center",
    "apps-card",
    "apps-storage",
  ];
  const ignoredSemanticHooks = new Set([
    // Optional structural / transition hooks without required direct rules
    "cinema-home-shelves",
    "cinema-detail-panels",
    "cinema-row-title",
  ]);

  const missing = [];
  const targets = [...vueFiles, join(SRC_DIR, "AppShell.html")];

  for (const file of targets) {
    if (!existsSync(file)) continue;
    const content = readFileSync(file, "utf8");
    const used = extractTemplateStaticClasses(content);
    const localClasses = vueStyleByPath.get(file) ?? new Set();

    for (const cls of used) {
      if (!checkedPrefixes.some((prefix) => cls.startsWith(prefix))) continue;
      if (ignoredSemanticHooks.has(cls)) continue;
      if (!globalClasses.has(cls) && !localClasses.has(cls)) {
        missing.push(`${file.replace(SRC_DIR, "")}: .${cls}`);
      }
    }
  }

  assert.deepEqual(
    missing,
    [],
    `Unstyled domain CSS classes detected:\n${missing.join("\n")}`,
  );
});

test("diskManagementSupport formats TB cleanly and identifies EFI/Disk Image system partitions", () => {
  assert.equal(formatDiskSize(0), "0 B");
  assert.equal(formatDiskSize(512 * 1024 ** 2), "512.0 MB");
  assert.equal(formatDiskSize(250 * 1024 ** 3), "250.0 GB");
  assert.equal(formatDiskSize(11360.1 * 1024 ** 3), "11.09 TB");

  assert.equal(
    isSystemDiskPartition({
      id: "disk0s1",
      name: "EFI",
      parent: "disk0",
      mount: "",
      filesystem: "FAT32",
      protocol: "Apple Fabric",
      smart: "",
      total: 524 * 1024 ** 2,
      free: 0,
      readOnly: false,
      mounted: false,
      external: false,
      identity: "",
    }),
    true,
  );

  assert.equal(
    isSystemDiskPartition({
      id: "disk5s1",
      name: "LightIsle DMG",
      parent: "disk5",
      mount: "/Volumes/LightIsle",
      filesystem: "APFS",
      protocol: "Disk Image",
      smart: "",
      total: 2 * 1024 ** 3,
      free: 1024 ** 3,
      readOnly: true,
      mounted: true,
      external: false,
      identity: "",
    }),
    true,
  );

  assert.equal(
    isSystemDiskPartition({
      id: "disk4s1",
      name: "FamilyNAS",
      parent: "disk4",
      mount: "/Volumes/FamilyNAS",
      filesystem: "APFS",
      protocol: "USB",
      smart: "Verified",
      total: 4 * 1024 ** 4,
      free: 2 * 1024 ** 4,
      readOnly: false,
      mounted: true,
      external: true,
      identity: "a".repeat(64),
    }),
    false,
  );

  const segments = diskUsageSegments(1000, 250);
  assert.equal(segments[0].value, 750);
  assert.equal(segments[1].value, 250);

  assert.equal(
    isSystemVolume({
      name: "Recovery",
      mount: "/Volumes/Recovery",
      device: "disk3s3",
      filesystem: "APFS",
      total: 1024 ** 4,
      free: 512 * 1024 ** 3,
      readOnly: true,
    }),
    true,
  );
  assert.equal(
    isSystemVolume({
      name: "Update",
      mount: "/System/Volumes/Update",
      device: "disk3s2",
      filesystem: "APFS",
      total: 1024 ** 4,
      free: 512 * 1024 ** 3,
      readOnly: false,
    }),
    true,
  );
  assert.equal(
    isSystemVolume({
      name: "Gemini 2",
      mount: "/Volumes/Gemini 2",
      device: "disk6s1",
      filesystem: "APFS",
      total: 1024 ** 3,
      free: 0,
      readOnly: true,
    }),
    true,
  );
  assert.equal(
    isSystemVolume({
      name: "Macintosh HD",
      mount: "/",
      device: "disk3s1s1",
      filesystem: "APFS",
      total: 1024 ** 4,
      free: 512 * 1024 ** 3,
      readOnly: true,
    }),
    false,
  );
  assert.equal(
    isSystemVolume({
      name: "FamilyNAS",
      mount: "/Volumes/FamilyNAS",
      device: "disk4s1",
      filesystem: "APFS",
      total: 4 * 1024 ** 4,
      free: 2 * 1024 ** 4,
      readOnly: false,
    }),
    false,
  );
});
