import assert from "node:assert/strict";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import test from "node:test";
import { computed, ref } from "vue";
import { formatDateTime, formatShortDate } from "../src/dateTimeFormat.ts";
import { useCinemaDockDrag } from "../src/useCinemaDockDrag.ts";
import { usePhotoTimelineScrubber } from "../src/usePhotoTimelineScrubber.ts";

const SRC_ROOT = new URL("../src/", import.meta.url).pathname;

function listFiles(dir) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) {
      out.push(...listFiles(full));
    } else {
      out.push(full);
    }
  }
  return out.sort();
}

function readSrc(rel) {
  return readFileSync(join(SRC_ROOT, rel), "utf8");
}

function withMockWindow(fn) {
  const prevWindow = globalThis.window;
  const listeners = new Map();
  let nextRaf = 1;
  const rafQueue = new Map();
  const canceled = [];

  globalThis.window = {
    addEventListener(type, handler, options) {
      listeners.set(type, { handler, options });
    },
    removeEventListener(type, handler) {
      const existing = listeners.get(type);
      if (existing && existing.handler === handler) listeners.delete(type);
    },
    requestAnimationFrame(cb) {
      const id = nextRaf++;
      rafQueue.set(id, cb);
      return id;
    },
    cancelAnimationFrame(id) {
      canceled.push(id);
      rafQueue.delete(id);
    },
    scrollTo() {},
  };

  try {
    return fn({
      listeners,
      rafQueue,
      canceled,
      flushRaf() {
        const callbacks = [...rafQueue.values()];
        rafQueue.clear();
        for (const cb of callbacks) cb(16);
      },
    });
  } finally {
    globalThis.window = prevWindow;
  }
}

test("dateTimeFormat formats valid dates, handles invalid inputs, and bounds its cache", () => {
  assert.equal(formatDateTime(""), "");
  assert.equal(formatDateTime(undefined), "");
  assert.equal(formatDateTime("not-a-date"), "");
  assert.equal(formatShortDate(undefined), "");
  assert.equal(formatShortDate(null), "");
  assert.equal(formatShortDate(0), "");
  assert.equal(formatShortDate(-10), "");
  assert.equal(formatShortDate(Number.NaN), "");

  const iso = "2026-05-01T08:30:45.000Z";
  const first = formatDateTime(iso);
  const second = formatDateTime(iso);
  assert.ok(first.length > 0);
  assert.equal(first, second);
  assert.equal(formatDateTime(Date.parse(iso)), first);

  const shortA = formatShortDate(1777624245.9);
  const shortB = formatShortDate(1777624245);
  assert.ok(shortA.length > 0);
  assert.equal(shortA, shortB);

  // Exceed the 512-entry cache ceiling to verify FIFO eviction stays healthy.
  for (let i = 0; i < 600; i++) {
    const out = formatDateTime(1700000000000 + i * 1000);
    assert.ok(out.length > 0);
  }
});

test("useCinemaDockDrag marks pointermove passive, caches bounds on pointerdown, coalesces rAF, and flushes final drop", () => {
  withMockWindow(({ listeners, rafQueue, canceled, flushRaf }) => {
    const drag = useCinemaDockDrag();
    let stageRectReads = 0;
    let dockRectReads = 0;

    const stageEl = {
      getBoundingClientRect() {
        stageRectReads += 1;
        return { width: 1200, height: 800 };
      },
    };
    const dockEl = {
      captured: null,
      setPointerCapture(id) { this.captured = id; },
      releasePointerCapture() { this.captured = null; },
      getBoundingClientRect() {
        dockRectReads += 1;
        return { width: 600, height: 100 };
      },
    };

    const started = drag.startDockDrag({ button: 0, pointerId: 7, clientX: 500, clientY: 500, target: null }, stageEl, dockEl);
    assert.equal(started, true);
    assert.equal(stageRectReads, 1);
    assert.equal(dockRectReads, 1);

    const moveReg = listeners.get("pointermove");
    assert.ok(moveReg);
    assert.equal(moveReg.options?.passive, true);

    // 4 rapid moves before vsync queue only 1 rAF and do not re-measure layout rects.
    moveReg.handler({ pointerId: 7, clientX: 510, clientY: 490 });
    moveReg.handler({ pointerId: 7, clientX: 525, clientY: 480 });
    moveReg.handler({ pointerId: 7, clientX: 540, clientY: 460 });
    assert.equal(rafQueue.size, 1);
    assert.deepEqual(drag.dockOffset.value, { x: 0, y: 0 });

    flushRaf();
    assert.deepEqual(drag.dockOffset.value, { x: 40, y: -40 });
    assert.equal(stageRectReads, 1);
    assert.equal(dockRectReads, 1);

    // Final move before pointerup must cancel queued rAF and flush final clamped position.
    moveReg.handler({ pointerId: 7, clientX: 600, clientY: 420 });
    assert.equal(rafQueue.size, 1);
    const upReg = listeners.get("pointerup");
    upReg.handler({ pointerId: 7 });
    assert.equal(canceled.length, 1);
    assert.deepEqual(drag.dockOffset.value, { x: 100, y: -80 });
    assert.equal(drag.draggingDock.value, false);
  });
});

test("usePhotoTimelineScrubber caches rail rect per scrub and cancels pending rAF cleanly", () => {
  withMockWindow(({ rafQueue, canceled, flushRaf }) => {
    const assets = ref([
      { id: 1, name: "a.jpg", path: "a.jpg", takenAt: 1704067200 },
      { id: 2, name: "b.jpg", path: "b.jpg", takenAt: 1706745600 },
      { id: 3, name: "c.jpg", path: "c.jpg", takenAt: 1709251200 },
    ]);
    const scrubber = usePhotoTimelineScrubber({
      assets,
      nextCursor: ref(0),
      loading: ref(false),
      loadError: ref(""),
      galleryLoaded: ref(true),
      focusedIndex: ref(0),
      gridElement: ref(null),
      scrubberInView: ref(true),
      timelineLayout: computed(() => ({ groups: [] })),
      virtualWindow: computed(() => ({ startIndex: 0, endIndex: 3, headers: [] })),
      isFullTimelineView: () => true,
      beginListRequest: () => ({ signal: new AbortController().signal, isCurrent: () => true }),
      getRootEpoch: () => 0,
      isDisposed: () => false,
      api: async () => ({ months: [] }),
      apiPath: (p) => p,
      load: async () => {},
      updateViewport: () => {},
      measureViewport: () => {},
    });

    let railRectReads = 0;
    let pointerCaptured = false;
    const railEl = {
      getBoundingClientRect() {
        railRectReads += 1;
        return { top: 100, height: 300 };
      },
      setPointerCapture() { pointerCaptured = true; },
      hasPointerCapture() { return pointerCaptured; },
      releasePointerCapture() { pointerCaptured = false; },
    };

    scrubber.startScrub({
      button: 0,
      pointerId: 3,
      clientY: 110,
      currentTarget: railEl,
      preventDefault() {},
    });
    assert.equal(railRectReads, 1);
    assert.equal(scrubber.scrubbing.value, true);
    assert.equal(scrubber.scrubPreview.value, 0);

    scrubber.moveScrub({ pointerId: 3, clientY: 250, currentTarget: railEl });
    scrubber.moveScrub({ pointerId: 3, clientY: 390, currentTarget: railEl });
    assert.equal(rafQueue.size, 1);

    flushRaf();
    assert.equal(scrubber.scrubPreview.value, 2);
    assert.equal(railRectReads, 1);

    scrubber.moveScrub({ pointerId: 3, clientY: 240, currentTarget: railEl });
    assert.equal(rafQueue.size, 1);
    scrubber.resetScrubberForRootChange();
    assert.equal(canceled.length, 1);
    assert.equal(scrubber.scrubbing.value, false);
  });
});

test("apps/web/src CSS and SFC sources follow compositor-only motion, prefers-reduced-motion, and hygiene rules", () => {
  const allSrc = listFiles(SRC_ROOT);
  const styleAndSfc = allSrc.filter((p) => p.endsWith(".css") || p.endsWith(".vue"));

  for (const file of allSrc) {
    const rel = relative(SRC_ROOT, file);
    if (!rel.includes(".test.")) {
      assert.equal(rel.endsWith(".js"), false, `Unexpected production .js file: ${rel}`);
      const lineCount = readFileSync(file, "utf8").split("\n").length;
      assert.ok(lineCount < 800, `File exceeds 800 lines (${lineCount}): ${rel}`);
    }
    if (rel.endsWith(".vue") || rel.endsWith(".html")) {
      const content = readFileSync(file, "utf8");
      assert.doesNotMatch(content, /<select[\s>]/i, `Native <select> disallowed in ${rel}`);
      assert.doesNotMatch(content, /\bwindow\.(alert|confirm|prompt)\s*\(/, `Native dialog disallowed in ${rel}`);
    }
  }

  for (const file of styleAndSfc) {
    const rel = relative(SRC_ROOT, file);
    const content = readFileSync(file, "utf8");
    assert.doesNotMatch(content, /transition\s*:\s*all\b/, `transition: all disallowed in ${rel}`);
    if (/(transition|animation)\s*:/.test(content)) {
      assert.match(content, /prefers-reduced-motion/, `Missing prefers-reduced-motion guard in ${rel}`);
    }
  }

  const auroraCss = readSrc("fluid-aurora.css");
  assert.doesNotMatch(auroraCss, /infinite|aurora-float-/);
  const baseCss = readSrc("style.css");
  assert.doesNotMatch(baseCss, /pulseDot|floatOrb|glassTilt|\binfinite\b/);

  const cinemaCss = readSrc("CinemaView.css");
  assert.match(cinemaCss, /\.cinema-tile\{[^}]*content-visibility:\s*auto/);
  const cinemaPlayRule = cinemaCss.match(/\.cinema-play\{[^}]*\}/)?.[0] ?? "";
  assert.doesNotMatch(cinemaPlayRule, /backdrop-filter/);
  const cinemaLabelRule = cinemaCss.match(/\.cinema-label\{[^}]*\}/)?.[0] ?? "";
  assert.doesNotMatch(cinemaLabelRule, /backdrop-filter/);
  const cinemaScopeRule = cinemaCss.match(/\.cinema-scope-label\{[^}]*\}/)?.[0] ?? "";
  assert.doesNotMatch(cinemaScopeRule, /backdrop-filter/);

  const photosCss = readSrc("PhotosView.css");
  const liveChipRule = photosCss.match(/\.photo-live-chip\{[^}]*\}/)?.[0] ?? "";
  assert.doesNotMatch(liveChipRule, /backdrop-filter/);

  const buttonVue = readSrc("IsleButton.vue");
  const glassBtnRule = buttonVue.match(/\.isle-btn\.variant-glass[\s\S]*?\}/)?.[0] ?? "";
  assert.doesNotMatch(glassBtnRule, /backdrop-filter/);

  const filesCss = readSrc("fluid-files.css");
  const trashEntryRule = filesCss.match(/(?:^|\n)\.trash-list\s+\.file-entry\s*\{[^}]*\}/)?.[0] ?? "";
  assert.match(trashEntryRule, /content-visibility:\s*auto/);
  const fileEntryRule = filesCss.match(/(?:^|\n)\.file-entry\s*\{[^}]*\}/)?.[0] ?? "";
  assert.ok(fileEntryRule.length > 0);
  assert.doesNotMatch(fileEntryRule, /content-visibility:\s*auto/);
  const sharedEntryRule = filesCss.match(/(?:^|\n)\.file-entry,\s*\.account-row\s*\{[^}]*\}/)?.[0] ?? "";
  assert.ok(sharedEntryRule.length > 0);
  assert.doesNotMatch(sharedEntryRule, /content-visibility:\s*auto/);

  const selectVue = readSrc("AppleSelect.vue");
  assert.match(selectVue, /addEventListener\("scroll",\s*handleScrollOrResize,\s*\{\s*capture:\s*true,\s*passive:\s*true\s*\}/);

  const shellHtml = readSrc("AppShell.html");
  assert.match(shellHtml, /<Transition name="isle-batch-bar">[\s\S]*class="file-batch-bar"/);
  assert.match(shellHtml, /!showingTrash && filesLoading && !fileEntries\.length/);
  assert.match(readSrc("PhotosBatchBar.vue"), /<Transition name="isle-hud-float">[\s\S]*class="photo-batch-hud"/);
  assert.match(readSrc("CinemaView.vue"), /<Transition name="isle-hud-float">[\s\S]*class="cinema-batch-hud"/);
});
