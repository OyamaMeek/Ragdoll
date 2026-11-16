import { test } from 'node:test';
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { parseFile, scan } from '../src/logs.ts';

const fixture = (name: string) => join(import.meta.dirname, 'fixtures', name);

test('Codex cache writes are counted once inside total input', async () => {
  const session = await parseFile('codex', fixture('codex-cache-write.jsonl'));
  assert.equal(session.usage[0].input, 20);
  assert.equal(session.usage[0].cacheWrite, 20);
  const u = session.usage[0];
  assert.equal(u.input + u.cacheRead + u.cacheWrite + u.output, 110);
});

test('Claude replayed assistant IDs count once', async () => {
  const session = await parseFile('claude', fixture('claude-native-replay.jsonl'));
  assert.equal(session.usage.length, 2);
  assert.equal(session.usage.reduce((n, u) => n + u.output, 0), 37363);
  assert.equal(session.nativeID, 'session_3');
});

test('Codex canonical records take precedence over compatibility counters', async () => {
  const session = await parseFile('codex', fixture('codex-compaction-counter-domains.jsonl'));
  assert.equal(session.usage.length, 4);
  assert.equal(session.usage.reduce((n, u) => n + u.output, 0), 6856);
  assert.equal(session.usage[0].input, 785);
  assert.equal(session.usage[0].cacheRead, 213760);
});

test('dsh version selection reads the latest file only', async () => {
  const sessions = await scan([{ source: 'dsh', path: fixture('dsh') }]);
  const session = sessions.find(s => s.nativeID === 'dsh-a');
  assert.ok(session);
  assert.equal(session.title, 'Build script tidy');
  assert.equal(session.usage.length, 2);
  assert.equal(session.usage[0].cacheRead, 1000);
  assert.equal(session.messages.filter(m => m.role === 'user').length, 1);
});

test('dsh compressed logs expose messages and usage', async () => {
  const sessions = await scan([{ source: 'dsh', path: fixture('dsh-skills') }]);
  assert.equal(sessions.length, 3);
  assert.ok(sessions.some(s => s.messages.length > 0));
});
