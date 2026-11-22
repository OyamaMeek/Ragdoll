import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseCodexQuota, readWarmupCompletion, warmupCodex } from '../src/codex-warmup.ts';

test('Codex quota validates windows and distinguishes unused, active, expired and exhausted', () => {
  const now = 2_000_000_000;
  const payload = (used: number, reset: number, weekly = 10) => ({ rate_limit: {
    primary_window: { used_percent: used, limit_window_seconds: 18000, reset_at: reset },
    secondary_window: { used_percent: weekly, limit_window_seconds: 604800, reset_at: now + 604800 },
  } });
  assert.equal(parseCodexQuota(payload(0, now + 18000), now).active, false);
  assert.equal(parseCodexQuota(payload(1, now + 18000), now).active, true);
  assert.equal(parseCodexQuota(payload(1, now), now).active, false);
  assert.equal(parseCodexQuota(payload(0, now + 18000, 100), now).exhausted, true);
  assert.equal(parseCodexQuota(payload(100, now + 18000), now).exhausted, true);
  assert.throws(() => parseCodexQuota({}), /额度/);
  assert.throws(() => parseCodexQuota(payload(NaN, now + 18000)), /额度/);
  assert.throws(() => parseCodexQuota({ rate_limit: { primary_window: { used_percent: 1, limit_window_seconds: 123, reset_at: now + 1 } } }), /5h/);
});

test('Codex warmup requires a complete structured SSE success across byte fragments', async () => {
  const response = (text: string) => new Response(new ReadableStream({ start(controller) {
    for (const byte of new TextEncoder().encode(text)) controller.enqueue(Uint8Array.of(byte));
    controller.close();
  } }), { headers: { 'content-type': 'text/event-stream' } });
  await readWarmupCompletion(response('event: response.completed\r\ndata: {"type":"response.completed",\r\ndata: "response":{"status":"completed"}}\r\n\r\n'));
  await readWarmupCompletion(response('data: {"type":"response.done","response":{"status":"completed"}}\n\n'));
  await readWarmupCompletion(new Response(new TextEncoder().encode('data: {"type":"response.completed","response":{"status":"completed"}}\n\n')));
  for (const text of [
    'data: {"type":"response.output_text.delta","delta":"response.completed"}\n\n',
    'data: {"type":"response.completed","response":{"status":"failed"}}\n\n',
    'data: {"type":"response.failed"}\n\n',
    'data: {"type":"error","message":"PRIVATE_TOKEN"}\n\n',
    'data: {"type":"response.completed","response":{"status":"completed"}}',
  ]) await assert.rejects(readWarmupCompletion(response(text)), error => error instanceof Error && !error.message.includes('PRIVATE_TOKEN'));
  await assert.rejects(readWarmupCompletion(new Response('x'.repeat(1024 * 1024 + 1), { headers: { 'content-type': 'text/event-stream' } })), /上限/);
  await assert.rejects(readWarmupCompletion(new Response('not SSE')), /SSE/);
});

test('Codex warmup rejects missing authentication without creating a home', async () => {
  await assert.rejects(warmupCodex(''), /目录/);
  await assert.rejects(warmupCodex('/nonexistent-ragdoll-codex-home'), /登录/);
});

test('live Codex warmup through the configured account', { skip: !process.env.RAGDOLL_CODEX_LIVE_HOME, timeout: 90000 }, async () => {
  const result = await warmupCodex(process.env.RAGDOLL_CODEX_LIVE_HOME!);
  assert.ok(['activated', 'alreadyActive', 'exhausted', 'requestSent'].includes(result.status));
  assert.equal(typeof result.message, 'string');
  console.log(JSON.stringify(result));
});
