import { createInterface } from 'node:readline';
import { watch } from 'node:fs';
import type { FSWatcher } from 'node:fs';
import { mkdir } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { homedir } from 'node:os';
import { randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { scan, defaultLocations } from './logs.ts';
import { importDesktop } from './desktop.ts';
import { registry, install, uninstall } from './registry.ts';
import { Agents, defaultAgents } from './agents.ts';
import { createTerminalAuth, runTerminalAuth } from './terminal-auth.ts';
import { fileURLToPath } from 'node:url';
import { object, string } from './types.ts';
import type { Data, Location, AgentConfig } from './types.ts';

const dataArg = process.argv.indexOf('--data-dir');
const root = dataArg >= 0 ? resolve(process.argv[dataArg + 1]) : join(homedir(), 'Library/Application Support/Ragdoll');
process.env.RAGDOLL_MAIN_SCRIPT = fileURLToPath(import.meta.url);
const output = (value: unknown) => process.stdout.write(JSON.stringify(value) + '\n');
const emit = (event: string, data: unknown) => output({ event, data });
async function sessionOutput(data: unknown): Promise<void> {
  if (!output({ event: 'session', data })) await once(process.stdout, 'drain');
}
const approvals = new Map<string, { resolve: (value: Data) => void; remove: () => void }>();
const agents = new Agents(join(root, 'conversations'), emit, (method, params, signal) => new Promise(resolve => {
  const requestID = randomUUID();
  const cancel = () => { approvals.delete(requestID); emit('approvalCancelled', { requestID }); resolve({ allowed: false }); };
  if (signal?.aborted) return cancel();
  signal?.addEventListener('abort', cancel, { once: true });
  approvals.set(requestID, { resolve, remove: () => signal?.removeEventListener('abort', cancel) });
  emit('approval', { requestID, method, params });
}));
let watchers: FSWatcher[] = [];
let scanActive = false;
let changeTimer: NodeJS.Timeout | undefined;
function watchLocations(locations: Location[]): void {
  for (const watcher of watchers) watcher.close(); watchers = [];
  for (const location of locations) {
    try {
      const watcher = watch(location.path, { recursive: true }, () => {
        clearTimeout(changeTimer); changeTimer = setTimeout(() => emit('sourceChanged', {}), 1500);
      });
      watcher.on('error', error => emit('warning', `目录监听失败：${String(error)}`));
      watchers.push(watcher);
    } catch (error) { if (object(error).code !== 'ENOENT') emit('warning', `目录监听失败：${String(error)}`); }
  }
}

async function handle(method: string, p: Data): Promise<unknown> {
  if (method === 'initialize') return { version: '0.1.0', locations: defaultLocations(), agents: await defaultAgents() };
  if (method === 'scan') {
    if (scanActive) throw new Error('正在扫描，请稍后重试');
    const locations = p.locations === undefined ? defaultLocations() : p.locations;
    if (!Array.isArray(locations) || locations.some(v => !['codex', 'claude', 'dsh'].includes(string(object(v).source)) || !string(object(v).path))) throw new Error('扫描目录配置无效');
    scanActive = true;
    try {
      watchLocations(locations as Location[]);
      for (const session of await agents.saved()) await sessionOutput(session);
      let count = 0;
      await scan(locations as Location[], async s => { count++; await sessionOutput(s); }, error => emit('warning', error));
      return { count };
    } finally { scanActive = false; }
  }
  if (method === 'import') {
    const sessions = await importDesktop(string(p.path), join(root, 'imports'));
    for (const session of sessions) emit('session', session);
    return { count: sessions.length };
  }
  if (method === 'registry') return registry();
  if (method === 'install') return install(p.agent, join(root, 'tools'));
  if (method === 'uninstall') { await uninstall(p.agent as AgentConfig, join(root, 'tools')); return {}; }
  if (method === 'probe') return agents.probe(p.agent, string(p.cwd, homedir()));
  if (method === 'chat.start') return agents.start(p);
  if (method === 'chat.send') { await agents.send(string(p.id), string(p.text), string(p.model) || undefined, p.attachments ?? []); return {}; }
  if (method === 'chat.stop') { await agents.stop(string(p.id)); return {}; }
  if (method === 'chat.configure') return agents.configure(string(p.id), string(p.configID), string(p.value));
  if (method === 'chat.list') return agents.list(p.agent, string(p.cwd, homedir()), string(p.cursor) || undefined);
  if (method === 'chat.import') return agents.importNative(p.agent, object(p.session), string(p.cwd, homedir()));
  if (method === 'native.login') {
    const agent = p.agent as AgentConfig;
    if (agent.kind !== 'codex' && agent.kind !== 'claude') throw new Error('请使用原应用管理此工具的登录');
    return createTerminalAuth({ ...agent, args: [] }, { args: agent.kind === 'codex' ? ['login'] : ['auth', 'login'] }, homedir(), root);
  }
  if (method === 'authenticate') return agents.authenticate(p.agent, string(p.cwd, homedir()), string(p.methodID));
  if (method === 'approval') {
    const pending = approvals.get(string(p.requestID));
    if (!pending) throw new Error('权限请求已经取消或结束');
    approvals.delete(string(p.requestID)); pending.remove(); pending.resolve(object(p.answer)); return {};
  }
  if (method === 'shutdown') { await agents.close(); for (const watcher of watchers) watcher.close(); return {}; }
  throw new Error(`未知助手方法：${method}`);
}

if (process.argv.includes('--terminal-auth')) {
  try { process.exitCode = await runTerminalAuth(process.argv[process.argv.indexOf('--terminal-auth') + 1]); }
  catch (error) { process.stderr.write(`${String(error)}\n`); process.exitCode = 1; }
} else if (process.argv.includes('--self-check')) {
  output({ status: 'ok', version: '0.1.0', node: process.version, agents: await defaultAgents() });
} else {
  await mkdir(root, { recursive: true });
  const input = createInterface({ input: process.stdin });
  input.on('line', line => {
    let request: Data;
    try {
      request = object(JSON.parse(line));
      if ((typeof request.id !== 'number' && typeof request.id !== 'string') || typeof request.method !== 'string') throw new Error('请求必须包含 id 和 method');
    } catch (error) { output({ id: null, error: { status: 'error', type: 'InvalidRequest', message: String(error), suggestion: '发送有效的 NDJSON 请求' } }); return; }
    void handle(request.method as string, object(request.params)).then(
      result => output({ id: request.id, result }),
      error => output({ id: request.id, error: { status: 'error', type: error instanceof Error ? error.name : 'RuntimeError', message: String(error), suggestion: '检查 Agent 配置、登录状态或运行日志后重试' } }),
    );
  });
  input.on('close', () => {
    for (const approval of approvals.values()) { approval.remove(); approval.resolve({ allowed: false }); }
    for (const watcher of watchers) watcher.close(); clearTimeout(changeTimer);
    void agents.close().finally(() => process.exit(0));
  });
}
