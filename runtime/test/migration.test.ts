import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, readFile, writeFile, rm, symlink, readdir, access } from 'node:fs/promises';
import { join, resolve, dirname } from 'node:path';
import { randomUUID } from 'node:crypto';
import { migrateSession, publishNativeHistory } from '../src/migration.ts';
import { parseFile, defaultLocations } from '../src/logs.ts';
import { Agents, defaultAgents } from '../src/agents.ts';
import { object } from '../src/types.ts';

async function sourceFile(root: string, kind = 'codex'): Promise<string> {
  const path = kind === 'dsh' ? join(root, 'sessions/source/session.v3.jsonl') : join(root, 'sessions/source.jsonl');
  await mkdir(dirname(path), { recursive: true }); return path;
}

test('native migration preserves complete tool records and leaves source unchanged', async () => {
  const root = resolve(import.meta.dirname, '../../.agent/tests', randomUUID());
  await mkdir(root, { recursive: true });
  const path = await sourceFile(root, 'dsh');
  const privateFile = join(root, 'private.key'); await writeFile(privateFile, 'MUST_NOT_COPY');
  const original = [
    { type: 'session', version: 3, id: 'source', cwd: root, createdAt: 1800000000000 },
    { type: 'user/message', seq: 0, time: 1800000000001, data: { source: { kind: 'user' }, content: 'remember MIGRATE_1729' } },
    { type: 'assistant/message', seq: 1, time: 1800000000002, data: { message: { role: 'assistant', content: [{ type: 'text', text: 'OK' }] } } },
    { type: 'tool/result', seq: 2, time: 1800000000003, data: { result: { opaque: 'keep every byte of this record', url: new URL('file://' + privateFile).href } } },
  ].map(row => JSON.stringify(row)).join('\n') + '\n';
  await writeFile(path, original);
  try {
    const source = await parseFile('dsh', path, root);
    const result = await migrateSession({ session: source, target: { id: 'native-codex', name: 'Codex', kind: 'codex', command: 'codex', args: [], env: {} }, home: join(root, 'target'), cwd: root });
    assert.notEqual(result.nativeID, 'source');
    assert.equal(result.migration?.sourceID, source.id);
    assert.equal(result.usage.length, 0);
    assert.equal(result.files.some(p => p.endsWith('private.key')), false);
    assert.equal(result.messages.filter(m => m.role === 'user' && m.text === 'remember MIGRATE_1729').length, 1);
    assert.equal(result.messages.filter(m => m.text.includes('"role": "assistant"') && m.text.includes('"text": "OK"')).length, 0);
    const text = await readFile(result.files.find(p => p.endsWith('.jsonl'))!, 'utf8');
    assert.match(text, /MIGRATE_1729/);
    assert.match(text, /keep every byte of this record/);
    assert.equal(await readFile(path, 'utf8'), original);
    const parsed = await parseFile('codex', result.files.find(p => p.endsWith('.jsonl'))!, join(root, 'target'));
    assert.equal(parsed.messages.filter(m => m.role === 'assistant').some(m => m.text === 'OK'), true);
    assert.equal(parsed.migration?.sourceID, source.id);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('migration copies attachments and rejects a target history symlink before creating external directories', async t => {
  const root = resolve(import.meta.dirname, '../../.agent/tests', randomUUID());
  await mkdir(root, { recursive: true });
  const path = await sourceFile(root), image = join(root, 'picture.png'), outside = join(root, 'outside'), home = join(root, 'target');
  const json = join(root, 'attachment.json'); await writeFile(json, '[1,2,3]');
  await writeFile(image, new Uint8Array([1, 2, 3, 4]));
  await writeFile(path, [
    { type: 'event_msg', payload: { type: 'user_message', message: 'with attachments', local_images: [image] } },
    { type: 'response_item', payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text: 'with attachments' }, { type: 'localImage', path: image }, { type: 'input_file', file_path: json }] } },
  ].map(row => JSON.stringify(row)).join('\n') + '\n');
  const target = { id: 'native-codex', name: 'Codex', kind: 'codex', command: 'codex', args: [], env: {} };
  try {
    const source = await parseFile('codex', path, root);
    source.files.push(json);
    const migrated = await migrateSession({ session: source, target, home, cwd: root });
    const copy = migrated.files.find(p => p.endsWith('picture.png'))!;
    assert.notEqual(copy, image); assert.deepEqual(await readFile(copy), Buffer.from([1, 2, 3, 4]));
    assert.equal(await readFile(migrated.files.find(p => p.endsWith('attachment.json'))!, 'utf8'), '[1,2,3]');
    assert.equal(migrated.messages.filter(m => m.role === 'user' && m.text === 'with attachments').length, 1);
    const hostile = join(root, 'hostile'); await mkdir(hostile); await mkdir(outside);
    await symlink(outside, join(hostile, 'sessions'));
    await assert.rejects(migrateSession({ session: source, target, home: hostile, cwd: root }), /越界|符号链接/);
    assert.deepEqual(await readdir(outside), []);
    await t.test('attachments survive a second dsh migration', { skip: process.env.RAGDOLL_MIGRATION_LIVE !== 'dsh' }, async () => {
      const second = await migrateSession({ session: migrated, target: { id: 'dsh', kind: 'dsh', command: '/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh', args: ['--profile', 'sdk'], env: {} }, home: join(root, 'second'), cwd: root });
      assert.equal(second.messages.some(m => m.text.includes(copy)), false);
      assert.equal(second.messages.filter(m => m.role === 'user' && m.text === 'with attachments').length, 1);
    });
    await rm(copy);
    await assert.rejects(parseFile('codex', migrated.files.find(p => p.endsWith('.jsonl'))!, home), /ENOENT/);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('migration requires explicit authorization for an external declared attachment', async () => {
  const root = resolve(import.meta.dirname, '../../.agent/tests', randomUUID()); await mkdir(root, { recursive: true });
  const path = await sourceFile(root), image = join(root, 'external.png'), project = join(root, 'project'); await mkdir(project);
  await writeFile(image, Buffer.from([4, 3, 2, 1]));
  await writeFile(path, JSON.stringify({ type: 'event_msg', payload: { type: 'user_message', message: 'an attachment', local_images: [image] } }) + '\n');
  const target = { id: 'test', kind: 'codex', command: 'codex', args: [], env: {} };
  try {
    const source = await parseFile('codex', path, root);
    await assert.rejects(migrateSession({ session: source, target, home: join(root, 'denied'), cwd: project }), /授权/);
    const result = await migrateSession({ session: source, target, home: join(root, 'allowed'), cwd: project, authorizedAttachments: [image] });
    assert.equal(result.files.some(p => p.endsWith('external.png')), true);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('native migration requires raw history and retains configured home identity', async () => {
  const root = resolve(import.meta.dirname, '../../.agent/tests', randomUUID()); await mkdir(root, { recursive: true });
  const path = await sourceFile(root), actual = join(root, 'actual'), alias = join(root, 'alias');
  await mkdir(actual); await symlink(actual, alias);
  await writeFile(path, JSON.stringify({ type: 'response_item', payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text: 'One message' }] } }) + '\n');
  const target = { id: 'test', kind: 'codex', command: 'codex', args: [], env: {} };
  try {
    const source = await parseFile('codex', path, root);
    await assert.rejects(migrateSession({ session: { ...source, files: [] }, target, home: alias + '/', cwd: root }), /原始/);
    const migrated = await migrateSession({ session: source, target, home: alias + '/', cwd: root });
    const scanned = await parseFile('codex', migrated.files.find(p => p.endsWith('.jsonl'))!, alias + '/');
    assert.equal(migrated.id, scanned.id); assert.equal(migrated.home, alias + '/');
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('native publication preserves an existing sidecar and existing target', async () => {
  const root = resolve(import.meta.dirname, '../../.agent/tests', randomUUID()); await mkdir(root, { recursive: true });
  const prepared = join(root, 'prepared'), destination = join(root, 'target.jsonl');
  await writeFile(prepared, 'new history'); await writeFile(destination + '.ragdoll.json', 'existing sidecar');
  try {
    await assert.rejects(publishNativeHistory(prepared, destination, '{}'));
    assert.equal(await readFile(destination + '.ragdoll.json', 'utf8'), 'existing sidecar');
    await assert.rejects(access(destination));
    await writeFile(destination, 'existing native history');
    await assert.rejects(publishNativeHistory(prepared, destination, '{}'));
    assert.equal(await readFile(destination, 'utf8'), 'existing native history');
  } finally { await rm(root, { recursive: true, force: true }); }
});

for (const kind of ['codex', 'dsh'] as const) {
  test(`migrated ${kind} conversation continues with the original context`, { skip: process.env.RAGDOLL_MIGRATION_LIVE !== kind, timeout: 180000 }, async () => {
    const root = resolve(import.meta.dirname, '../../.agent/tests', randomUUID()); await mkdir(root, { recursive: true });
    const sourcePath = await sourceFile(root), home = join(root, 'target'); await mkdir(home);
    await writeFile(sourcePath, [
      { type: 'session_meta', payload: { id: 'source', cwd: root } },
      { type: 'response_item', payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text: 'Remember the secret code NATIVE_HISTORY_7319.' }] } },
      { type: 'response_item', payload: { type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'I remember.' }] } },
    ].map(row => JSON.stringify(row)).join('\n') + '\n');
    const target = (await defaultAgents()).find(a => a.kind === kind)!;
    target.env = { ...target.env, [kind === 'codex' ? 'CODEX_HOME' : 'DSH_HOME']: home };
    if (kind === 'codex') {
      const auth = join(defaultLocations().find(l => l.source === 'codex')!.path, 'auth.json'); await access(auth); await symlink(auth, join(home, 'auth.json'));
    } else {
      const auth = join(defaultLocations().find(l => l.source === 'dsh')!.path, '.credentials.yaml'); await access(auth); await symlink(auth, join(home, '.credentials.yaml'));
    }
    const terminalEvents: unknown[] = [];
    const agents = new Agents(join(root, 'cache'), (event, raw) => {
      if (event !== 'chat') return;
      const data = object(raw), params = object(data.params), native = object(params.event);
      if (native.type === 'turn/end' || String(data.method).includes('error')) terminalEvents.push({ method: data.method, type: native.type, reason: object(native.data).reason });
    }, async () => ({ allowed: false }));
    try {
      const source = await parseFile('codex', sourcePath, root);
      const session = await migrateSession({ session: source, target, home, cwd: root });
      const probe = kind === 'codex' ? await agents.probe(target, root) : undefined;
      const models = probe?.models as { data?: { model: string; isDefault: boolean }[] } | undefined;
      const model = models?.data?.find(m => m.isDefault)?.model;
      await agents.start({ agent: target, session, cwd: root, ...(model ? { model } : {}) });
      await agents.send(session.id, 'Return only the secret code from our earlier conversation. Do not inspect files or use tools.', model);
      const saved = (await agents.saved()).find(s => s.id === session.id)!;
      assert.match(saved.messages.filter(m => m.role === 'assistant').at(-1)!.text, /NATIVE_HISTORY_7319/, JSON.stringify(terminalEvents));
    } finally { await agents.close(); await rm(root, { recursive: true, force: true }); }
  });
}

test('migration refuses malformed raw input before publishing target history', async () => {
  const root = resolve(import.meta.dirname, '../../.agent/tests', randomUUID());
  await mkdir(root, { recursive: true });
  const path = await sourceFile(root); await writeFile(path, '{invalid}\n');
  try {
    await assert.rejects(migrateSession({ session: { id: 'one', nativeID: 'source', home: root, source: 'codex', files: [path], messages: [], usage: [] }, target: { id: 'test', kind: 'codex', command: 'codex', args: [], env: {} }, home: join(root, 'target'), cwd: root }), SyntaxError);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('Codex history becomes a dsh native conversation that the installed tool can resume', { skip: process.env.RAGDOLL_MIGRATION_LIVE !== 'dsh' }, async () => {
  const root = resolve(import.meta.dirname, '../../.agent/tests', randomUUID());
  await mkdir(root, { recursive: true });
  const path = await sourceFile(root);
  await writeFile(path, [
    { type: 'session_meta', payload: { id: 'source', cwd: root } },
    { type: 'response_item', payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text: 'remember DS_NATIVE_1729' }] } },
    { type: 'response_item', payload: { type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'I remember.' }] } },
  ].map(row => JSON.stringify(row)).join('\n') + '\n');
  const agents = new Agents(join(root, 'cache'), () => {}, async () => ({ allowed: false }));
  try {
    const target = { id: 'native-dsh', name: 'dsh', kind: 'dsh' as const, command: '/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh', args: ['--profile', 'sdk'], env: { DEEPSEEK_API_KEY: '' } };
    const source = await parseFile('codex', path, root);
    const result = await migrateSession({ session: source, target, home: join(root, 'target'), cwd: root });
    const resumed = await agents.start({ agent: target, session: result, cwd: root });
    assert.equal((resumed.session as { nativeID: string }).nativeID, result.nativeID);
    await assert.rejects(agents.send(result.id, 'Reply only OK. Do not use tools.'), /no API key|MISSING_CREDENTIAL/);
  } finally { await agents.close(); await rm(root, { recursive: true, force: true }); }
});
