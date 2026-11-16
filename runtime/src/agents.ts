import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { Readable, Writable } from 'node:stream';
import { mkdir, writeFile, rename, appendFile, readdir, readFile, access } from 'node:fs/promises';
import { join, dirname, extname, basename } from 'node:path';
import { pathToFileURL } from 'node:url';
import { homedir } from 'node:os';
import { randomUUID } from 'node:crypto';
import { query } from '@anthropic-ai/claude-agent-sdk';
import type { Query, SDKUserMessage } from '@anthropic-ai/claude-agent-sdk';
import * as acp from '@agentclientprotocol/sdk';
import * as acp2 from '@agentclientprotocol/sdk/experimental/v2';
import { RpcProcess, childEnvironment } from './rpc.ts';
import { ClientTools } from './client-tools.ts';
import type { Ask } from './client-tools.ts';
import { sessionKey, defaultLocations } from './logs.ts';
import { object, string, content, number } from './types.ts';
import { applyUpdate } from './acp-state.ts';
import { createTerminalAuth } from './terminal-auth.ts';
import type { Data, AgentConfig, Session } from './types.ts';

export type Emit = (event: string, data: unknown) => void;
interface AcpPeer {
  request: (method: string, params?: unknown, timeout?: number) => Promise<unknown>;
  notify: (method: string, params?: unknown) => Promise<void>;
  close: () => Promise<void>;
  version: number;
  info: Data;
  closed: Promise<void>;
}
interface AcpApp {
  onRequest(method: '*', handler: (ctx: { method: string; params: unknown; signal: AbortSignal }) => Promise<unknown>): unknown;
  onNotification(method: '*', handler: (ctx: { method: string; params: unknown }) => void): unknown;
  connect(stream: acp.Stream): { close(error?: unknown): void; closed: Promise<void>; agent: {
    request<Response = unknown, Params = unknown>(method: string, params?: Params, options?: { signal: AbortSignal }): Promise<Response>;
    notify(method: string, params?: unknown): Promise<void>;
  } };
}
interface Running {
  session: Session; agent: AgentConfig; busy: boolean; rpc?: RpcProcess; peer?: AcpPeer; claude?: Query;
  turnID?: string; finish?: () => void; tools?: ClientTools; deltaID?: string; replaying?: boolean;
  fail?: (error: Error) => void; importing?: boolean; hasActivity?: boolean; writeQueue?: Promise<void>;
}

export async function defaultAgents(): Promise<AgentConfig[]> {
  const dshBundle = '/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh';
  const dsh = await access(dshBundle).then(() => dshBundle, () => 'dsh');
  return [
    { id: 'native-codex', name: 'Codex', kind: 'codex', command: 'codex', args: [], env: {} },
    { id: 'native-claude', name: 'Claude Code', kind: 'claude', command: 'claude', args: [], env: {} },
    { id: 'native-dsh', name: 'DeepSeek Harness', kind: 'dsh', command: dsh, args: ['--profile', 'sdk'], env: {} },
  ];
}

function validateConfig(value: unknown): AgentConfig {
  const c = object(value);
  if (!string(c.id) || !string(c.command) || !['codex', 'claude', 'dsh', 'acp'].includes(string(c.kind)) || !Array.isArray(c.args) || c.args.some(x => typeof x !== 'string')) throw new Error('Agent 配置无效');
  for (const [name, value] of Object.entries(object(c.env))) if (!/^[a-zA-Z_][a-zA-Z0-9_]*$/.test(name) || typeof value !== 'string') throw new Error('环境变量必须是有效名称和文本值');
  return c as unknown as AgentConfig;
}

async function openAcp(agent: AgentConfig, cwd: string, ask: Ask, emit: (method: string, params: Data) => void, tools: ClientTools): Promise<AcpPeer> {
  async function connect(version: number): Promise<AcpPeer> {
    const child = spawn(agent.command, agent.args, { cwd, env: childEnvironment(agent.env), stdio: 'pipe', detached: true });
    let stderr = '';
    child.stderr.on('data', data => { stderr = (stderr + String(data)).slice(-3000); });
    const sdk = version === 2 ? acp2 : acp;
    const app = sdk.client({ name: 'Ragdoll' }) as unknown as AcpApp;
    app.onNotification('*', ctx => emit(ctx.method, object(ctx.params)));
    app.onRequest('*', async ctx => {
      const params = object(ctx.params);
      if (ctx.method === 'session/request_permission') {
        const answer = await ask(ctx.method, params, ctx.signal);
        const options = Array.isArray(params.options) ? params.options.map(object) : [];
        const chosen = options.find(o => o.optionId === answer.optionId) ?? options.find(o => answer.allowed === true ? o.kind === 'allow_once' : o.kind === 'reject_once');
        return chosen ? { outcome: { outcome: 'selected', optionId: chosen.optionId } } : { outcome: { outcome: 'cancelled' } };
      }
      if (ctx.method.includes('elicitation')) {
        const answer = await ask(ctx.method, params, ctx.signal);
        return { action: answer.allowed === true ? 'accept' : 'cancel', content: answer.content ?? {} };
      }
      return tools.handle(ctx.method, params, ctx.signal);
    });
    const stream = sdk.ndJsonStream(Writable.toWeb(child.stdin), Readable.toWeb(child.stdout) as ReadableStream<Uint8Array>);
    let mismatch: Error | undefined;
    const readable = stream.readable.pipeThrough(new TransformStream({ transform(message, controller) {
      const result = object(object(message).result);
      if (typeof result.protocolVersion === 'number' && result.protocolVersion !== version) {
        mismatch = new Error(`ACP_PROTOCOL_MISMATCH:${result.protocolVersion}`); controller.error(mismatch); return;
      }
      controller.enqueue(message);
    } }));
    const connection = app.connect({ writable: stream.writable, readable });
    child.on('error', error => connection.close(error));
    child.on('exit', code => connection.close(new Error(`ACP 进程退出 (${code})：${stderr}`)));
    const request = (method: string, params?: unknown, timeout = 30000) => connection.agent.request<unknown, unknown>(method, params, timeout > 0 ? { signal: AbortSignal.timeout(timeout) } : undefined);
    const close = async () => {
      connection.close(); child.stdin.end();
      if (child.pid && child.exitCode === null && child.signalCode === null) {
        const pid = child.pid;
        try { process.kill(-pid, 'SIGTERM'); } catch {}
        const timer = setTimeout(() => { try { process.kill(-pid, 'SIGKILL'); } catch {} }, 3000); timer.unref();
        await new Promise<void>(resolve => { if (child.exitCode !== null || child.signalCode !== null) resolve(); else child.once('exit', () => resolve()); });
        clearTimeout(timer);
      }
    };
    try {
      const info = object(await request('initialize', version === 2
        ? { protocolVersion: 2, info: { name: 'ragdoll', version: '0.1.0' }, capabilities: { auth: { terminal: {} } } }
        : { protocolVersion: 1, clientInfo: { name: 'ragdoll', version: '0.1.0' }, clientCapabilities: { fs: { readTextFile: true, writeTextFile: true }, terminal: true, auth: { terminal: {} } } }));
      if (number(info.protocolVersion) !== version) throw new Error(`ACP_PROTOCOL_MISMATCH:${info.protocolVersion}`);
      return { request, notify: (m, p) => connection.agent.notify(m, p), close, version, info, closed: connection.closed };
    } catch (error) { await close(); throw mismatch ?? error; }
  }
  try { return await connect(agent.protocol ?? 2); }
  catch (error) {
    if (!agent.protocol && /ACP_PROTOCOL_MISMATCH|protocol.?version|unsupported.*version|-32602|-32022/i.test(String(error))) return connect(1);
    throw error;
  }
}

export class Agents {
  private running = new Map<string, Running>();
  private root: string;
  private emit: Emit;
  private ask: Ask;
  constructor(root: string, emit: Emit, ask: Ask) { this.root = root; this.emit = emit; this.ask = ask; }

  async saved(): Promise<Session[]> {
    await mkdir(this.root, { recursive: true });
    const entries = await readdir(this.root, { withFileTypes: true });
    const sessions: Session[] = [];
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      try {
        const v = object(JSON.parse(await readFile(join(this.root, entry.name, 'session.json'), 'utf8')));
        if (typeof v.id === 'string' && Array.isArray(v.messages) && Array.isArray(v.usage)) sessions.push(v as unknown as Session);
      } catch (error) { if (object(error).code !== 'ENOENT') this.emit('warning', `会话缓存无法读取：${String(error)}`); }
    }
    return sessions;
  }
  private async persist(r: Running): Promise<void> {
    await r.writeQueue;
    const dir = join(this.root, sessionKey('chat', r.session.id));
    await mkdir(dir, { recursive: true });
    r.session.updated = Date.now();
    if (r.session.source === 'acp') r.session.files = [...new Set([join(dir, 'events.jsonl'), ...r.session.files])];
    const path = join(dir, 'session.json');
    await writeFile(path + '.writing', JSON.stringify(r.session)); await rename(path + '.writing', path);
    this.emit('session', r.session);
  }
  private update(r: Running, method: string, params: Data): void {
    const id = r.session.id;
    this.emit('chat', { conversationID: id, method, params });
    if (params.sessionId && params.sessionId !== r.session.nativeID) return;
    if (r.replaying && !r.importing) return;
    if (method === 'item/agentMessage/delta') this.delta(r, string(params.delta), string(params.itemId) || undefined);
    if (method === 'turn/started') r.turnID = string(object(params.turn).id);
    if (method === 'turn/completed') {
      const turn = object(params.turn);
      if (turn.status === 'failed') r.fail?.(new Error(string(object(turn.error).message, 'Codex 执行失败')));
      else r.finish?.();
    }
    if (method === 'session/update') {
      const update = object(params.update);
      const type = string(update.sessionUpdate ?? update.type);
      if (!type.startsWith('user_') || r.importing) {
        const role = type.startsWith('user_') ? 'user' : 'assistant';
        if (type.includes('message') && r.session.messages.find(m => m.id === r.deltaID)?.role !== role) r.deltaID = undefined;
        r.deltaID ||= randomUUID();
        const outcome = applyUpdate(r.session, update, r.deltaID);
        if (type === 'state_update' && (update.state === 'running' || update.state === 'requires_action')) r.hasActivity = true;
        if (type.startsWith('agent_message')) r.hasActivity = true;
        if (outcome.idle && r.hasActivity && !r.replaying) {
          if (update.stopReason === 'error') r.fail?.(new Error(content(update.error ?? update.message) || 'ACP Agent 执行失败'));
          else r.finish?.();
        }
        if (type.startsWith('agent_message') && !r.importing) {
          const message = r.session.messages.find(m => m.id === string(update.messageId, r.deltaID));
          if (message) this.emit('delta', { conversationID: id, message });
        }
        if (type.startsWith('tool_')) r.deltaID = undefined;
      }
      if (type === 'config_option_update' || type === 'config_options_update' || type === 'available_commands_update') this.emit('agentConfiguration', { agentID: r.agent.id, conversationID: id, update });
      if (type.includes('usage')) {
        const value = object(update.usage ?? update);
        if (typeof value.inputTokens === 'number' && typeof value.outputTokens === 'number') {
          const usageID = string(value.id, `${id}:turn:${r.session.messages.filter(m => m.role === 'user').length}`);
          const u = { id: usageID, time: Date.now(), model: string(value.model), input: number(value.inputTokens), output: number(value.outputTokens), cacheRead: number(value.cachedReadTokens), cacheWrite: number(value.cachedWriteTokens) };
          const old = r.session.usage.findIndex(u => u.id === usageID);
          if (old < 0) r.session.usage.push(u); else r.session.usage[old] = u;
        }
      }
      const dir = join(this.root, sessionKey('chat', id));
      r.writeQueue = (r.writeQueue ?? Promise.resolve()).then(async () => { await mkdir(dir, { recursive: true }); await appendFile(join(dir, 'events.jsonl'), JSON.stringify({ time: Date.now(), method, params }) + '\n'); });
      void r.writeQueue.catch(error => this.emit('warning', `会话事件保存失败：${String(error)}`));
    }
    if (method === 'session.event') {
      const e = object(params.event), d = object(e.data), message = object(d.message);
      if (e.type === 'assistant/delta') this.delta(r, string(d.text ?? d.delta));
      if (e.type === 'assistant/message') {
        const text = content(message.content ?? d.content);
        if (text) {
          const existing = r.session.messages.find(m => m.id === r.deltaID);
          if (existing) existing.text = text;
          else r.session.messages.push({ id: randomUUID(), role: 'assistant', text, time: Date.now(), kind: 'text' });
        }
        r.deltaID = undefined;
      }
    }
    if (method === 'session.status' && (params.status === 'idle' || object(params.status).status === 'idle')) r.finish?.();
  }
  private delta(r: Running, text: string, preferredID?: string): void {
    if (!text) return;
    if (preferredID && r.deltaID !== preferredID) r.deltaID = preferredID;
    r.deltaID ||= randomUUID();
    if (!r.session.messages.some(m => m.id === r.deltaID)) r.session.messages.push({ id: r.deltaID, role: 'assistant', text: '', time: Date.now(), kind: 'text' });
    const message = r.session.messages.find(m => m.id === r.deltaID)!; message.text += text;
    this.emit('delta', { conversationID: r.session.id, message });
  }

  async probe(agentValue: unknown, cwd: string): Promise<Data> {
    const agent = validateConfig(agentValue);
    if (agent.kind === 'acp') {
      const tools = new ClientTools(cwd, this.ask);
      const peer = await openAcp(agent, cwd, this.ask, (m, p) => this.emit('agentEvent', { agentID: agent.id, method: m, params: p }), tools);
      try { return { ...peer.info, protocolVersion: peer.version }; } finally { await peer.close(); await tools.close(); }
    }
    if (agent.kind === 'codex') {
      const rpc = new RpcProcess(agent.command, [...agent.args, 'app-server'], cwd, agent.env);
      try {
        const info = object(await rpc.request('initialize', { clientInfo: { name: 'ragdoll', version: '0.1.0' }, capabilities: { experimentalApi: true } }));
        rpc.notify('initialized');
        const models = await rpc.request('model/list', {});
        return { ...info, models };
      } finally { await rpc.close(); }
    }
    if (agent.kind === 'dsh') {
      const rpc = new RpcProcess(agent.command, agent.args, cwd, agent.env);
      try { return object(await rpc.request('initialize', { cwd, provider: 'deepseek-official', model: 'deepseek-v4-flash', maxTokens: 32768, approvalRequests: true })); }
      finally { await rpc.close(); }
    }
    const result = await promisify(execFile)(agent.command, ['--version'], { cwd, env: childEnvironment(agent.env), timeout: 15000 });
    return { name: 'Claude Code', version: result.stdout.trim() };
  }

  async start(value: Data): Promise<Data> {
    const agent = validateConfig(value.agent), cwd = string(value.cwd, homedir());
    await access(cwd);
    const prior = value.session ? object(value.session) as unknown as Session : undefined;
    if (prior && this.running.has(prior.id)) return { session: this.running.get(prior.id)!.session };
    if (prior && prior.source !== 'acp' && prior.source !== agent.kind) throw new Error('此历史会话必须使用原始工具恢复');
    if (prior?.instanceID && prior.instanceID !== agent.id) throw new Error('此会话属于其他 Agent 实例');
    const homeKey = agent.kind === 'codex' ? 'CODEX_HOME' : agent.kind === 'claude' ? 'CLAUDE_CONFIG_DIR' : 'DSH_HOME';
    const home = prior?.home || agent.env[homeKey] || defaultLocations().find(l => l.source === agent.kind)?.path || '';
    if (agent.kind !== 'acp' && home) agent.env = { ...agent.env, [homeKey]: home };
    const session: Session = prior ? structuredClone(prior) : {
      id: `chat:${randomUUID()}`, nativeID: '', source: agent.kind, instanceID: agent.id,
      title: '新对话', project: cwd, home, created: Date.now(), updated: Date.now(), messages: [], usage: [], files: [], warnings: [],
    };
    const r: Running = { session, agent, busy: false };
    let info: Data = {};
    if (agent.kind === 'codex') {
      const rpc = new RpcProcess(agent.command, [...agent.args, 'app-server'], cwd, agent.env); r.rpc = rpc;
      rpc.onNotification = (m, p) => this.update(r, m, p);
      rpc.onExit = message => r.fail?.(new Error(message));
      rpc.onRequest = async (method, params) => {
        const answer = await this.ask(method, { ...params, conversationID: session.id });
        if (method.includes('requestUserInput')) return { answers: answer.answers ?? {} };
        return { decision: answer.allowed === true ? 'accept' : 'decline' };
      };
      try {
        await rpc.request('initialize', { clientInfo: { name: 'ragdoll', version: '0.1.0' }, capabilities: { experimentalApi: true } }); rpc.notify('initialized');
        info = object(await rpc.request(prior ? 'thread/resume' : 'thread/start', { ...(prior ? { threadId: prior.nativeID } : {}), cwd, approvalPolicy: 'on-request', sandbox: 'workspace-write', ...(value.model ? { model: value.model } : {}) }));
        info = { ...info, models: await rpc.request('model/list', {}) };
        const catalog = object(info.models).data;
        if (!value.model && typeof info.model === 'string' && Array.isArray(catalog) && !catalog.some(m => object(m).model === info.model)) session.warnings.push('当前配置模型未出现在工具的可用目录中，请从模型菜单选择可用模型后发送。');
        const id = string(object(info.thread).id);
        if (!id) throw new Error('Codex 返回的会话缺少 ID');
        session.nativeID = id;
      } catch (error) { await rpc.close(); throw error; }
    }
    if (agent.kind === 'dsh') {
      const rpc = new RpcProcess(agent.command, agent.args, cwd, agent.env); r.rpc = rpc;
      rpc.onNotification = (m, p) => this.update(r, m, p);
      rpc.onExit = message => r.fail?.(new Error(message));
      rpc.onRequest = async (method, params) => {
        const answer = await this.ask(method, { ...params, conversationID: session.id });
        if (method === 'approval/request') return { outcome: answer.allowed === true ? 'allowed-once' : 'rejected' };
        return answer.allowed === true ? { answers: answer.answers ?? [] } : { cancelled: true };
      };
      try {
        info = object(await rpc.request('initialize', { cwd, provider: session.provider || 'deepseek-official', model: string(value.model, session.usage.at(-1)?.model || 'deepseek-v4-flash'), maxTokens: 32768, approvalRequests: true, capabilities: { userQuestions: true } }));
        session.nativeID ||= randomUUID();
        if (prior) await rpc.request('session/resume', { sessionId: session.nativeID });
      } catch (error) { await rpc.close(); throw error; }
    }
    if (agent.kind === 'acp') {
      const ask: Ask = (m, p, signal) => { if (r.busy) r.hasActivity = true; return this.ask(m, { ...p, conversationID: session.id }, signal); };
      r.tools = new ClientTools(cwd, ask);
      const peer = await openAcp(agent, cwd, ask, (m, p) => this.update(r, m, p), r.tools); r.peer = peer;
      try {
        if (prior) {
          const capabilities = object(peer.info.agentCapabilities ?? peer.info.capabilities);
          const sessions = object(capabilities.session ?? capabilities.sessionCapabilities);
          if (peer.version === 2 ? capabilities.session == null : capabilities.loadSession !== true && !sessions.resume) throw new Error('此 ACP Agent 未声明历史恢复能力；已保存的会话仍可浏览和归档');
          r.replaying = true;
          r.importing = prior.messages.length === 0;
          info = object(await peer.request(peer.version === 1 && capabilities.loadSession === true ? 'session/load' : 'session/resume', { sessionId: prior.nativeID, cwd, mcpServers: [], ...(peer.version === 2 && r.importing ? { replayFrom: { type: 'start' } } : {}) }));
          r.replaying = false;
          r.importing = false;
        } else {
          info = object(await peer.request('session/new', { cwd, mcpServers: [] }));
          session.nativeID = string(info.sessionId);
          if (!session.nativeID) throw new Error('ACP Agent 返回的会话缺少 ID');
        }
      } catch (error) { await peer.close(); await r.tools.close(); throw error; }
      info = { ...peer.info, ...info, protocolVersion: peer.version };
    }
    if (agent.kind === 'claude') { session.nativeID ||= randomUUID(); session.nativeStarted = prior ? prior.nativeStarted ?? true : false; }
    if (!prior) session.id = sessionKey(agent.kind, `${agent.kind === 'acp' ? agent.id : home}\0${session.nativeID}`);
    if (agent.kind === 'acp') {
      const nativeSource = agent.registryID === 'codex-acp' ? 'codex' : agent.registryID === 'claude-acp' ? 'claude' : /(?:^|\/)dsh$/.test(agent.command) && agent.args.includes('acp') ? 'dsh' : undefined;
      if (nativeSource) {
        session.nativeSource = nativeSource;
        const key = nativeSource === 'codex' ? 'CODEX_HOME' : nativeSource === 'claude' ? 'CLAUDE_CONFIG_DIR' : 'DSH_HOME';
        session.home = agent.env[key] || defaultLocations().find(l => l.source === nativeSource)?.path || '';
      }
    }
    session.instanceID = agent.id;
    this.running.set(session.id, r);
    await this.persist(r);
    return { session, info };
  }

  async send(id: string, text: string, model?: string, attachments: unknown = []): Promise<void> {
    const r = this.running.get(id);
    if (!r) throw new Error('请先打开或恢复会话');
    if (r.busy) throw new Error('此会话正在执行，请等待或停止当前执行');
    if (!text.trim()) throw new Error('消息不能为空');
    if (!Array.isArray(attachments) || attachments.some(p => typeof p !== 'string')) throw new Error('附件列表无效');
    const files = await Promise.all((attachments as string[]).map(async path => {
      const mime = ({ '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.webp': 'image/webp', '.gif': 'image/gif' } as Record<string, 'image/png' | 'image/jpeg' | 'image/webp' | 'image/gif'>)[extname(path).toLowerCase()];
      if (mime) {
        const data = await readFile(path);
        if (data.length > 20 * 1024 * 1024) throw new Error('单张图片不能超过 20 MiB');
        return { path, mime, data: data.toString('base64') };
      }
      await access(path); return { path, mime: undefined, data: undefined };
    }));
    if (r.peer && files.some(f => f.mime)) {
      const capabilities = object(r.peer.info.agentCapabilities ?? r.peer.info.capabilities);
      const prompts = object(r.peer.version === 2 ? object(capabilities.session).prompt : capabilities.promptCapabilities);
      if (prompts.image !== true) throw new Error('此 ACP Agent 未声明图片输入能力');
    }
    const visibleText = text + (files.length ? '\n\n' + files.map(f => `[附件：${basename(f.path)}](${pathToFileURL(f.path).href})`).join('\n') : '');
    const withPaths = text + (files.some(f => !f.mime) ? '\n\n附件路径：\n' + files.filter(f => !f.mime).map(f => f.path).join('\n') : '');
    r.busy = true; r.deltaID = undefined; r.hasActivity = false;
    r.session.files = [...new Set([...r.session.files, ...files.map(f => f.path)])];
    r.session.messages.push({ id: randomUUID(), role: 'user', text: visibleText, time: Date.now(), kind: 'text' });
    if (r.session.title === '新对话') r.session.title = text.slice(0, 80);
    await this.persist(r); this.emit('state', { conversationID: id, state: 'running' });
    try {
      if (r.peer) {
        if (model) await r.peer.request('session/set_config_option', { sessionId: r.session.nativeID, configId: 'model', value: model, ...(r.peer.version === 2 ? { type: 'id' } : {}) });
        const completed = new Promise<void>((resolve, reject) => { r.finish = resolve; r.fail = reject; });
        const blocks = files.map(f => f.mime ? { type: 'image', data: f.data, mimeType: f.mime } : { type: 'resource_link', uri: pathToFileURL(f.path).href, name: basename(f.path) });
        await r.peer.request('session/prompt', { sessionId: r.session.nativeID, prompt: [{ type: 'text', text }, ...blocks] }, 0);
        if (r.peer.version === 2) await Promise.race([completed, r.peer.closed.then(() => { throw new Error('ACP 连接中断，运行结果尚未确认'); })]);
      } else if (r.agent.kind === 'codex') {
        const completed = new Promise<void>((resolve, reject) => { r.finish = resolve; r.fail = reject; });
        const result = object(await r.rpc!.request('turn/start', { threadId: r.session.nativeID, input: [{ type: 'text', text: withPaths }, ...files.filter(f => f.mime).map(f => ({ type: 'localImage', path: f.path }))], ...(model ? { model } : {}) }));
        r.turnID = string(object(result.turn).id); await completed;
      } else if (r.agent.kind === 'dsh') {
        await r.rpc!.request('session/prompt', { sessionId: r.session.nativeID, contentBlocks: [{ type: 'text', text: withPaths }, ...files.filter(f => f.mime).map(f => ({ type: 'image', data: f.data, mimeType: f.mime }))] });
        await r.rpc!.request('session/wait', { sessionId: r.session.nativeID }, 0);
      } else {
        const resumed = r.session.nativeStarted === true;
        const images = files.filter((f): f is typeof f & { mime: 'image/png' | 'image/jpeg' | 'image/webp' | 'image/gif'; data: string } => f.mime !== undefined && f.data !== undefined);
        async function* input(): AsyncGenerator<SDKUserMessage> {
          yield { type: 'user', session_id: r!.session.nativeID, parent_tool_use_id: null, message: { role: 'user', content: [{ type: 'text', text: withPaths }, ...images.map(f => ({ type: 'image' as const, source: { type: 'base64' as const, media_type: f.mime, data: f.data } }))] } };
        }
        const q = query({ prompt: images.length ? input() : withPaths, options: {
          cwd: r.session.project, pathToClaudeCodeExecutable: r.agent.command, env: { ...childEnvironment(r.agent.env), CLAUDE_CODE_MAX_OUTPUT_TOKENS: '32768' },
          ...(resumed ? { resume: r.session.nativeID } : { sessionId: r.session.nativeID }),
          ...(model ? { model } : {}), maxTurns: 64, includePartialMessages: true, permissionMode: 'default',
          canUseTool: async (name, input, options) => {
            const answer = await this.ask(name, { input, conversationID: id }, options.signal);
            return answer.allowed === true ? { behavior: 'allow', updatedInput: { ...input, ...object(answer.updatedInput) } } : { behavior: 'deny', message: '用户拒绝此次操作' };
          },
        } });
        r.claude = q;
        try { for await (const message of q) {
          const raw = object(message);
          if (raw.type === 'system' && raw.subtype === 'init') r.session.nativeStarted = true;
          if (raw.type === 'stream_event') {
            const event = object(raw.event), delta = object(event.delta);
            if (delta.type === 'text_delta') this.delta(r, string(delta.text));
          }
          if (raw.type === 'assistant') {
            const m = object(raw.message), text = content(m.content);
            const existing = r.session.messages.find(m => m.id === r.deltaID);
            if (existing) existing.text = text;
            else if (text) r.session.messages.push({ id: randomUUID(), role: 'assistant', text, time: Date.now(), kind: 'text' });
            r.deltaID = undefined;
            const u = object(m.usage);
            if (Object.keys(u).length) r.session.usage.push({ id: string(m.id, randomUUID()), time: Date.now(), model: string(m.model), input: number(u.input_tokens), output: number(u.output_tokens), cacheRead: number(u.cache_read_input_tokens), cacheWrite: number(u.cache_creation_input_tokens) });
          }
          this.emit('chat', { conversationID: id, method: 'claude/message', params: raw });
          if (raw.type === 'result' && raw.is_error === true) throw new Error(string(raw.result, JSON.stringify(raw.errors ?? 'Claude 执行失败')));
        } } finally { q.close(); r.claude = undefined; }
      }
      this.emit('state', { conversationID: id, state: 'idle' });
    } catch (error) {
      this.emit('state', { conversationID: id, state: 'error', message: String(error) }); throw error;
    } finally { r.busy = false; r.finish = undefined; r.fail = undefined; await this.persist(r); }
  }
  async stop(id: string): Promise<void> {
    const r = this.running.get(id); if (!r) return;
    if (r.peer && r.busy) await r.peer.notify('session/cancel', { sessionId: r.session.nativeID }).catch(error => this.emit('warning', `ACP 取消返回：${String(error)}`));
    if (r.claude) { try { await r.claude.interrupt(); } catch (error) { this.emit('warning', `Claude 中断返回：${String(error)}`); } finally { r.claude.close(); r.claude = undefined; } }
    if (r.rpc && r.agent.kind === 'codex' && r.turnID) await r.rpc.request('turn/interrupt', { threadId: r.session.nativeID, turnId: r.turnID }).catch(() => {});
    await r.peer?.close(); await r.rpc?.close(); await r.tools?.close(); r.finish?.();
    this.running.delete(id); this.emit('state', { conversationID: id, state: 'stopped' });
    await this.persist(r);
  }
  async configure(id: string, configId: string, value: string): Promise<unknown> {
    const r = this.running.get(id); if (!r?.peer) throw new Error('此会话没有 ACP 配置项');
    if (configId === '__legacy_mode') return r.peer.request('session/set_mode', { sessionId: r.session.nativeID, modeId: value });
    if (configId === '__legacy_model') return r.peer.request('session/set_model', { sessionId: r.session.nativeID, modelId: value });
    const parsed: string | boolean = value === 'true' ? true : value === 'false' ? false : value;
    return r.peer.request('session/set_config_option', { sessionId: r.session.nativeID, configId, value: parsed, ...(r.peer.version === 2 ? { type: typeof parsed === 'boolean' ? 'boolean' : 'id' } : {}) });
  }
  async list(agentValue: unknown, cwd: string, cursor?: string): Promise<unknown> {
    const agent = validateConfig(agentValue), tools = new ClientTools(cwd, this.ask);
    const peer = await openAcp(agent, cwd, this.ask, () => {}, tools);
    try {
      const caps = object(peer.info.agentCapabilities ?? peer.info.capabilities), session = object(caps.session ?? caps.sessionCapabilities);
      if (peer.version === 2 ? caps.session == null : !session.list) throw new Error('此 Agent 未声明会话列举能力');
      return await peer.request('session/list', { cwd, ...(cursor ? { cursor } : {}) });
    } finally { await peer.close(); await tools.close(); }
  }
  async authenticate(agentValue: unknown, cwd: string, methodID: string): Promise<unknown> {
    const agent = validateConfig(agentValue), tools = new ClientTools(cwd, this.ask);
    const peer = await openAcp(agent, cwd, this.ask, (method, params) => this.emit('agentEvent', { agentID: agent.id, method, params }), tools);
    try {
      const methods = Array.isArray(peer.info.authMethods) ? peer.info.authMethods.map(object) : [];
      const method = methods.find(m => string(m.id ?? m.methodId) === methodID);
      if (!method) throw new Error('Agent 未声明此认证方法');
      if (method.type === 'terminal') return createTerminalAuth(agent, method, cwd, dirname(this.root));
      return await peer.request(peer.version === 2 ? 'auth/login' : 'authenticate', { methodId: methodID }, 0);
    }
    finally { await peer.close(); await tools.close(); }
  }
  async close(): Promise<void> {
    const results = await Promise.allSettled([...this.running.keys()].map(id => this.stop(id)));
    for (const result of results) if (result.status === 'rejected') this.emit('warning', `会话清理失败：${String(result.reason)}`);
  }

  async importNative(agentValue: unknown, record: Data, cwd: string): Promise<Data> {
    const agent = validateConfig(agentValue), nativeID = string(record.sessionId);
    if (!nativeID) throw new Error('Agent 历史条目缺少会话 ID');
    const session: Session = { id: sessionKey('acp', `${agent.id}\0${nativeID}`), nativeID, source: 'acp', instanceID: agent.id, title: string(record.title, nativeID), project: string(record.cwd, cwd), home: '', created: Date.now(), updated: Date.now(), messages: [], usage: [], files: [], warnings: [] };
    return this.start({ agent, session, cwd: session.project });
  }
}
