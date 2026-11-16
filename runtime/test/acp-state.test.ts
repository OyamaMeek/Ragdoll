import { test } from 'node:test';
import assert from 'node:assert/strict';
import { applyUpdate } from '../src/acp-state.ts';
import type { Session } from '../src/types.ts';

function session(): Session { return { id: 's', nativeID: 'n', source: 'acp', title: 'test', project: '/', home: '', created: 1, updated: 1, messages: [], usage: [], files: [], warnings: [] }; }
test('ACP v2 message replacements are idempotent and interleaved chunks stay separate', () => {
  const s = session();
  applyUpdate(s, { sessionUpdate: 'agent_message_chunk', messageId: 'a', content: { type: 'text', text: 'one' } }, 'fallback');
  applyUpdate(s, { sessionUpdate: 'agent_message_chunk', messageId: 'b', content: { type: 'text', text: 'two' } }, 'fallback');
  applyUpdate(s, { sessionUpdate: 'agent_message', messageId: 'a', content: [{ type: 'text', text: 'complete' }] }, 'fallback');
  applyUpdate(s, { sessionUpdate: 'agent_message', messageId: 'a', content: [{ type: 'text', text: 'complete' }] }, 'fallback');
  assert.equal(s.messages.length, 2);
  assert.equal(s.messages[0].text, 'complete');
  assert.equal(s.messages[1].text, 'two');
});
test('ACP v2 idle snapshots complete activity without counting context tokens as consumption', () => {
  const s = session();
  applyUpdate(s, { sessionUpdate: 'usage_update', used: 4000, size: 128000 }, 'f');
  assert.equal(s.usage.length, 0);
  assert.equal(applyUpdate(s, { sessionUpdate: 'state_update', state: 'idle', stopReason: 'end_turn' }, 'f').idle, true);
});
