import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { readFileSync } from 'node:fs';

test('IsleModal encapsulates Teleport to body and ARIA dialog semantics', () => {
  const source = readFileSync(new URL('../src/components/ui/IsleModal.vue', import.meta.url), 'utf8');

  // Verify Teleport to body
  assert.match(source, /<Teleport to="body">/, 'IsleModal must mount directly to body via Teleport');

  // Verify dialog semantics
  assert.match(source, /role="dialog"|:role="role"/, 'IsleModal must provide role="dialog"');
  assert.match(source, /aria-modal="true"/, 'IsleModal must declare aria-modal="true"');

  // Verify z-index token usage
  assert.match(source, /--z-modal/, 'IsleModal must use --z-modal token for layer hierarchy');
});

test('AppsCenterView uses IsleModal for logs modal and removes unreachable dead modals', () => {
  const source = readFileSync(new URL('../src/features/apps/AppsCenterView.vue', import.meta.url), 'utf8');

  // Verify IsleModal is imported
  assert.match(source, /import IsleModal from ["']\.\.\/\.\.\/components\/ui\/IsleModal\.vue["']/, 'IsleModal must be imported');

  // Dead modals were removed in favor of inline AppDetailPanel
  assert.doesNotMatch(source, /editingAccessApp/, 'Dead editingAccessApp modal must remain removed');
  assert.doesNotMatch(source, /editingConfigApp/, 'Dead editingConfigApp modal must remain removed');

  // Verify IsleModal wraps logs modal
  assert.match(
    source,
    /<IsleModal\s+v-if="viewingLogsApp"/,
    'viewingLogsApp modal must use IsleModal',
  );

  // Verify openAppDetail does not trigger viewingLogsApp modal
  const controller = readFileSync(new URL('../src/composables/useAppsCenterController.ts', import.meta.url), 'utf8');
  assert.match(controller, /if\s*\(options\?\.openModal\)\s*\{\s*viewingLogsApp\.value\s*=\s*app;/);
});

test('generated-fluid.css contains explicit z-index tokens', () => {
  const source = readFileSync(new URL('../src/generated-fluid.css', import.meta.url), 'utf8');

  assert.match(source, /--z-modal:\s*1300;/, '--z-modal must be 1300');
  assert.match(source, /--z-sidebar:\s*40;/, '--z-sidebar must be 40');
  assert.match(source, /--z-topbar:\s*15;/, '--z-topbar must be 15');
  assert.match(source, /--z-confirm:\s*9999;/, '--z-confirm must be 9999');
  assert.match(source, /--z-dropdown:\s*99999;/, '--z-dropdown must be 99999');
});

test('fluid.css does not trap .main in an integer stacking context below .sidebar', () => {
  const source = readFileSync(new URL('../src/styles/fluid.css', import.meta.url), 'utf8');

  // .main should not have z-index: 1
  assert.doesNotMatch(
    source,
    /\.main\s*\{[^}]*z-index:\s*1;/,
    '.main should not have z-index: 1 creating a stacking context below sidebar',
  );
});
