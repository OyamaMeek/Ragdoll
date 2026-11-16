import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, writeFile, readFile, rm } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { randomUUID } from 'node:crypto';
import { ClientTools } from '../src/client-tools.ts';
import { Agents, defaultAgents } from '../src/agents.ts';
import { registry, install } from '../src/registry.ts';
import type { Session } from '../src/types.ts';

const directory = () => resolve(import.meta.dirname, '../../.agent/tests', randomUUID());

test('client terminal cleanup kills a real process that ignores SIGTERM', { timeout: 10000 }, async () => {
  const root = directory(); await mkdir(root, { recursive: true });
  const tools = new ClientTools(root, async () => ({ allowed: true }));
  try {
    const terminal = await tools.handle('terminal/create', { command: process.execPath, args: ['-e', 'process.on("SIGTERM",()=>{});console.log("ready");setInterval(()=>{},1000)'] }) as { terminalId: string };
    const deadline = Date.now() + 3000;
    while (true) {
      const output = await tools.handle('terminal/output', terminal) as { output: string };
      if (output.output.includes('ready')) break;
      if (Date.now() > deadline) throw new Error('real terminal did not start');
      await new Promise(resolve => setTimeout(resolve, 20));
    }
    const exited = tools.handle('terminal/wait_for_exit', terminal);
    await tools.close();
    assert.equal((await exited as { signal: string }).signal, 'SIGKILL');
  } finally { await tools.close(); await rm(root, { recursive: true, force: true }); }
});

test('client filesystem permissions reject writes and paths outside the project', async () => {
  const root = directory(); await mkdir(root, { recursive: true });
  await writeFile(join(root, 'existing.txt'), 'original');
  const tools = new ClientTools(root, async () => ({ allowed: false }));
  try {
    assert.deepEqual(await tools.handle('fs/read_text_file', { path: 'existing.txt' }), { content: 'original' });
    await assert.rejects(tools.handle('fs/write_text_file', { path: 'existing.txt', content: 'replaced' }), /拒绝/);
    await assert.rejects(tools.handle('fs/read_text_file', { path: '/etc/passwd' }), /授权范围/);
    assert.equal(await readFile(join(root, 'existing.txt'), 'utf8'), 'original');
  } finally { tools.close(); await rm(root, { recursive: true, force: true }); }
});

test('real Codex app-server initializes and lists models without sending a prompt', { skip: process.env.RAGDOLL_INTEGRATION !== '1', timeout: 60000 }, async () => {
  const root = directory(); await mkdir(root, { recursive: true });
  const agents = new Agents(root, () => {}, async () => ({ allowed: false }));
  try {
    const codex = (await defaultAgents()).find(a => a.kind === 'codex')!;
    const result = await agents.probe(codex, resolve(import.meta.dirname, '../..'));
    assert.ok(result.models);
  } finally { await agents.close(); await rm(root, { recursive: true, force: true }); }
});

test('official registry installs a real Claude ACP binary and negotiates its protocol', { skip: process.env.RAGDOLL_REGISTRY_INTEGRATION !== '1', timeout: 240000 }, async () => {
  const root = resolve(import.meta.dirname, '../../.agent/registry-integration');
  await mkdir(root, { recursive: true });
  const entry = (await registry()).find(a => a.id === 'claude-acp'); assert.ok(entry);
  const config = await install(entry, join(root, 'tools'));
  const agents = new Agents(join(root, 'sessions'), () => {}, async () => ({ allowed: false }));
  try {
    const result = await agents.probe(config, resolve(import.meta.dirname, '../..'));
    assert.ok(result.protocolVersion === 1 || result.protocolVersion === 2);
    assert.ok(result.info || result.agentInfo);
  } finally { await agents.close(); }
});

for (const kind of ['codex', 'claude', 'dsh', 'dsh-acp']) {
  test(`real ${kind} conversations persist and resume their native history`, { skip: process.env.RAGDOLL_LIVE_CHAT !== kind, timeout: 180000 }, async () => {
    const root = directory(); await mkdir(root, { recursive: true });
    const agents = new Agents(join(root, 'cache'), () => {}, async () => ({ allowed: false }));
    try {
      const base = (await defaultAgents()).find(a => a.kind === (kind === 'dsh-acp' ? 'dsh' : kind))!;
      const config = kind === 'dsh-acp' ? { ...base, id: 'test-dsh-acp', kind: 'acp' as const, args: ['--profile', 'acp'] } : base;
      const probe = kind === 'codex' ? await agents.probe(config, root) : undefined;
      const models = probe && typeof probe.models === 'object' ? (probe.models as { data: { model: string; isDefault: boolean }[] }).data : [];
      const model = models.find(m => m.isDefault)?.model;
      const opened = await agents.start({ agent: config, cwd: root, ...(model ? { model } : {}) });
      const first = opened.session as Session;
      await agents.send(first.id, 'Remember the code RAGDOLL_CHECK_1729. Reply only OK. Do not inspect files or use any tools.', model);
      const saved = (await agents.saved()).find(s => s.id === first.id)!;
      assert.ok(saved.messages.some(m => m.role === 'assistant' && m.text.length > 0));
      await agents.stop(first.id);
      const resumed = await agents.start({ agent: config, cwd: root, session: saved, ...(model ? { model } : {}) });
      assert.equal((resumed.session as Session).nativeID, saved.nativeID);
      await agents.send(first.id, 'Return only the code I asked you to remember. Do not use tools.', model);
      const last = (await agents.saved()).find(s => s.id === first.id)!;
      assert.ok(last.messages.filter(m => m.role === 'assistant').at(-1)?.text.includes('RAGDOLL_CHECK_1729'));
    } finally { await agents.close(); }
  });
}
