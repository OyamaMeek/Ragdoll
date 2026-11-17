import { test, type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, writeFile, appendFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { parseFile, scan } from '../src/logs.ts';

const fixture = (name: string) => join(import.meta.dirname, 'fixtures', name);

async function codexHome(t: TestContext, messages = ['# AGENTS.md instructions for /project\n<INSTRUCTIONS>rules</INSTRUCTIONS>', '<environment_context>context</environment_context>', '修复会话标题']) {
  const cache = join(import.meta.dirname, '../../.cache');
  await mkdir(cache, { recursive: true });
  const home = await mkdtemp(join(cache, 'codex-titles-'));
  t.after(() => rm(home, { recursive: true, force: true }));
  await mkdir(join(home, 'sessions'));
  const events = [
    { type: 'session_meta', payload: { id: 'thread-one', cwd: '/project' } },
    ...messages.map(text => ({ type: 'response_item', payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text }] } })),
  ];
  await writeFile(join(home, 'sessions/rollout.jsonl'), events.map(e => JSON.stringify(e)).join('\n') + '\n');
  return home;
}

test('Codex scan reads saved titles per home, including archived sessions', async t => {
  const home = await codexHome(t), other = await codexHome(t);
  await mkdir(join(home, 'archived_sessions'));
  await writeFile(join(home, 'archived_sessions/old.jsonl'), JSON.stringify({ type: 'session_meta', payload: { id: 'old' } }) + '\n');
  await writeFile(join(home, 'session_index.jsonl'), [
    { id: 'thread-one', thread_name: '旧标题' },
    { id: 'old', thread_name: '归档标题' },
    { id: 'thread-one', thread_name: '读取会话小标题' },
  ].map(e => JSON.stringify(e)).join('\n') + '\n');
  await writeFile(join(other, 'session_index.jsonl'), JSON.stringify({ id: 'thread-one', thread_name: '另一个 home' }) + '\n');
  const sessions = await scan([{ source: 'codex', path: home }, { source: 'codex', path: other }]);
  assert.equal(sessions.find(s => s.home === home && s.nativeID === 'thread-one')?.title, '读取会话小标题');
  assert.equal(sessions.find(s => s.nativeID === 'old')?.title, '归档标题');
  assert.equal(sessions.find(s => s.home === other)?.title, '另一个 home');
});

test('Codex title changes invalidate only the matching incremental session', async t => {
  const home = await codexHome(t), index = join(home, 'session_index.jsonl');
  const locations = [{ source: 'codex' as const, path: home }];
  const titles: string[] = [];
  const collect = (s: Awaited<ReturnType<typeof parseFile>>) => { titles.push(s.title); };
  await writeFile(index, JSON.stringify({ id: 'thread-one', thread_name: '原名' }) + '\n');
  await scan(locations, collect);
  assert.deepEqual(titles, ['原名']);
  titles.length = 0;
  await appendFile(index, JSON.stringify({ id: 'unrelated', thread_name: '无关标题' }) + '\n');
  await scan(locations, collect);
  assert.deepEqual(titles, []);
  await appendFile(index, JSON.stringify({ id: 'thread-one', thread_name: '新名称' }) + '\n');
  await scan(locations, collect);
  assert.deepEqual(titles, ['新名称']);
  titles.length = 0;
  await appendFile(index, JSON.stringify({ id: 'thread-one', thread_name: ' ' }) + '\n');
  await scan(locations, collect);
  assert.deepEqual(titles, ['修复会话标题']);
  titles.length = 0;
  await writeFile(index, JSON.stringify({ id: 'thread-one', thread_name: '再次命名' }) + '\n');
  await scan(locations, collect);
  await rm(index);
  await scan(locations, collect);
  assert.deepEqual(titles, ['再次命名', '修复会话标题']);
});

test('Codex missing title index uses the actual request and preserves messages', async t => {
  const home = await codexHome(t);
  const [session] = await scan([{ source: 'codex', path: home }]);
  assert.equal(session.title, '修复会话标题');
  assert.equal(session.messages.length, 3);
  assert.match(session.messages[0].text, /^# AGENTS.md/);
  const instructionsOnly = await codexHome(t, ['<environment_context>context</environment_context>']);
  assert.equal((await scan([{ source: 'codex', path: instructionsOnly }]))[0].title, 'thread-one');
  const attached = await codexHome(t, ['# Files mentioned by the user:\n\n## My request:\n添加小标题\n第二行']);
  assert.equal((await scan([{ source: 'codex', path: attached }]))[0].title, '添加小标题 第二行');
});

test('Codex title index reports damaged records and keeps valid titles', async t => {
  const home = await codexHome(t), warnings: string[] = [];
  await writeFile(join(home, 'session_index.jsonl'), '{invalid}\n{"id":4,"thread_name":true}\n' + JSON.stringify({ id: 'thread-one', thread_name: '有效名称' }) + '\n{"id":');
  const [session] = await scan([{ source: 'codex', path: home }], undefined, warning => warnings.push(warning));
  assert.equal(session.title, '有效名称');
  assert.ok(warnings.some(w => w.includes('session_index.jsonl')));
});

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
