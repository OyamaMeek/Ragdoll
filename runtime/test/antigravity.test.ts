import { test, type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { chmod, mkdir, mkdtemp, readdir, rm, stat, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { defaultLocations, scan } from '../src/logs.ts';
import { object } from '../src/types.ts';

const CONV_SCHEMA = `
CREATE TABLE trajectory_meta (trajectory_id text PRIMARY KEY, cascade_id text, trajectory_type integer, source integer);
CREATE TABLE steps (idx integer PRIMARY KEY, step_type integer NOT NULL DEFAULT 0, status integer NOT NULL DEFAULT 0, metadata blob);
CREATE TABLE gen_metadata (idx integer PRIMARY KEY, data blob, size integer NOT NULL DEFAULT 0);
`;

const SUMMARY_SCHEMA = `
CREATE TABLE conversation_summaries (
  conversation_id text PRIMARY KEY,
  title text NOT NULL DEFAULT '',
  preview text NOT NULL DEFAULT '',
  step_count integer NOT NULL DEFAULT 0,
  last_modified_time datetime NOT NULL,
  workspace_uris text NOT NULL,
  parent_conversation_id text NOT NULL DEFAULT '',
  last_user_input_time datetime NOT NULL DEFAULT '',
  app_data_dir text NOT NULL DEFAULT ''
);
`;

function uvarint(value: number): Buffer {
  const bytes: number[] = [];
  let v = BigInt(value);
  while (v >= 0x80n) {
    bytes.push(Number((v & 0x7fn) | 0x80n));
    v >>= 7n;
  }
  bytes.push(Number(v));
  return Buffer.from(bytes);
}

const pbVarint = (field: number, value: number) => Buffer.concat([uvarint((field << 3) | 0), uvarint(value)]);
const pbBytes = (field: number, data: Buffer | string) => {
  const buf = typeof data === 'string' ? Buffer.from(data, 'utf8') : data;
  return Buffer.concat([uvarint((field << 3) | 2), uvarint(buf.length), buf]);
};

function pbStepMetadata(opts: {
  sec: number;
  nanos?: number;
  gen?: number;
  usage?: { input?: number; output?: number; cacheWrite?: number; cacheRead?: number; response?: string };
}): Buffer {
  const parts = [pbBytes(1, Buffer.concat([pbVarint(1, opts.sec), ...(opts.nanos ? [pbVarint(2, opts.nanos)] : [])]))];
  if (opts.usage) {
    const u: Buffer[] = [];
    if (opts.usage.input) u.push(pbVarint(2, opts.usage.input));
    if (opts.usage.output) u.push(pbVarint(3, opts.usage.output));
    if (opts.usage.cacheWrite) u.push(pbVarint(4, opts.usage.cacheWrite));
    if (opts.usage.cacheRead) u.push(pbVarint(5, opts.usage.cacheRead));
    if (opts.usage.response) u.push(pbBytes(11, opts.usage.response));
    parts.push(pbBytes(9, Buffer.concat(u)));
  }
  if (opts.gen !== undefined) parts.push(pbBytes(20, pbVarint(3, opts.gen)));
  return Buffer.concat(parts);
}

function pbGenMetadata(model: string, modelField = 19, lastStepIndex?: number): Buffer {
  const inner = [pbBytes(modelField, model)];
  if (lastStepIndex !== undefined) {
    inner.push(pbBytes(20, Buffer.concat([pbBytes(1, 'last_step_index'), pbBytes(2, String(lastStepIndex))])));
  }
  return pbBytes(1, Buffer.concat(inner));
}

async function tempRoot(t: TestContext, prefix = 'antigravity-'): Promise<string> {
  const cache = join(import.meta.dirname, '../../.cache');
  await mkdir(cache, { recursive: true });
  const root = await mkdtemp(join(cache, prefix));
  t.after(() => rm(root, { recursive: true, force: true }));
  return root;
}

test('defaultLocations includes antigravity under .gemini or ANTIGRAVITY_HOME', () => {
  const previous = process.env.ANTIGRAVITY_HOME;
  try {
    delete process.env.ANTIGRAVITY_HOME;
    const defaults = defaultLocations();
    const entry = defaults.find(item => item.source === 'antigravity');
    assert.ok(entry);
    assert.match(entry.path, /\.gemini$/);
    process.env.ANTIGRAVITY_HOME = '/custom/antigravity-home';
    assert.equal(defaultLocations().find(item => item.source === 'antigravity')?.path, '/custom/antigravity-home');
  } finally {
    if (previous === undefined) delete process.env.ANTIGRAVITY_HOME;
    else process.env.ANTIGRAVITY_HOME = previous;
  }
});

test('Antigravity scans desktop, insiders, and CLI sessions while ignoring orphan summaries', async t => {
  const gemini = await tempRoot(t);
  const appDir = join(gemini, 'antigravity');
  const insidersDir = join(gemini, 'antigravity-insiders');
  const cliDir = join(gemini, 'antigravity-cli');
  await mkdir(join(appDir, 'conversations'), { recursive: true });
  await mkdir(join(insidersDir, 'conversations'), { recursive: true });
  await mkdir(join(cliDir, 'conversations'), { recursive: true });

  const sharedID = '37c3c786-9a11-44be-97df-b8fc1ccebc78';
  const appDB = new DatabaseSync(join(appDir, 'conversations', `${sharedID}.db`));
  appDB.exec('PRAGMA journal_mode = WAL;' + CONV_SCHEMA);
  const insertStep = appDB.prepare('INSERT INTO steps (idx, step_type, metadata) VALUES (?, 15, ?)');
  insertStep.run(0, pbStepMetadata({ sec: 1_791_860_300 }));
  insertStep.run(1, pbStepMetadata({ sec: 1_791_860_310, usage: { input: 100, output: 10, cacheWrite: 50, cacheRead: 200, response: 'resp_same' } }));
  insertStep.run(2, pbStepMetadata({ sec: 1_791_860_318, nanos: 500_000_000, usage: { input: 120, output: 45, cacheWrite: 50, cacheRead: 200, response: 'resp_same' } }));
  insertStep.run(3, pbStepMetadata({ sec: 1_791_860_330, gen: 1, usage: { input: 80, output: 30, cacheRead: 400 } }));
  const insertGen = appDB.prepare('INSERT INTO gen_metadata (idx, data, size) VALUES (?, ?, ?)');
  const gen0 = pbBytes(1, Buffer.concat([pbBytes(19, 'gemini-3.8-flash-n'), pbBytes(21, 'Gemini 3.8 Flash')]));
  const gen1 = pbGenMetadata('gemini-4-neon', 21);
  insertGen.run(0, gen0, gen0.length);
  insertGen.run(1, gen1, gen1.length);
  appDB.close();

  const desktopLogDir = join(appDir, 'brain', sharedID, '.system_generated', 'logs');
  await mkdir(desktopLogDir, { recursive: true });
  await writeFile(join(desktopLogDir, 'transcript_full.jsonl'), [
    { step_index: 0, source: 'USER_EXPLICIT', type: 'USER_INPUT', created_at: '2026-10-13T02:58:20Z', content: '<USER_REQUEST>\n桌面端同步骤不重复计数\n</USER_REQUEST>' },
    { step_index: 2, source: 'MODEL', type: 'PLANNER_RESPONSE', created_at: '2026-10-13T02:58:38Z', model: 'gemini-3.8-flash-n', input_tokens: 120, output_tokens: 45, cache_read_tokens: 200 },
    { step_index: 3, source: 'MODEL', type: 'PLANNER_RESPONSE', created_at: '2026-10-13T02:58:50Z', model: 'gemini-4-neon', input_tokens: 80, output_tokens: 30, cache_read_tokens: 400 },
    { step_index: 5, source: 'MODEL', type: 'PLANNER_RESPONSE', created_at: '2026-10-13T02:59:00Z', model: 'gemini-4-carbon-d', input_tokens: 90, output_tokens: 15, cache_read_tokens: 300 },
  ].map(line => JSON.stringify(line)).join('\n') + '\n');

  const appSum = new DatabaseSync(join(appDir, 'conversation_summaries.db'));
  appSum.exec('PRAGMA journal_mode = WAL;' + SUMMARY_SCHEMA);
  const insertSummary = appSum.prepare(
    'INSERT INTO conversation_summaries (conversation_id, title, preview, last_modified_time, workspace_uris, parent_conversation_id, app_data_dir) VALUES (?, ?, ?, ?, ?, ?, ?)'
  );
  insertSummary.run(sharedID, '', '实现 Antigravity 会话解析', '2026-11-07 00:12:46.60116+00:00', '["vscode-remote://ssh/work","file:///Volumes/Work/My%20Repo"]', 'parent-uuid', 'antigravity');
  insertSummary.run('0a0b0c0d-0000-4000-8000-000000000000', '已删除孤立摘要', '', '2026-11-07 00:12:00+00:00', '["file:///Volumes/Work/Gone"]', '', 'antigravity');
  appSum.close();

  const insDB = new DatabaseSync(join(insidersDir, 'conversations', `${sharedID}.db`));
  insDB.exec('PRAGMA journal_mode = WAL;' + CONV_SCHEMA);
  insDB.prepare('INSERT INTO steps (idx, step_type, metadata) VALUES (1, 15, ?)').run(pbStepMetadata({ sec: 1_791_860_400, usage: { input: 50, output: 20 } }));
  insDB.close();

  const cliID = '9c462bce-9709-47a1-9655-4ddd39f54270';
  const logDir = join(cliDir, 'brain', cliID, '.system_generated', 'logs');
  await mkdir(logDir, { recursive: true });
  await mkdir(join(cliDir, 'brain', 'tempmediaStorage'), { recursive: true });
  await writeFile(join(logDir, 'transcript_full.jsonl'), [
    { step_index: 0, source: 'USER_EXPLICIT', type: 'USER_INPUT', created_at: '2026-10-25T09:46:59Z', content: '<meta>ctx</meta>\n<USER_REQUEST>\n统计 CLI Token 明细\n第二行\n</USER_REQUEST>' },
    { step_index: 1, source: 'MODEL', type: 'PLANNER_RESPONSE', created_at: '2026-10-25T09:47:05Z', input_tokens: 500, output_tokens: 10, cache_read_tokens: 100 },
    { step_index: 1, source: 'MODEL', type: 'PLANNER_RESPONSE', created_at: '2026-10-25T09:47:08Z', input_tokens: 600, output_tokens: 25, cache_read_tokens: 150 },
  ].map(line => JSON.stringify(line)).join('\n') + '\n');

  const cliConvDB = new DatabaseSync(join(cliDir, 'conversations', `${cliID}.db`));
  cliConvDB.exec('PRAGMA journal_mode = WAL;' + CONV_SCHEMA);
  const cliGen = pbGenMetadata('gemini-4-argon-d', 19, 0);
  cliConvDB.prepare('INSERT INTO gen_metadata (idx, data, size) VALUES (0, ?, ?)').run(cliGen, cliGen.length);
  cliConvDB.close();

  const cliSum = new DatabaseSync(join(cliDir, 'conversation_summaries.db'));
  cliSum.exec('PRAGMA journal_mode = WAL;' + SUMMARY_SCHEMA);
  cliSum.prepare(
    'INSERT INTO conversation_summaries (conversation_id, title, preview, last_modified_time, workspace_uris, app_data_dir) VALUES (?, ?, ?, ?, ?, ?)'
  ).run(sharedID, '跨目录同步摘要', '', '2026-11-07 00:12:46+00:00', '["file:///Volumes/Work/My%20Repo"]', 'antigravity');
  cliSum.close();

  const sessions = await scan([{ source: 'antigravity', path: gemini }]);
  assert.equal(sessions.length, 3);

  const desktop = sessions.find(s => s.home === appDir && s.nativeID === sharedID);
  assert.ok(desktop);
  assert.equal(desktop.source, 'antigravity');
  assert.equal(desktop.title, '实现 Antigravity 会话解析');
  assert.equal(desktop.project, '/Volumes/Work/My Repo');
  assert.equal(desktop.parentID, 'parent-uuid');
  assert.equal('messages' in desktop, false);
  assert.equal('files' in desktop, false);
  assert.equal(desktop.usage.length, 3);
  assert.deepEqual(desktop.usage[0], {
    id: 'resp_same',
    time: 1_791_860_318_500,
    model: 'gemini-3.8-flash',
    input: 120,
    output: 45,
    cacheWrite: 50,
    cacheRead: 200,
  });
  assert.equal(desktop.usage[1].model, 'gemini-4-neon');
  assert.equal(desktop.usage[1].input, 80);
  assert.equal(desktop.usage[1].cacheRead, 400);
  assert.equal(desktop.usage[2].model, 'gemini-4-carbon');
  assert.equal(desktop.usage[2].input, 90);
  assert.equal(desktop.usage[2].output, 15);
  assert.equal(desktop.usage[2].cacheRead, 300);

  const insiders = sessions.find(s => s.home === insidersDir && s.nativeID === sharedID);
  assert.ok(insiders);
  assert.notEqual(insiders.id, desktop.id);
  assert.equal(insiders.usage[0].model, '');

  const cli = sessions.find(s => s.home === cliDir && s.nativeID === cliID);
  assert.ok(cli);
  assert.equal(cli.title, '统计 CLI Token 明细 第二行');
  assert.equal(cli.usage.length, 1);
  assert.equal(cli.usage[0].model, 'gemini-4-argon');
  assert.equal(cli.usage[0].input, 600);
  assert.equal(cli.usage[0].output, 25);
  assert.equal(cli.usage[0].cacheRead, 150);

  const direct = await scan([{ source: 'antigravity', path: appDir }]);
  assert.equal(direct.length, 1);
  assert.equal(direct[0].id, desktop.id);
  assert.equal(direct[0].home, appDir);
});

test('Antigravity reads read-only closed WAL databases and live uncheckpointed WAL files without writing to source', async t => {
  const root = await tempRoot(t, 'antigravity-wal-');
  const readonlyApp = join(root, 'ro-app');
  const convDir = join(readonlyApp, 'conversations');
  await mkdir(convDir, { recursive: true });
  const roID = '11111111-2222-4333-8444-555555555555';
  const roDB = new DatabaseSync(join(convDir, `${roID}.db`));
  roDB.exec('PRAGMA journal_mode = WAL;' + CONV_SCHEMA);
  roDB.prepare('INSERT INTO steps (idx, step_type, metadata) VALUES (1, 15, ?)').run(pbStepMetadata({ sec: 1_790_000_100, usage: { input: 30, output: 12 } }));
  roDB.close();
  await chmod(convDir, 0o555);
  await chmod(readonlyApp, 0o555);
  try {
    const roSessions = await scan([{ source: 'antigravity', path: readonlyApp }]);
    assert.equal(roSessions.length, 1);
    assert.equal(roSessions[0].usage[0].input, 30);
    assert.deepEqual(await readdir(convDir), [`${roID}.db`]);
  } finally {
    await chmod(readonlyApp, 0o755).catch(() => {});
    await chmod(convDir, 0o755).catch(() => {});
  }

  const liveApp = join(root, 'live-app');
  await mkdir(join(liveApp, 'conversations'), { recursive: true });
  const liveID = '22222222-3333-4444-8555-666666666666';
  const stableID = '33333333-4444-4555-8666-777777777777';
  const liveConvPath = join(liveApp, 'conversations', `${liveID}.db`);
  const stableConvPath = join(liveApp, 'conversations', `${stableID}.db`);
  const liveSumPath = join(liveApp, 'conversation_summaries.db');
  const writerConv = new DatabaseSync(liveConvPath);
  const stableConv = new DatabaseSync(stableConvPath);
  const writerSum = new DatabaseSync(liveSumPath);
  t.after(() => { writerConv.close(); writerSum.close(); });
  writerConv.exec('PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0;' + CONV_SCHEMA);
  stableConv.exec('PRAGMA journal_mode = WAL;' + CONV_SCHEMA);
  stableConv.prepare('INSERT INTO steps (idx, step_type, metadata) VALUES (1, 15, ?)').run(pbStepMetadata({ sec: 1_790_000_150, usage: { input: 10, output: 5 } }));
  stableConv.close();
  writerSum.exec('PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0;' + SUMMARY_SCHEMA);
  writerConv.prepare('INSERT INTO steps (idx, step_type, metadata) VALUES (1, 15, ?)').run(pbStepMetadata({ sec: 1_790_000_200, usage: { input: 40, output: 15 } }));
  const insertLiveSummary = writerSum.prepare(
    'INSERT INTO conversation_summaries (conversation_id, title, preview, last_modified_time, workspace_uris) VALUES (?, ?, ?, ?, ?)'
  );
  insertLiveSummary.run(liveID, '未检查点标题', '', '2026-11-24 12:00:00+00:00', '["file:///work/live"]');
  insertLiveSummary.run(stableID, '未变标题', '', '2026-11-24 11:00:00+00:00', '["file:///work/stable"]');
  assert.ok((await stat(`${liveConvPath}-wal`)).size > 0);
  assert.ok((await stat(`${liveSumPath}-wal`)).size > 0);

  const emitted: string[] = [];
  const locations = [{ source: 'antigravity' as const, path: liveApp }];
  await scan(locations, session => { emitted.push(`${session.title}:${session.usage.length}`); });
  assert.deepEqual(emitted.sort(), ['未变标题:1', '未检查点标题:1']);

  emitted.length = 0;
  await scan(locations, session => { emitted.push(session.title); });
  assert.deepEqual(emitted, [] as string[]);

  writerSum.prepare('UPDATE conversation_summaries SET title = ? WHERE conversation_id = ?').run('更新后的 WAL 标题', liveID);
  await scan(locations, session => { emitted.push(session.title); });
  assert.deepEqual(emitted, ['更新后的 WAL 标题']);
});

test('runtime initialize and scan accept antigravity locations', { timeout: 10000 }, async t => {
  const root = await tempRoot(t, 'antigravity-runtime-');
  const appDir = join(root, 'gemini', 'antigravity');
  await mkdir(join(appDir, 'conversations'), { recursive: true });
  const id = '44444444-5555-4666-8777-888888888888';
  const db = new DatabaseSync(join(appDir, 'conversations', `${id}.db`));
  db.exec('PRAGMA journal_mode = WAL;' + CONV_SCHEMA);
  db.prepare('INSERT INTO steps (idx, step_type, metadata) VALUES (1, 15, ?)').run(pbStepMetadata({ sec: 1_790_000_300, usage: { input: 70, output: 30 } }));
  db.close();

  const child = spawn(process.execPath, [join(import.meta.dirname, '../src/main.ts'), '--data-dir', join(root, 'data')]);
  t.after(() => { child.kill(); });
  const output = createInterface({ input: child.stdout });
  child.stdin.write([
    { id: 1, method: 'initialize' },
    { id: 2, method: 'scan', params: { locations: [{ source: 'antigravity', path: join(root, 'gemini') }] } },
  ].map(v => JSON.stringify(v)).join('\n') + '\n');

  const responses = new Map<number, Record<string, unknown>>();
  const sessions: Record<string, unknown>[] = [];
  for await (const line of output) {
    const value = object(JSON.parse(line));
    if (typeof value.id === 'number') responses.set(value.id, value);
    else if (value.event === 'session') sessions.push(object(value.data));
    if (responses.size === 2) break;
  }
  const initLocations = (object(responses.get(1)?.result).locations ?? []) as Array<Record<string, unknown>>;
  assert.ok(initLocations.some(item => item.source === 'antigravity'));
  assert.equal(object(responses.get(2)?.result).count, 1);
  assert.equal(sessions.length, 1);
  assert.equal(sessions[0].source, 'antigravity');
});
