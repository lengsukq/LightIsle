import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { readFileSync } from 'node:fs';

test('trash entries do not depend on retention-policy visibility', () => {
  const source = readFileSync(new URL('../src/App.vue', import.meta.url), 'utf8');
  const marker = source.indexOf('class="trash-list"');
  assert.ok(marker >= 0);
  const trash = source.slice(marker, source.indexOf('</div>\n              <div v-if="!showingTrash', marker));
  assert.match(trash, /v-if="trashRetention"/);
  assert.match(trash, /v-for="entry in \(trashPresentation==='items' \? trashItems : \[\]\)"/);
  assert.doesNotMatch(trash, /v-else\s+v-for="entry in trashItems"/);
});
