import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { readFileSync } from 'node:fs';

test('IsleButton provides complete capsule button variants, sizes, and tactile interactions', () => {
  const source = readFileSync(new URL('../src/IsleButton.vue', import.meta.url), 'utf8');

  // Verify variants
  assert.match(source, /variant-primary/, 'IsleButton must support variant-primary');
  assert.match(source, /variant-tonal/, 'IsleButton must support variant-tonal');
  assert.match(source, /variant-danger/, 'IsleButton must support variant-danger');
  assert.match(source, /variant-glass/, 'IsleButton must support variant-glass');
  assert.match(source, /variant-ghost/, 'IsleButton must support variant-ghost');

  // Verify capsule shape & press motion
  assert.match(source, /border-radius:\s*9999px;/, 'IsleButton must have capsule border-radius');
  assert.match(source, /transform:\s*scale\(0\.96\)/, 'IsleButton must support iOS tactile press-scale');

  // Verify accessible button attributes and loading state
  assert.match(source, /:disabled="isDisabled"/, 'IsleButton must bind native disabled attribute');
  assert.match(source, /:aria-disabled="isDisabled \? 'true' : undefined"/, 'IsleButton must provide aria-disabled');
  assert.match(source, /:aria-busy="loading \? 'true' : undefined"/, 'IsleButton must provide aria-busy');
  assert.match(source, /class="spin-icon"/, 'IsleButton must render animated spinner when loading');
});

test('IsleCard provides fluid surfaces, stereoscopic shadows, and slot composition', () => {
  const source = readFileSync(new URL('../src/IsleCard.vue', import.meta.url), 'utf8');

  // Verify variants
  assert.match(source, /variant-card/, 'IsleCard must support variant-card');
  assert.match(source, /variant-item/, 'IsleCard must support variant-item');
  assert.match(source, /variant-glass/, 'IsleCard must support variant-glass');

  // Verify design token bindings
  assert.match(source, /--fluid-card-fill/, 'IsleCard must bind --fluid-card-fill');
  assert.match(source, /--fluid-card-border/, 'IsleCard must bind --fluid-card-border');
  assert.match(source, /--fluid-card-shadow/, 'IsleCard must bind --fluid-card-shadow');
  assert.match(source, /--radius-lg/, 'IsleCard must bind --radius-lg');

  // Verify slots
  assert.match(source, /name="header"/, 'IsleCard must provide header slot');
  assert.match(source, /name="actions"/, 'IsleCard must provide actions slot');
  assert.match(source, /name="footer"/, 'IsleCard must provide footer slot');
  assert.match(source, /name="icon"/, 'IsleCard must provide icon slot');
});

test('IsleBanner provides semantic tone feedback, accessibility, and dismissibility', () => {
  const source = readFileSync(new URL('../src/IsleBanner.vue', import.meta.url), 'utf8');

  // Verify tone types
  assert.match(source, /type-info/, 'IsleBanner must support type-info');
  assert.match(source, /type-success/, 'IsleBanner must support type-success');
  assert.match(source, /type-warning/, 'IsleBanner must support type-warning');
  assert.match(source, /type-error/, 'IsleBanner must support type-error');
  assert.match(source, /type-offline/, 'IsleBanner must support type-offline');

  // Verify accessibility
  assert.match(source, /role="status"/, 'IsleBanner must define role="status"');
  assert.match(source, /aria-live="polite"/, 'IsleBanner must define aria-live="polite"');

  // Verify slots and events
  assert.match(source, /name="action"/, 'IsleBanner must provide action slot');
  assert.match(source, /emit\('close'\)/, 'IsleBanner must emit close event');
});

test('IsleChip provides capsule filter chips with selection states and removal', () => {
  const source = readFileSync(new URL('../src/IsleChip.vue', import.meta.url), 'utf8');

  // Verify shape and active state
  assert.match(source, /border-radius:\s*9999px;/, 'IsleChip must have capsule border-radius');
  assert.match(source, /is-selected/, 'IsleChip must support selected state');
  assert.match(source, /aria-pressed="selected \? 'true' : 'false'/, 'IsleChip must provide aria-pressed');
  assert.match(source, /transform:\s*scale\(0\.96\)/, 'IsleChip must support iOS press-scale');

  // Verify remove emit
  assert.match(source, /emit\("remove", event\)/, 'IsleChip must emit remove event');
});

test('IsleEmpty provides empty state presentation with icon, title, description, and action slots', () => {
  const source = readFileSync(new URL('../src/IsleEmpty.vue', import.meta.url), 'utf8');

  // Verify slots & structure
  assert.match(source, /name="icon"/, 'IsleEmpty must provide icon slot');
  assert.match(source, /name="title"/, 'IsleEmpty must provide title slot');
  assert.match(source, /name="action"/, 'IsleEmpty must provide action slot');
  assert.match(source, /role="status"/, 'IsleEmpty must define role="status"');

  // Verify compact & card modes
  assert.match(source, /compact/, 'IsleEmpty must support compact mode');
  assert.match(source, /card-surface/, 'IsleEmpty must support card-surface mode');
});

test('IsleBadge provides status pills with semantic variants and sizes', () => {
  const source = readFileSync(new URL('../src/IsleBadge.vue', import.meta.url), 'utf8');

  // Verify variants
  assert.match(source, /badge-neutral/, 'IsleBadge must support badge-neutral');
  assert.match(source, /badge-online/, 'IsleBadge must support badge-online');
  assert.match(source, /badge-offline/, 'IsleBadge must support badge-offline');
  assert.match(source, /badge-warning/, 'IsleBadge must support badge-warning');
  assert.match(source, /badge-accent/, 'IsleBadge must support badge-accent');

  // Verify pill radius & dot
  assert.match(source, /border-radius:\s*var\(--radius-full\);/, 'IsleBadge must have capsule radius');
  assert.match(source, /isle-badge-dot/, 'IsleBadge must support indicator dot');
});

test('IsleImageViewer provides anchored zoom, gesture panning, HUD toolbar, and navigation', () => {
  const source = readFileSync(new URL('../src/IsleImageViewer.vue', import.meta.url), 'utf8');

  // Verify gestures and zoom methods
  assert.match(source, /zoomAtAnchor/, 'IsleImageViewer must use zoomAtAnchor for cursor-anchored zoom');
  assert.match(source, /normalizeViewerTransform/, 'IsleImageViewer must normalize zoom bounds');
  assert.match(source, /pinchScale/, 'IsleImageViewer must support pinch scaling');
  assert.match(source, /toggleActualSize/, 'IsleImageViewer must support 1:1 vs fit toggle');
  assert.match(source, /rotate/, 'IsleImageViewer must support 90-degree rotation');

  // Verify navigation and HUD
  assert.match(source, /viewer-hud/, 'IsleImageViewer must render floating HUD toolbar');
  assert.match(source, /nav-btn prev/, 'IsleImageViewer must render previous navigation arrow');
  assert.match(source, /nav-btn next/, 'IsleImageViewer must render next navigation arrow');
});

test('IsleVideoPlayer provides unified transport bar, scrubbing, volume, rate, PiP, and keyboard shortcuts', () => {
  const viewSource = readFileSync(new URL('../src/IsleVideoPlayer.vue', import.meta.url), 'utf8');
  const transportSource = readFileSync(
    new URL('../src/composables/useHtmlVideoTransport.ts', import.meta.url),
    'utf8'
  );
  const combined = `${viewSource}\n${transportSource}`;

  // Verify controls
  assert.match(viewSource, /player-transport-bar/, 'IsleVideoPlayer must render unified transport bar');
  assert.match(viewSource, /player-timeline/, 'IsleVideoPlayer must render interactive scrub timeline');
  assert.match(viewSource, /timeline-buffered/, 'IsleVideoPlayer must indicate buffered ranges');
  assert.match(viewSource, /timeline-hover-time/, 'IsleVideoPlayer must show hover timestamp preview');

  // Verify audio, rate, PiP, fullscreen, and symmetric listener teardown
  assert.match(viewSource, /volume-slider/, 'IsleVideoPlayer must provide volume control');
  assert.match(combined, /playbackRateOptions/, 'IsleVideoPlayer must support multiple playback rates');
  assert.match(transportSource, /requestPictureInPicture/, 'IsleVideoPlayer must support Picture-in-Picture');
  assert.match(transportSource, /requestFullscreen/, 'IsleVideoPlayer must support Fullscreen mode');
  assert.match(transportSource, /handleKeydown/, 'IsleVideoPlayer must support keyboard shortcuts');
  assert.match(
    transportSource,
    /removeEventListener\("fullscreenchange",\s*handleFullscreenChange\)/,
    'useHtmlVideoTransport must clean up fullscreenchange listener on unmount'
  );
});
