import { test } from 'node:test';
import assert from 'node:assert/strict';
import { importConversations } from '../src/desktop.ts';

test('Claude export preserves conversation identity and marks missing attachments', () => {
  const records = [{ uuid: 'chat-1', name: 'Research', created_at: '2026-01-01T00:00:00Z', updated_at: '2026-01-02T00:00:00Z', chat_messages: [{ uuid: 'm1', sender: 'human', text: 'hello', created_at: '2026-01-01T00:00:00Z', attachments: [{ file_name: 'report.pdf' }] }] }];
  const sessions = importConversations(records);
  assert.equal(sessions[0].nativeID, 'chat-1');
  assert.equal(sessions[0].messages[0].role, 'user');
  assert.equal(sessions[0].messages[0].text, 'hello');
  assert.equal(sessions[0].usage.length, 0);
  assert.ok(sessions[0].warnings.some(w => w.includes('附件')));
});

test('unrecognized exports fail explicitly', () => {
  assert.throws(() => importConversations({ accounts: [] }));
  assert.throws(() => importConversations([{ name: 'missing identity' }]));
});
