import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { mkdir, mkdtemp, writeFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { object } from '../src/types.ts';

test('runtime exposes usage scanning and rejects conversation methods without loading old chat caches', { timeout: 10000 }, async t => {
  const cache = join(import.meta.dirname, '../../.cache');
  await mkdir(cache, { recursive: true });
  const root = await mkdtemp(join(cache, 'usage-runtime-'));
  await mkdir(join(root, 'conversations/old'), { recursive: true });
  await writeFile(join(root, 'conversations/old/session.json'), JSON.stringify({ id: 'private', messages: [{ text: 'PRIVATE_BODY' }], usage: [] }));
  const child = spawn(process.execPath, [join(import.meta.dirname, '../src/main.ts'), '--data-dir', root]);
  t.after(async () => { child.kill(); await rm(root, { recursive: true, force: true }); });
  const output = createInterface({ input: child.stdout });
  child.stdin.write([
    { id: 1, method: 'initialize' },
    { id: 2, method: 'scan', params: { locations: [] } },
    { id: 3, method: 'chat.start', params: {} },
    { id: 4, method: 'codex.autoWarmup', params: { id: 'a', attemptID: 'canceled' } },
  ].map(value => JSON.stringify(value)).join('\n') + '\n');
  const responses = new Map<number, Record<string, unknown>>();
  const events: unknown[] = [];
  for await (const line of output) {
    const value = object(JSON.parse(line));
    if (typeof value.id === 'number') responses.set(value.id, value);
    else events.push(value);
    if (responses.size === 4) break;
  }
  assert.equal(responses.size, 4);
  assert.equal('agents' in object(responses.get(1)?.result), false);
  assert.equal(object(responses.get(2)?.result).count, 0);
  assert.deepEqual(events, []);
  assert.match(String(object(responses.get(3)?.error).message), /未知助手方法/);
  assert.match(String(object(responses.get(4)?.error).message), /自动激活状态/);
});
