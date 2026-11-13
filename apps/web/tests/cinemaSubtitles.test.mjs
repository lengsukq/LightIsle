import assert from "node:assert/strict";
import test from "node:test";
import {
  applyTextTracksOffset,
  formatCinemaResumeLabel,
  parseSubtitleToWebVtt,
  pickInitialSeriesSeason,
} from "../src/cinemaSubtitles.ts";
import { createCinemaKeyboardController } from "../src/cinemaKeyboard.ts";

test("parseSubtitleToWebVtt parses BOM SRT and shifts offsets with non-negative clamping", () => {
  const srt = "\uFEFF1\r\n00:00:00,500 --> 00:00:02,000\r\n第一行\r\n第二行\r\n\r\n2\r\n00:00:04,000 --> 00:00:06,250\r\n下一句\r\n";
  const vtt = parseSubtitleToWebVtt(srt, "movie.srt", 0);
  assert.ok(vtt.startsWith("WEBVTT\n"));
  assert.ok(vtt.includes("00:00:00.500 --> 00:00:02.000\n第一行\n第二行"));

  const shiftedEarly = parseSubtitleToWebVtt(srt, "movie.srt", -1.0);
  assert.ok(shiftedEarly.includes("00:00:00.000 --> 00:00:01.000"));
  assert.ok(shiftedEarly.includes("00:00:03.000 --> 00:00:05.250"));
});

test("parseSubtitleToWebVtt parses ASS/SSA dialogue events and strips override tags", () => {
  const ass = `[Script Info]
Title: Example

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:01:02.50,0:01:05.00,Default,,0,0,0,,{\\an8\\fs20}你好世界\\NHello`;
  const vtt = parseSubtitleToWebVtt(ass, "ep01.ass", 0.5);
  assert.ok(vtt.includes("00:01:03.000 --> 00:01:05.500\n你好世界\nHello"));
});

test("applyTextTracksOffset shifts live cues relative to original baseline without drift", () => {
  const cue1 = { startTime: 10, endTime: 13 };
  const cue2 = { startTime: 0.4, endTime: 2.0 };
  const video = { textTracks: [{ cues: [cue1, cue2] }] };
  const baselines = new WeakMap();

  applyTextTracksOffset(video, 0.5, baselines);
  assert.equal(cue1.startTime, 10.5);
  assert.equal(cue1.endTime, 13.5);

  applyTextTracksOffset(video, 1.5, baselines);
  assert.equal(cue1.startTime, 11.5);
  assert.equal(cue2.startTime, 1.9);

  applyTextTracksOffset(video, -1.0, baselines);
  assert.equal(cue1.startTime, 9.0);
  assert.equal(cue2.startTime, 0);

  applyTextTracksOffset(video, 0, baselines);
  assert.equal(cue1.startTime, 10);
  assert.equal(cue1.endTime, 13);
});

test("formatCinemaResumeLabel and pickInitialSeriesSeason format series/movie resume hints cleanly", () => {
  assert.equal(
    formatCinemaResumeLabel({ season: 1, episode: 4, position: 720, duration: 1800 }),
    "继续播放 S01E04 · 剩余 18 分钟",
  );
  assert.equal(
    formatCinemaResumeLabel({ position: 600, duration: 3120 }),
    "继续播放 · 剩余 42 分钟",
  );

  const films = [
    { id: 1, season: 1, episode: 1, completed: true, position: 1000 },
    { id: 2, season: 2, episode: 3, completed: false, position: 120 },
    { id: 3, season: 3, episode: 1, completed: false, position: 0 },
  ];
  assert.equal(pickInitialSeriesSeason(films, 3), 3);
  assert.equal(pickInitialSeriesSeason(films), 2);
});

test("cinemaKeyboardController handles Space on dock buttons, hold ArrowRight 2x boost, and tiered Esc", async () => {
  const ctrl = createCinemaKeyboardController(20);
  const events = [];
  const makeTarget = (selectorMatch) => ({
    closest(sel) {
      if (selectorMatch && sel.includes(selectorMatch)) return {};
      return null;
    },
  });

  let defaultPrevented = false;
  const makeEvent = (key, target = null, repeat = false) => {
    defaultPrevented = false;
    return {
      key,
      code: key === " " ? "Space" : key,
      repeat,
      altKey: false,
      ctrlKey: false,
      metaKey: false,
      target,
      preventDefault() {
        defaultPrevented = true;
      },
    };
  };

  const baseBindings = {
    dialog: {},
    playing: true,
    playlistOpen: true,
    popoverOpen: true,
    isFullscreen: true,
    showControls: () => events.push("showControls"),
    jump: (s) => events.push(`jump:${s}`),
    togglePlay: () => events.push("togglePlay"),
    adjustVolume: (d) => events.push(`vol:${d}`),
    toggleMute: () => events.push("mute"),
    toggleFullscreen: () => events.push("fullscreen"),
    exitFullscreen: () => events.push("exitFullscreen"),
    startHoldBoost: () => events.push("boostStart"),
    stopHoldBoost: () => events.push("boostStop"),
    closePopover: () => events.push("closePopover"),
    closePlaylist: () => events.push("closePlaylist"),
    close: () => events.push("close"),
  };

  // Space pressed while a dock <button> has focus should toggle playback, not be ignored or hijacked.
  ctrl.handleKeydown(makeEvent(" ", makeTarget("button")), baseBindings);
  assert.equal(defaultPrevented, true);
  assert.equal(events.includes("togglePlay"), true);

  // Space inside an active popover menu should NOT toggle playback.
  events.length = 0;
  ctrl.handleKeydown(makeEvent(" ", makeTarget(".cinema-popover-menu")), baseBindings);
  assert.equal(events.includes("togglePlay"), false);

  // Short ArrowRight tap (< 20ms) seeks +10s on keyup without starting speed boost.
  events.length = 0;
  ctrl.handleKeydown(makeEvent("ArrowRight"), baseBindings);
  ctrl.handleKeyup(makeEvent("ArrowRight"), baseBindings);
  assert.deepEqual(events.filter((x) => x.startsWith("jump:") || x.startsWith("boost")), ["jump:10"]);

  // Long ArrowRight hold (>= 20ms) enters speed boost and restores on keyup without seeking +10s.
  events.length = 0;
  ctrl.handleKeydown(makeEvent("ArrowRight"), baseBindings);
  await new Promise((resolve) => setTimeout(resolve, 40));
  ctrl.handleKeyup(makeEvent("ArrowRight"), baseBindings);
  assert.deepEqual(events.filter((x) => x.startsWith("jump:") || x.startsWith("boost")), ["boostStart", "boostStop"]);

  // Tiered Escape order: fullscreen -> popover -> playlist -> close.
  events.length = 0;
  ctrl.handleKeydown(makeEvent("Escape"), { ...baseBindings });
  ctrl.handleKeydown(makeEvent("Escape"), { ...baseBindings, isFullscreen: false });
  ctrl.handleKeydown(makeEvent("Escape"), { ...baseBindings, isFullscreen: false, popoverOpen: false });
  ctrl.handleKeydown(makeEvent("Escape"), { ...baseBindings, isFullscreen: false, popoverOpen: false, playlistOpen: false });
  assert.deepEqual(events, ["exitFullscreen", "closePopover", "closePlaylist", "close"]);
});
