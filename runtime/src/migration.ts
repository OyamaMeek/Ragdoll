import { mkdir, readFile, writeFile, copyFile, stat, realpath, link, rm } from 'node:fs/promises';
import { dirname, join, basename, isAbsolute } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { zstdDecompressSync, zstdCompressSync } from 'node:zlib';
import { randomUUID } from 'node:crypto';
import { constants } from 'node:fs';
import { object, string, timestamp } from './types.ts';
import type { Data, Session } from './types.ts';
import { parseFile } from './logs.ts';
import { RpcProcess } from './rpc.ts';

interface Historical { role: 'user' | 'assistant'; text: string; time: number }

export async function publishNativeHistory(prepared: string, destination: string, sidecar: string): Promise<void> {
  await link(prepared, destination);
  try { await writeFile(destination + '.ragdoll.json', sidecar, { flag: 'wx', mode: 0o600 }); }
  catch (error) { await rm(destination); throw error; }
}

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
  const authorized = input.authorizedAttachments ?? [];
  if (!Array.isArray(authorized) || authorized.some(p => typeof p !== 'string' || !isAbsolute(p))) throw new Error('授权附件路径无效');
  const id = randomUUID(), now = Date.now();
  const origin = object(source.migration), previousAttachments = origin.attachments ?? [];
  if ((Object.keys(origin).length && !Array.isArray(origin.attachments)) || !Array.isArray(previousAttachments)
    || previousAttachments.some(p => typeof p !== 'string' || !files.includes(p))) throw new Error('旧迁移缺少可信附件清单，请从原会话重新迁移');
  const previous = new Set(await Promise.all((previousAttachments as string[]).map(p => realpath(p))));
  const history: Historical[] = [], snapshots: { path: string; actual: string; data: Buffer; fingerprint: string; modified: number }[] = [];
  const attachments = new Set<string>();
  const projectRoot = await realpath(cwd);
  const sourceRoot = string(source.home) ? await realpath(string(source.home)) : undefined;
  for (const path of files as string[]) {
    const before = await stat(path);
    if (!before.isFile()) throw new Error(`源记录不是普通文件：${path}`);
    snapshots.push({ path, actual: await realpath(path), data: await readFile(path), fingerprint: `${before.size}:${before.mtimeMs}`, modified: before.mtimeMs });
  }
  const nativeID = string(source.nativeID);
  const nativeFiles = snapshots.filter(s => sourceRoot && (s.actual.startsWith(join(sourceRoot, 'sessions') + '/') || s.actual.startsWith(join(sourceRoot, 'archived_sessions') + '/') || s.actual.startsWith(join(sourceRoot, 'projects') + '/'))
    && /\.jsonl(?:\.(?:zstd|zst))?$/.test(s.path)
    && (basename(s.path).endsWith(nativeID + '.jsonl') || basename(dirname(s.actual)) === nativeID));
  const primary = source.source === 'acp' ? snapshots.filter(s => basename(s.path) === 'events.jsonl')
    : source.source === 'desktop' ? [] : nativeFiles.sort((a, b) => Number(/\.v(\d+)\./.exec(b.path)?.[1] ?? 0) - Number(/\.v(\d+)\./.exec(a.path)?.[1] ?? 0) || b.modified - a.modified).slice(0, 1);
  if (source.source !== 'acp' && source.source !== 'desktop' && !primary.length) throw new Error('原始原生历史尚未取得，请先刷新会话索引后迁移');
  const explicitAttachments = snapshots.filter(s => previous.has(s.actual) || (source.source !== 'desktop' && !primary.includes(s) && !nativeFiles.includes(s)
    && !(sourceRoot && s.actual.startsWith(join(sourceRoot, '.ragdoll-migrations') + '/')) && !nativeFiles.some(log => s.actual === log.actual + '.ragdoll.json')));
  const allowed = new Set([...explicitAttachments.map(s => s.actual), ...await Promise.all((authorized as string[]).map(p => realpath(p)))]);
  for (const file of explicitAttachments) attachments.add(file.path);
  if (source.source === 'acp' || source.source === 'desktop') {
    for (const raw of source.messages) {
      const message = object(raw);
      if (typeof message.text !== 'string') throw new Error('源消息内容无效');
      history.push({ role: message.role === 'user' ? 'user' : 'assistant', text: message.text, time: timestamp(message.time) || now });
    }
  }
  const collectPath = (value: unknown): void => {
    if (typeof value !== 'string') return;
    if (value.startsWith('file://')) attachments.add(fileURLToPath(value));
    else if (isAbsolute(value)) attachments.add(value);
  };
  const collectBlock = (value: unknown): void => {
    const block = object(value);
    if (!['input_image', 'localImage', 'local_image', 'image', 'input_file', 'file', 'document', 'attachment', 'resource_link'].includes(string(block.type))) return;
    for (const record of [block, object(block.source)]) for (const key of ['path', 'file_path', 'filePath', 'image_url', 'url', 'uri']) collectPath(record[key]);
  };
  const addRecord = (record: unknown, type: string, time: number) => history.push({ role: 'assistant', time, text: `【迁移来源：${string(source.source)} · ${type}】\n\n${JSON.stringify(record, null, 2)}` });
  const addMessage = (role: 'user' | 'assistant', value: unknown, time: number): void => {
    if (typeof value === 'string') { if (value) history.push({ role, text: value, time }); return; }
    const blocks = Array.isArray(value) ? value : [value];
    let text: string[] = [];
    const flush = () => { if (text.length) history.push({ role, text: text.join('\n'), time }); text = []; };
    for (const raw of blocks) {
      const block = object(raw);
      if (role === 'user') collectBlock(block);
      if (typeof raw === 'string') text.push(raw);
      else if (['text', 'input_text', 'output_text'].includes(string(block.type)) && typeof block.text === 'string') text.push(block.text);
      else if (raw !== undefined && raw !== null) { flush(); addRecord(raw, string(block.type, '内容块'), time); }
    }
    flush();
  };
  for (const snapshot of primary) {
    const text = (/\.(zstd|zst)$/.test(snapshot.path) ? zstdDecompressSync(snapshot.data) : snapshot.data).toString('utf8');
    const records: unknown[] = text.split('\n').filter(line => line.trim()).map(line => JSON.parse(line));
    const mirrored = new Set(records.map(object).filter(e => e.type === 'response_item' && object(e.payload).type === 'message').map(e => {
      const p = object(e.payload);
      const text = typeof p.content === 'string' ? p.content : Array.isArray(p.content) ? p.content.map(object).filter(b => ['text', 'input_text', 'output_text'].includes(string(b.type))).map(b => string(b.text)).join('\n') : '';
      return `${p.role}\0${text}`;
    }));
    for (const raw of records) {
      const e = object(raw);
      if (!Object.keys(e).length) throw new Error(`源记录格式无效：${snapshot.path}`);
      const p = object(e.payload), d = object(e.data), m = object(e.message);
      const time = Math.trunc(timestamp(e.timestamp ?? e.time) || now);
      if (source.source === 'acp') {
        const update = object(object(e.params).update), type = string(update.sessionUpdate ?? update.type);
        if (type === 'user_message_chunk') collectBlock(update.content);
        if (!/^(?:user_message|agent_message|config_option|available_commands|usage)/.test(type)) addRecord(e, type || string(e.method, 'ACP 记录'), time);
        continue;
      }
      const native = e.type === 'response_item' && p.type === 'message' ? p
        : e.type === 'assistant/message' ? object(d.message)
        : e.type === 'user/message' ? d
        : e.type === 'user' || e.type === 'assistant' ? { ...m, role: e.type } : undefined;
      if (native) {
        addMessage(native.role === 'user' || e.type === 'user/message' ? 'user' : 'assistant', native.content, time);
        continue;
      }
      if (e.type === 'event_msg' && ['user_message', 'agent_message'].includes(string(p.type))) {
        const role = p.type === 'user_message' ? 'user' : 'assistant';
        if (role === 'user' && Array.isArray(p.local_images)) for (const path of p.local_images) collectPath(path);
        if (!mirrored.has(`${role}\0${string(p.message)}`)) addMessage(role, string(p.message), time);
        if (role === 'user' && Array.isArray(p.images)) for (const image of p.images) addRecord(image, '图片内容', time);
      } else if (!['session', 'session_meta', 'turn_context', 'turn/start', 'step/start', 'step/end', 'session/title', 'token_usage_record'].includes(string(e.type))
        && !(e.type === 'event_msg' && p.type === 'token_count') && !(e.type === 'turn/end' && object(d.reason).kind === 'completed')) addRecord(e, string(e.type, '原始记录'), time);
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
      const actual = await realpath(path);
      if (!allowed.has(actual) && actual !== projectRoot && !actual.startsWith(projectRoot + '/')) throw new Error(`附件位于目标项目之外，请通过文件选择器授权：${path}`);
      if (!(await stat(actual)).isFile()) throw new Error(`缺失附件或附件不是普通文件：${path}`);
      const destination = join(bundle, `${copies.size}-${basename(path)}`);
      await copyFile(actual, destination, constants.COPYFILE_EXCL); copies.set(path, destination);
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
    const migration = { sourceID: string(source.id), source: string(source.source), sourceNativeID: string(source.nativeID), created: now, title: string(source.title, '迁移会话'), attachments: [...copies.values()] };
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
    const artifacts = [join(bundle, 'manifest.json'), ...snapshots.map((s, index) => join(bundle, `raw-${index}-${basename(s.path)}`)), ...copies.values()];
    await publishNativeHistory(prepared, destination, JSON.stringify({ ...migration, files: artifacts })); published = destination;
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
    const session = await parseFile(kind as 'codex' | 'claude' | 'dsh', destination, home);
    session.migration = migration; session.instanceID = string(target.id); session.title = string(source.title, '迁移会话');
    session.files = [...new Set([...session.files, ...artifacts])];
    session.warnings.push('迁移历史：工具及专属记录按来源全文保留，不重新执行；旧用量归属原会话。');
    if (!snapshots.length) session.warnings.push('原始导入或事件文件不可用；本次仅包含已经保存的消息。');
    if (kind === 'claude' || source.source === 'claude') session.warnings.push('Claude 原生迁移未验证');
    return session;
  } catch (error) {
    if (published) { await rm(published, { force: true }); await rm(published + '.ragdoll.json', { force: true }); }
    await rm(bundle, { recursive: true, force: true });
    throw error;
  }
}
