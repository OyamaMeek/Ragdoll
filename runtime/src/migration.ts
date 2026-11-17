import { mkdir, readFile, writeFile, copyFile, stat, realpath, link, rm } from 'node:fs/promises';
import { dirname, join, basename, isAbsolute } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { zstdDecompressSync, zstdCompressSync } from 'node:zlib';
import { randomUUID } from 'node:crypto';
import { constants } from 'node:fs';
import { object, string, timestamp, content } from './types.ts';
import type { Data, Session } from './types.ts';
import { parseFile } from './logs.ts';
import { RpcProcess } from './rpc.ts';

interface Historical { role: 'user' | 'assistant'; text: string; time: number }

export async function migrateSession(value: unknown): Promise<Session> {
  const input = object(value), source = object(input.session), target = object(input.target);
  const kind = string(target.kind), home = string(input.home), cwd = string(input.cwd);
  if (!['codex', 'claude', 'dsh'].includes(kind) || !isAbsolute(home) || !isAbsolute(cwd) || !string(source.id)
    || !['codex', 'claude', 'dsh', 'desktop', 'acp'].includes(string(source.source))
    || !Array.isArray(source.files) || !Array.isArray(source.messages) || !Array.isArray(target.args)
    || target.args.some(x => typeof x !== 'string') || !string(target.command) || !string(target.id)) throw new Error('迁移来源、目标工具或目录无效');
  if (Object.entries(object(target.env)).some(([key, value]) => !/^[A-Za-z_][A-Za-z0-9_]*$/.test(key) || typeof value !== 'string')) throw new Error('目标工具环境变量无效');
  if (!(await stat(cwd)).isDirectory()) throw new Error('目标项目不是目录');
  const files = source.files;
  if (files.some(p => typeof p !== 'string' || !isAbsolute(p))) throw new Error('源记录路径无效');
  const id = randomUUID(), now = Date.now();
  const history: Historical[] = [], snapshots: { path: string; data: Buffer; fingerprint: string }[] = [];
  const attachments = new Set<string>();
  if (source.source === 'acp' || source.source === 'desktop') {
    for (const raw of source.messages) {
      const message = object(raw);
      if (typeof message.text !== 'string') throw new Error('源消息内容无效');
      history.push({ role: message.role === 'user' ? 'user' : 'assistant', text: message.text, time: timestamp(message.time) || now });
    }
  }
  const collectAttachments = (v: unknown): void => {
    if (Array.isArray(v)) { for (const item of v) collectAttachments(item); return; }
    const record = object(v), type = string(record.type);
    for (const [key, item] of Object.entries(record)) {
      if (typeof item === 'string' && item.startsWith('file://')) attachments.add(fileURLToPath(item));
      else if (typeof item === 'string' && isAbsolute(item) && /image|file|attachment/.test(type) && /path|url|image/.test(key)) attachments.add(item);
      else if (typeof item === 'object' && item !== null) collectAttachments(item);
    }
  };
  for (const path of files as string[]) {
    const before = await stat(path);
    if (!before.isFile()) throw new Error(`源记录不是普通文件：${path}`);
    const data = await readFile(path);
    const fingerprint = `${before.size}:${before.mtimeMs}`;
    snapshots.push({ path, data, fingerprint });
    if (!/\.jsonl(?:\.(?:zstd|zst))?$|\.json$/i.test(path)) { attachments.add(path); continue; }
    const text = (/\.(zstd|zst)$/.test(path) ? zstdDecompressSync(data) : data).toString('utf8');
    const records: unknown[] = /\.json$/i.test(path) ? [JSON.parse(text)] : text.split('\n').filter(line => line.trim()).map(line => JSON.parse(line));
    for (const raw of records) {
      const e = object(raw);
      if (!Object.keys(e).length) throw new Error(`源记录格式无效：${path}`);
      collectAttachments(e);
      const p = object(e.payload), d = object(e.data), m = object(e.message);
      const time = timestamp(e.timestamp ?? e.time) || now;
      const native = e.type === 'response_item' && p.type === 'message' ? p
        : e.type === 'assistant/message' ? object(d.message)
        : e.type === 'user/message' ? d
        : e.type === 'user' || e.type === 'assistant' ? { ...m, role: e.type } : undefined;
      if (native) {
        const text = content(native.content);
        if (text) history.push({ role: native.role === 'user' || e.type === 'user/message' ? 'user' : 'assistant', text, time });
      }
      history.push({ role: 'assistant', time, text: `【迁移来源：${string(source.source)} · ${string(e.type, '原始记录')}】\n\n${JSON.stringify(e, null, 2)}` });
    }
  }
  if (!snapshots.length) {
    for (const raw of source.messages) {
      const m = object(raw);
      if (typeof m.text !== 'string') throw new Error('源消息内容无效');
      history.push({ role: m.role === 'user' ? 'user' : 'assistant', text: m.text, time: timestamp(m.time) || now });
    }
  }
  if (!history.length) throw new Error('没有可迁移的历史记录');
  if (string(source.source) === 'desktop' && Array.isArray(source.warnings) && source.warnings.some(w => typeof w === 'string' && w.includes('附件'))) throw new Error('导出包缺失原始附件，无法完整迁移');
  await mkdir(home, { recursive: true });
  const canonicalHome = await realpath(home);
  const migrationRoot = join(canonicalHome, '.ragdoll-migrations');
  await mkdir(migrationRoot, { recursive: true, mode: 0o700 });
  if (await realpath(migrationRoot) !== migrationRoot) throw new Error('迁移目录不能是符号链接');
  const bundle = join(migrationRoot, id);
  await mkdir(bundle, { mode: 0o700 });
  let published: string | undefined;
  try {
    const copies = new Map<string, string>();
    for (const path of attachments) {
      if (!(await stat(path)).isFile()) throw new Error(`缺失附件或附件不是普通文件：${path}`);
      const destination = join(bundle, `${copies.size}-${basename(path)}`);
      await copyFile(path, destination, constants.COPYFILE_EXCL); copies.set(path, destination);
    }
    for (const item of history) for (const [from, to] of copies) {
      item.text = item.text.replaceAll(pathToFileURL(from).href, pathToFileURL(to).href)
        .replaceAll(JSON.stringify(from).slice(1, -1), JSON.stringify(to).slice(1, -1)).replaceAll(from, to);
    }
    for (const [index, snapshot] of snapshots.entries()) {
      const current = await stat(snapshot.path);
      if (`${current.size}:${current.mtimeMs}` !== snapshot.fingerprint) throw new Error('源会话正在变化，请停止原会话后重试迁移');
      await writeFile(join(bundle, `raw-${index}-${basename(snapshot.path)}`), snapshot.data, { flag: 'wx', mode: 0o600 });
    }
    const migration = { sourceID: string(source.id), source: string(source.source), sourceNativeID: string(source.nativeID), created: now, title: string(source.title, '迁移会话') };
    await writeFile(join(bundle, 'manifest.json'), JSON.stringify({ version: 1, migration, target: kind, id, originalUsage: source.usage, attachments: Object.fromEntries(copies) }, null, 2), { flag: 'wx', mode: 0o600 });
    const iso = (time: number) => new Date(time).toISOString();
    let rows: Data[], destination: string;
    if (kind === 'codex') {
      const day = iso(now).slice(0, 10);
      destination = join(canonicalHome, 'sessions', ...day.split('-'), `rollout-${iso(now).replaceAll(':', '-')}-${id}.jsonl`);
      rows = [{ timestamp: iso(now), type: 'session_meta', payload: { id, timestamp: iso(now), cwd, originator: 'codex_cli_rs', cli_version: '0.147.0', source: 'cli', model_provider: 'openai' } },
        ...history.flatMap((m, index) => [
          { timestamp: iso(m.time), type: 'event_msg', payload: { type: m.role === 'user' ? 'user_message' : 'agent_message', message: m.text, images: [], local_images: [] } },
          { timestamp: iso(m.time), type: 'response_item', payload: { type: 'message', id: `migrated-${index}`, role: m.role, content: [{ type: m.role === 'user' ? 'input_text' : 'output_text', text: m.text }] } },
        ])];
    } else if (kind === 'claude') {
      destination = join(canonicalHome, 'projects', cwd.replace(/[^a-zA-Z0-9]/g, '-'), `${id}.jsonl`);
      let parentUuid: string | null = null;
      rows = history.map(m => {
        const uuid = randomUUID();
        const row = { type: m.role, uuid, parentUuid, sessionId: id, cwd, isSidechain: false, timestamp: iso(m.time), version: '2.1.268', userType: 'external', message: { role: m.role, content: [{ type: 'text', text: m.text }], ...(m.role === 'assistant' ? { id: uuid, type: 'message', model: '<synthetic>', stop_reason: 'end_turn', stop_sequence: null } : {}) } };
        parentUuid = uuid; return row;
      });
    } else {
      let readable = '', separator = false;
      for (let i = 0; i < cwd.length; i++) {
        const ch = cwd[i]!;
        if (ch === '/' || ch === '\\' || ch === ':') { if (!separator) readable += '-'; separator = true; }
        else { readable += ch !== '~' && /^[A-Za-z0-9._-]$/.test(ch) ? ch : '~' + cwd.charCodeAt(i).toString(16).toUpperCase().padStart(4, '0'); separator = false; }
      }
      destination = join(canonicalHome, 'sessions', `--${(readable.replace(/^-+/, '') || 'root').slice(0, 251)}--`, id, 'session.v4.jsonl.zstd');
      let turn = 0;
      const events = history.flatMap((m): Data[] => {
        if (m.role === 'user') return [{ type: 'user/message', time: m.time, surfaceOp: 'append', data: { id: randomUUID(), role: 'user', source: { kind: 'user' }, content: [{ type: 'text', text: m.text }] } }];
        turn++;
        return [
          { type: 'turn/start', time: m.time, data: { turn } },
          { type: 'step/start', time: m.time, data: { turn, step: 1 } },
          { type: 'assistant/message', time: m.time, surfaceOp: 'append', data: { turn, step: 1, message: { id: randomUUID(), role: 'assistant', content: [{ type: 'text', text: m.text }], source: { kind: 'model', provider: 'deepseek-official', model: 'deepseek-v4-flash' } }, stream: [
            { type: 'chunk', time: m.time, chunk: { type: 'block-start', index: 0, blockType: 'text' } },
            { type: 'text-chunks', time0: m.time, index: 0, dt: [0], texts: [m.text] },
            { type: 'chunk', time: m.time, chunk: { type: 'block-end', index: 0, block: { type: 'text', text: m.text } } },
            { type: 'chunk', time: m.time, chunk: { type: 'finish', reason: { kind: 'stop' } } },
          ] } },
          { type: 'step/end', time: m.time, data: { turn, step: 1 } },
          { type: 'turn/end', time: m.time, data: { turn, reason: { kind: 'completed' } } },
        ];
      });
      if (string(source.title)) events.push({ type: 'session/title', time: now, data: { title: string(source.title), source: { kind: 'user' }, messageSeqs: [] } });
      rows = [{ type: 'session', version: 4, id, cwd, createdAt: now, isSeeded: false, delegationDepth: 0 }, ...events.map((event, seq) => ({ ...event, seq }))];
    }
    let ancestor = dirname(destination);
    while (true) {
      try {
        const existing = await realpath(ancestor);
        if (existing !== canonicalHome && !existing.startsWith(canonicalHome + '/')) throw new Error('目标历史路径越界');
        break;
      } catch (error) { if (object(error).code !== 'ENOENT') throw error; ancestor = dirname(ancestor); }
    }
    await mkdir(dirname(destination), { recursive: true });
    if (!(await realpath(dirname(destination))).startsWith(canonicalHome + '/')) throw new Error('目标历史路径越界');
    const prepared = join(bundle, 'prepared.jsonl');
    const output = kind === 'dsh'
      ? Buffer.concat(rows.map(row => zstdCompressSync(Buffer.from(JSON.stringify(row) + '\n'))))
      : Buffer.from(rows.map(row => JSON.stringify(row)).join('\n') + '\n');
    await writeFile(prepared, output, { flag: 'wx', mode: 0o600 });
    await link(prepared, destination); published = destination;
    const artifacts = [join(bundle, 'manifest.json'), ...snapshots.map((s, index) => join(bundle, `raw-${index}-${basename(s.path)}`)), ...copies.values()];
    await writeFile(destination + '.ragdoll.json', JSON.stringify({ ...migration, files: artifacts }), { flag: 'wx', mode: 0o600 });
    if (kind === 'codex' || kind === 'dsh') {
      const args = target.args as string[];
      const rpc = new RpcProcess(string(target.command), kind === 'codex' ? [...args, 'app-server'] : args, cwd, { ...object(target.env) as Record<string, string>, [kind === 'codex' ? 'CODEX_HOME' : 'DSH_HOME']: canonicalHome });
      try {
        if (kind === 'codex') {
          await rpc.request('initialize', { clientInfo: { name: 'ragdoll', version: '0.1.0' }, capabilities: { experimentalApi: true } }); rpc.notify('initialized');
          await rpc.request('thread/resume', { threadId: id, path: destination, cwd, approvalPolicy: 'on-request', sandbox: 'workspace-write' });
          if (string(source.title)) await rpc.request('thread/name/set', { threadId: id, name: string(source.title) });
        } else {
          await rpc.request('initialize', { cwd, provider: 'deepseek-official', model: 'deepseek-v4-flash', maxTokens: 32768, approvalRequests: true });
          await rpc.request('session/resume', { sessionId: id });
        }
      } finally { await rpc.close(); }
    }
    const session = await parseFile(kind as 'codex' | 'claude' | 'dsh', destination, canonicalHome);
    session.migration = migration; session.instanceID = string(target.id); session.title = string(source.title, '迁移会话');
    session.files = [...new Set([...session.files, ...artifacts])];
    session.warnings.push('迁移历史：工具及专属记录按来源全文保留，不重新执行；旧用量归属原会话。');
    if (kind === 'claude' || source.source === 'claude') session.warnings.push('Claude 原生迁移未验证');
    return session;
  } catch (error) {
    if (published) { await rm(published, { force: true }); await rm(published + '.ragdoll.json', { force: true }); }
    await rm(bundle, { recursive: true, force: true });
    throw error;
  }
}
