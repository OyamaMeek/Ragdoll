import { test } from 'node:test';
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { parseFile } from '../src/logs.ts';

test('usage parser excludes message bodies and source attachment references', async () => {
  const session = await parseFile('codex', join(import.meta.dirname, 'fixtures/codex-cache-write.jsonl'));
  assert.equal(session.usage[0].input + session.usage[0].output + session.usage[0].cacheRead + session.usage[0].cacheWrite, 110);
  assert.equal('messages' in session, false);
  assert.equal('files' in session, false);
  assert.equal('migration' in session, false);
});
