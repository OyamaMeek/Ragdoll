import { test } from 'node:test';
import assert from 'node:assert/strict';
import { access, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { CodexDesktopClient, readScheduledMessage, queueDesktopMessage } from '../src/codex-desktop.ts';
import { object } from '../src/types.ts';

test('scheduled desktop messages reject canceled, stale and invalid targets without exposing their text', async t => {
  const base = join(import.meta.dirname, '../../.cache');
  await mkdir(base, { recursive: true });
  const root = await mkdtemp(join(base, 'desktop-consent-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const target = { nativeID: randomUUID(), home: root, project: root, title: '本地会话', text: '私密消息\n第二行' };
  const state = { enabled: true, attemptID: 'current', target };
  const path = join(root, 'codex-scheduled-message.json');
  await writeFile(path, JSON.stringify({ a: state }));
  assert.deepEqual(await readScheduledMessage(root, 'a', 'current'), target);
  await assert.rejects(readScheduledMessage(root, 'a', 'old'), /取消|失效/);
  await writeFile(path, JSON.stringify({ a: { ...state, enabled: false } }));
  await assert.rejects(readScheduledMessage(root, 'a', 'current'), /取消|失效/);
  for (const change of [{ nativeID: '--last' }, { project: 'relative' }, { home: '' }, { text: '  \n' }]) {
    await writeFile(path, JSON.stringify({ a: { ...state, target: { ...target, ...change } } }));
    await assert.rejects(readScheduledMessage(root, 'a', 'current'), error => error instanceof Error && /计划|会话/.test(error.message) && !error.message.includes('私密消息'));
  }
  await writeFile(path, 'broken');
  await assert.rejects(readScheduledMessage(root, 'a', 'current'), /计划/);
});

const executable = '/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex';
const available = await access(executable).then(() => true, () => false);

test('desktop messages enter the real persistent queue once without resuming a thread or starting inference', { skip: !available, timeout: 60000 }, async t => {
  const base = join(import.meta.dirname, '../../.cache');
  await mkdir(base, { recursive: true });
  const root = await mkdtemp(join(base, 'desktop-queue-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const home = join(root, 'home'), project = join(root, 'project');
  await mkdir(home); await mkdir(project);
  const creator = await CodexDesktopClient.connect(home);
  t.after(() => creator.close());
  const thread = object((await creator.request('thread/start', { cwd: project, modelProvider: 'openai', historyMode: 'paginated' })).thread);
  const nativeID = String(thread.id);
  await creator.request('thread/name/set', { threadId: nativeID, name: '隔离队列检查' });
  const target = { nativeID, home, project, title: '隔离队列检查', text: '包含换行\n和 $() `反引号` 的原样消息' };
  const attempt = randomUUID();
  await creator.close();
  await assert.rejects(queueDesktopMessage(target, attempt, async () => { throw new Error('已取消'); }), /已取消/);
  const receipt = await queueDesktopMessage(target, attempt, async () => {});
  assert.ok(receipt);
  await queueDesktopMessage(target, attempt, async () => {});
  const reader = await CodexDesktopClient.connect(home);
  t.after(() => reader.close());
  const queued = await reader.request('thread/queue/list', { threadId: nativeID });
  const data = queued.data;
  assert.ok(Array.isArray(data));
  assert.equal(data.length, 1);
  const item = object(data[0]);
  assert.equal(item.clientUserMessageId, attempt);
  assert.deepEqual(item.input, [{ type: 'text', text: target.text, text_elements: [] }]);
  const loaded = await reader.request('thread/loaded/list', {});
  assert.deepEqual(loaded.data, []);
  const metadata = object((await reader.request('thread/read', { threadId: nativeID, includeTurns: false })).thread);
  assert.equal(object(metadata.status).type, 'notLoaded');
  const rollout = await readFile(String(metadata.path), 'utf8');
  assert.equal(rollout.includes(target.text), false);
  await assert.rejects(queueDesktopMessage({ ...target, project: home }, randomUUID(), async () => {}), /项目/);
  await assert.rejects(queueDesktopMessage({ ...target, nativeID: randomUUID() }, randomUUID(), async () => {}), /会话|thread\/read/);
  await reader.request('thread/queue/delete', { threadId: nativeID, queuedSubmissionId: String(item.id) });
  assert.deepEqual((await reader.request('thread/queue/list', { threadId: nativeID })).data, []);
});
