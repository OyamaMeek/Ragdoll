import { createReadStream } from 'node:fs';
import { readdir, stat, realpath } from 'node:fs/promises';
import { homedir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { createZstdDecompress } from 'node:zlib';
import { createHash } from 'node:crypto';
import { object, string, number, timestamp, content } from './types.ts';
import type { Data, Location, Session, Usage } from './types.ts';

const fingerprints = new Map<string, string>();

export const sessionKey = (source: string, id: string) => `${source}:${createHash('sha256').update(id).digest('hex').slice(0, 24)}`;

export function defaultLocations(): Location[] {
  return [
    { source: 'codex', path: process.env.CODEX_HOME || join(homedir(), '.codex') },
    { source: 'claude', path: process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude') },
    { source: 'dsh', path: process.env.DSH_HOME || join(homedir(), '.dsh') },
  ];
}

async function* records(path: string, warnings: string[]): AsyncGenerator<Data> {
  const input = createReadStream(path);
  const stream = /\.(zstd|zst)$/.test(path) ? input.pipe(createZstdDecompress()) : input;
  input.on('error', error => stream.destroy(error));
  let pending = '';
  stream.setEncoding('utf8');
  try {
    for await (const chunk of stream) {
      pending += String(chunk);
      let end: number;
      while ((end = pending.indexOf('\n')) >= 0) {
        const line = pending.slice(0, end).trim();
        pending = pending.slice(end + 1);
        if (!line) continue;
        try { yield object(JSON.parse(line)); }
        catch { warnings.push('存在无法解析的完整 JSONL 记录'); }
      }
    }
  } catch (error) {
    if (!/unexpected end|incomplete|premature/i.test(String(error))) throw error;
    warnings.push('压缩尾部尚未写完，下次扫描重试');
  } finally { input.destroy(); stream.destroy(); }
  if (pending.trim()) {
    try { yield object(JSON.parse(pending)); }
    catch { warnings.push('尾部记录尚未写完，下次扫描重试'); }
  }
}

function usage(id: string, time: number, model: string, v: Data, inclusive: boolean): Usage {
  const cacheRead = number(v.cached_input_tokens ?? v.cache_read_input_tokens ?? v.cacheReadTokens);
  const cacheWrite = number(v.cache_creation_input_tokens ?? v.cache_write_input_tokens ?? v.cacheWriteTokens);
  return {
    id, time, model,
    input: Math.max(0, number(v.input_tokens ?? v.inputTokens) - (inclusive ? cacheRead + cacheWrite : 0)),
    output: number(v.output_tokens ?? v.outputTokens), cacheRead,
    cacheWrite,
  };
}

export async function parseFile(source: Location['source'], path: string, home = dirname(path)): Promise<Session> {
  const file = await stat(path);
  const session: Session = {
    id: '', nativeID: basename(path).replace(/\.jsonl(?:\.(?:zstd|zst))?$/, ''), source, home,
    title: '', project: '', created: file.birthtimeMs, updated: file.mtimeMs,
    messages: [], usage: [], files: [path], warnings: [],
  };
  const messages = new Map<string, Session['messages'][number]>();
  const counted = new Map<string, Usage>();
  const canonical = new Map<string, Usage>();
  let model = '', inherited = false, seedLength = 0, line = 0;
  let previous: Data = {};
  let firstTime = Number.POSITIVE_INFINITY, lastTime = 0;
  for await (const e of records(path, session.warnings)) {
    line++;
    const p = object(e.payload), d = object(e.data), m = object(e.message);
    const time = timestamp(e.timestamp ?? e.time);
    if (time) { firstTime = Math.min(firstTime, time); lastTime = Math.max(lastTime, time); }
    const addMessage = (role: string, text: string, id = string(e.uuid ?? e.seq, String(line)), kind = 'text') => {
      if (!text) return;
      messages.set(id, { id, role, text, time: time || file.mtimeMs, kind });
      if (!session.title && role === 'user') session.title = text.replace(/\s+/g, ' ').slice(0, 100);
    };
    if (source === 'codex') {
      if (e.type === 'session_meta') {
        session.nativeID = string(p.id ?? p.session_id, session.nativeID);
        session.project = string(p.cwd, session.project);
        session.parentID = string(p.forked_from_id) || undefined;
      }
      if (e.type === 'turn_context') { model = string(p.model, model); session.project ||= string(p.cwd); }
      if (e.type === 'token_usage_record') {
        const id = string(p.response_id, String(line));
        canonical.set(id, usage(id, time, model, object(p.usage), true));
      }
      if (e.type === 'event_msg' && p.type === 'token_count') {
        const info = object(p.info), total = object(info.total_token_usage);
        const current = object(info.last_token_usage);
        const key = JSON.stringify(total);
        if (Object.keys(total).length && !counted.has(key)) {
          const delta: Data = {};
          for (const k of ['input_tokens', 'output_tokens', 'cached_input_tokens', 'cache_write_input_tokens']) delta[k] = Math.max(0, number(total[k]) - number(previous[k]));
          counted.set(key, usage(key, time, model, Object.keys(previous).length ? delta : current, true));
          previous = total;
        }
      }
      if (e.type === 'response_item' && p.type === 'message') addMessage(string(p.role, 'assistant'), content(p.content));
      if (e.type === 'response_item' && /tool_call|function_call/.test(string(p.type))) addMessage('tool', `${string(p.name)}\n${content(p.arguments ?? p.input ?? p.output)}`, string(p.call_id, String(line)), 'tool');
    }
    if (source === 'claude') {
      session.nativeID = string(e.sessionId, session.nativeID);
      session.project ||= string(e.cwd);
      if (e.type === 'summary') session.title = string(e.summary, session.title);
      if (e.type === 'custom-title') session.title = string(e.customTitle, session.title);
      if (e.type === 'user' || e.type === 'assistant') addMessage(string(e.type), content(m.content));
      if (e.type === 'assistant' && Object.keys(object(m.usage)).length) {
        const id = string(m.id ?? e.requestId ?? e.uuid, String(line));
        counted.set(id, usage(id, time, string(m.model), object(m.usage), false));
      }
      if (e.parentUuid && e.isSidechain) session.parentID ||= string(e.parentUuid);
    }
    if (source === 'dsh') {
      if (e.type === 'session') {
        session.nativeID = string(e.id, session.nativeID);
        session.project = string(e.cwd);
        session.created = timestamp(e.createdAt);
        session.parentID = string(e.parentSession) || undefined;
        inherited = e.isSeeded === true;
        seedLength = number(e.seedLength);
      }
      if (e.type === 'session/end-seed') { inherited = false; continue; }
      if (inherited || (seedLength > 0 && number(e.seq) < seedLength)) continue;
      if (e.type === 'session/title') session.title = string(d.title, session.title);
      if (e.type === 'user/message' && object(d.source).kind === 'user') addMessage('user', content(d.content));
      if (e.type === 'assistant/message') {
        const message = object(d.message), route = object(message.source);
        model = string(route.model, model);
        session.provider = string(route.provider) || session.provider;
        addMessage('assistant', content(message.content ?? d.content));
        if (Object.keys(object(d.usage)).length) counted.set(String(e.seq), usage(String(e.seq), time, model, object(d.usage), false));
      }
      if (e.type === 'tool/call') addMessage('tool', `${string(d.name)}\n${content(d.arguments)}`, String(e.seq), 'tool');
      if (e.type === 'tool/result') addMessage('tool', content(d.result ?? d.content), String(e.seq), 'tool');
    }
  }
  session.id = sessionKey(source, `${home}\0${session.nativeID}`);
  session.messages = [...messages.values()];
  session.usage = [...(canonical.size ? canonical : counted).values()];
  session.title ||= session.nativeID;
  if (Number.isFinite(firstTime)) session.created = Math.min(session.created || firstTime, firstTime);
  session.updated = lastTime || file.mtimeMs;
  session.warnings = [...new Set(session.warnings)];
  return session;
}

async function walk(path: string): Promise<string[]> {
  const entries = await readdir(path, { withFileTypes: true });
  const found = await Promise.all(entries.filter(e => !e.isSymbolicLink()).map(async e => {
    const p = join(path, e.name);
    if (e.isDirectory()) return walk(p);
    return /\.jsonl(?:\.(?:zstd|zst))?$/.test(e.name) ? [p] : [];
  }));
  return found.flat();
}

export async function scan(locations: Location[], onSession?: (session: Session) => void | Promise<void>, onError?: (message: string) => void): Promise<Session[]> {
  const results: Session[] = [];
  for (const location of locations) {
    let paths: string[];
    try {
      paths = (await Promise.all((location.source === 'claude' ? ['projects'] : ['sessions', ...(location.source === 'codex' ? ['archived_sessions'] : [])]).map(async sub => {
        try { return await walk(join(location.path, sub)); }
        catch (error) { if (object(error).code === 'ENOENT') return []; throw error; }
      }))).flat();
    } catch (error) { onError?.(`${location.path}: ${String(error)}`); continue; }
    if (location.source === 'dsh') {
      const latest = new Map<string, { path: string; version: number; modified: number }>();
      for (const path of paths) {
        const match = /^session(?:\.v(\d+))?\.jsonl(?:\.zstd)?$/.exec(basename(path));
        if (!match) continue;
        const key = dirname(path), version = Number(match[1] || 0), modified = (await stat(path)).mtimeMs;
        const old = latest.get(key);
        if (!old || version > old.version || (version === old.version && modified > old.modified)) latest.set(key, { path, version, modified });
      }
      paths = [...latest.values()].map(v => v.path);
    }
    for (const path of paths) {
      try {
        const info = await stat(path), fingerprint = `${info.size}:${info.mtimeMs}:${info.birthtimeMs}`;
        if (onSession && fingerprints.get(path) === fingerprint) continue;
        const session = await parseFile(location.source, await realpath(path), location.path);
        if (onSession) { await onSession(session); fingerprints.set(path, fingerprint); } else results.push(session);
      } catch (error) { onError?.(`${path}: ${String(error)}`); }
    }
  }
  return results;
}
