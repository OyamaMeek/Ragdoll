import { DatabaseSync } from 'node:sqlite';
import { createReadStream } from 'node:fs';
import { copyFile, mkdir, mkdtemp, readdir, rm, stat } from 'node:fs/promises';
import { isAbsolute, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { number, object, sessionKey, string, timestamp } from './types.ts';
import type { Data, Session, Usage } from './types.ts';

const KNOWN_SUBDIRS = ['antigravity', 'antigravity-insiders', 'antigravity-cli'] as const;
const SAFE_CONVERSATION_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const textDecoder = new TextDecoder();

interface SummaryRow {
  title: string;
  preview: string;
  project: string;
  parentID: string;
  lastModified: number;
  lastUserInput: number;
  revision: string;
}

interface SummaryCacheEntry {
  stamp: string;
  rows: Map<string, SummaryRow>;
}

interface TranscriptStep {
  stepIndex: number;
  time: number;
  model: string;
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
}

interface DBCall {
  stepIndex: number;
  time: number;
  gen: number;
  model: string;
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
  response: string;
}

const summaryCache = new Map<string, SummaryCacheEntry>();
const conversationFingerprints = new Map<string, string>();

export function normalizeGeminiModel(raw: string): string {
  const model = raw.trim();
  if (!model || model.length > 200) return '';
  const dash = model.lastIndexOf('-');
  if (dash > 'gemini-'.length && model.startsWith('gemini-') && model.length - dash === 2) {
    const suffix = model.charCodeAt(dash + 1);
    if (suffix >= 97 && suffix <= 122) return model.slice(0, dash);
  }
  return model;
}

function snapshotRoot(): string {
  const index = process.argv.indexOf('--data-dir');
  const dir = index >= 0 ? process.argv[index + 1] : '';
  return dir && isAbsolute(dir) ? join(dir, 'sqlite-snapshots') : join(import.meta.dirname, '../../.cache/sqlite-snapshots');
}

async function fileStamp(path: string): Promise<{ stamp: string; mtimeMs: number; birthtimeMs: number } | null> {
  try {
    const info = await stat(path, { bigint: true });
    if (!info.isFile()) return null;
    return {
      stamp: `${info.size}:${info.mtimeNs}:${info.birthtimeNs}`,
      mtimeMs: Number(info.mtimeMs),
      birthtimeMs: Number(info.birthtimeMs),
    };
  } catch (error) {
    if (object(error).code === 'ENOENT') return null;
    throw error;
  }
}

async function withReadOnlySQLite<T>(dbPath: string, read: (db: DatabaseSync) => T): Promise<T> {
  let walSize = 0;
  try {
    walSize = (await stat(`${dbPath}-wal`)).size;
  } catch (error) {
    if (object(error).code !== 'ENOENT') throw error;
  }
  if (walSize === 0) {
    const uri = pathToFileURL(dbPath);
    uri.search = '?immutable=1';
    const db = new DatabaseSync(uri.href, { readOnly: true });
    try {
      return read(db);
    } finally {
      db.close();
    }
  }
  const base = snapshotRoot();
  await mkdir(base, { recursive: true, mode: 0o700 });
  const tempDir = await mkdtemp(join(base, 'wal-'));
  try {
    const target = join(tempDir, 'snapshot.db');
    await copyFile(dbPath, target);
    try {
      await copyFile(`${dbPath}-wal`, `${target}-wal`);
      if ((await stat(`${target}-wal`)).size === 0) await copyFile(dbPath, target);
    } catch (error) {
      if (object(error).code !== 'ENOENT') throw error;
      await copyFile(dbPath, target);
    }
    const db = new DatabaseSync(target);
    try {
      return read(db);
    } finally {
      db.close();
    }
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

function readVarint(buf: Uint8Array, offset: number): [bigint, number] | null {
  let value = 0n;
  let shift = 0n;
  let index = offset;
  while (index < buf.length) {
    const byte = buf[index++];
    value |= BigInt(byte & 0x7f) << shift;
    if ((byte & 0x80) === 0) return [value, index];
    shift += 7n;
    if (shift > 63n) return null;
  }
  return null;
}

function pbWalk(buf: Uint8Array, visit: (field: number, varint: bigint, bytes: Uint8Array | null) => void): boolean {
  let index = 0;
  while (index < buf.length) {
    const tagEntry = readVarint(buf, index);
    if (!tagEntry) return false;
    const [tag, afterTag] = tagEntry;
    const field = Number(tag >> 3n);
    const wire = Number(tag & 7n);
    if (field <= 0) return false;
    index = afterTag;
    if (wire === 0) {
      const valEntry = readVarint(buf, index);
      if (!valEntry) return false;
      visit(field, valEntry[0], null);
      index = valEntry[1];
    } else if (wire === 1) {
      if (index + 8 > buf.length) return false;
      index += 8;
    } else if (wire === 2) {
      const lenEntry = readVarint(buf, index);
      if (!lenEntry) return false;
      const length = Number(lenEntry[0]);
      index = lenEntry[1];
      if (length < 0 || index + length > buf.length) return false;
      visit(field, 0n, buf.subarray(index, index + length));
      index += length;
    } else if (wire === 5) {
      if (index + 4 > buf.length) return false;
      index += 4;
    } else {
      return false;
    }
  }
  return true;
}

function pbTimestampMs(bytes: Uint8Array): number {
  let sec = 0n;
  let nanos = 0n;
  if (!pbWalk(bytes, (field, value, sub) => {
    if (sub !== null) return;
    if (field === 1) sec = value;
    else if (field === 2) nanos = value;
  })) return 0;
  if (sec <= 0n || sec > (1n << 40n) || nanos < 0n || nanos >= 1_000_000_000n) return 0;
  return Number(sec) * 1000 + Number(nanos) / 1_000_000;
}

function parseGeneratorMetadata(bytes: Uint8Array): { model: string; answeredStep?: number } {
  const candidates = ['', '', ''];
  let answeredStep: number | undefined;
  pbWalk(bytes, (field, _value, sub) => {
    if (field !== 1 || !sub) return;
    pbWalk(sub, (innerField, _innerValue, innerBytes) => {
      if (!innerBytes) return;
      if (innerField === 19) candidates[0] = textDecoder.decode(innerBytes);
      else if (innerField === 21) candidates[1] = textDecoder.decode(innerBytes);
      else if (innerField === 22) candidates[2] = textDecoder.decode(innerBytes);
      else if (innerField === 20) {
        let key = '';
        let val = '';
        pbWalk(innerBytes, (kvField, _kvVal, kvBytes) => {
          if (!kvBytes) return;
          if (kvField === 1) key = textDecoder.decode(kvBytes);
          else if (kvField === 2) val = textDecoder.decode(kvBytes);
        });
        if (key === 'last_step_index') {
          const parsed = Number.parseInt(val.trim(), 10);
          if (Number.isSafeInteger(parsed) && parsed >= 0) answeredStep = parsed + 1;
        }
      }
    });
  });
  for (const candidate of candidates) {
    const normalized = normalizeGeminiModel(candidate);
    if (normalized) return { model: normalized, answeredStep };
  }
  return { model: '', answeredStep };
}

function parseStepMetadata(stepIndex: number, bytes: Uint8Array): { time: number; gen: number; call: DBCall | null } {
  let time = 0;
  let gen = 0;
  let usageBytes: Uint8Array | null = null;
  const ok = pbWalk(bytes, (field, _value, sub) => {
    if (field === 1 && sub) time = pbTimestampMs(sub);
    else if (field === 9 && sub) usageBytes = sub;
    else if (field === 20 && sub) {
      pbWalk(sub, (locField, locVal, locBytes) => {
        if (locField === 3 && locBytes === null) gen = Number(locVal);
      });
    }
  });
  if (!ok) return { time: 0, gen: 0, call: null };
  if (!usageBytes || time <= 0) return { time, gen, call: null };
  let input = 0;
  let output = 0;
  let cacheWrite = 0;
  let cacheRead = 0;
  let response = '';
  const usageOk = pbWalk(usageBytes, (field, value, sub) => {
    if (sub === null) {
      if (field === 2) input = Number(value);
      else if (field === 3) output = Number(value);
      else if (field === 4) cacheWrite = Number(value);
      else if (field === 5) cacheRead = Number(value);
    } else if (field === 11) {
      response = textDecoder.decode(sub);
    }
  });
  if (!usageOk || input + output + cacheWrite + cacheRead <= 0) return { time, gen, call: null };
  return {
    time,
    gen,
    call: { stepIndex, time, gen, model: '', input, output, cacheRead, cacheWrite, response },
  };
}

function parseSummaryTime(raw: string): number {
  const text = raw.trim();
  if (!text) return 0;
  const iso = text.replace(/^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})/, '$1T$2');
  const withZone = /(?:Z|[+-]\d{2}:\d{2})$/.test(iso) ? iso : `${iso}Z`;
  const parsed = Date.parse(withZone);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 0;
}

function parseWorkspaceProject(raw: string): string {
  try {
    const list = JSON.parse(raw);
    if (!Array.isArray(list)) return '';
    for (const entry of list) {
      if (typeof entry !== 'string' || !entry.startsWith('file:')) continue;
      try {
        const url = new URL(entry);
        if (url.protocol !== 'file:') continue;
        if (url.hostname && url.hostname !== 'localhost') continue;
        const resolved = fileURLToPath(url);
        if (resolved) return resolved;
      } catch {}
    }
  } catch {}
  return '';
}

function cleanTitle(raw: string): string {
  return raw.replace(/\s+/g, ' ').trim().slice(0, 100);
}

function extractUserRequest(raw: string): string {
  const startTag = '<USER_REQUEST>';
  const endTag = '</USER_REQUEST>';
  const start = raw.indexOf(startTag);
  if (start < 0) return cleanTitle(raw);
  const rest = raw.slice(start + startTag.length);
  const end = rest.indexOf(endTag);
  return cleanTitle(end >= 0 ? rest.slice(0, end) : rest);
}

async function readSummaries(dataDir: string, onError?: (message: string) => void): Promise<Map<string, SummaryRow>> {
  const dbPath = join(dataDir, 'conversation_summaries.db');
  const mainStamp = await fileStamp(dbPath);
  if (!mainStamp) {
    summaryCache.delete(dbPath);
    return new Map();
  }
  const walStamp = await fileStamp(`${dbPath}-wal`);
  const combinedStamp = `${mainStamp.stamp}|${walStamp?.stamp ?? ''}`;
  const cached = summaryCache.get(dbPath);
  if (cached && cached.stamp === combinedStamp) return cached.rows;

  try {
    const rows = await withReadOnlySQLite(dbPath, db => {
      const table = db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'conversation_summaries'").get();
      if (!table) return new Map<string, SummaryRow>();
      const cols = new Set(
        (db.prepare('PRAGMA table_info(conversation_summaries)').all() as Array<Record<string, unknown>>)
          .map(col => string(col.name))
      );
      if (!cols.has('conversation_id')) return new Map<string, SummaryRow>();
      const query = `SELECT
        conversation_id,
        ${cols.has('title') ? 'title' : "'' AS title"},
        ${cols.has('preview') ? 'preview' : "'' AS preview"},
        ${cols.has('workspace_uris') ? 'workspace_uris' : "'[]' AS workspace_uris"},
        ${cols.has('last_modified_time') ? 'last_modified_time' : "'' AS last_modified_time"},
        ${cols.has('parent_conversation_id') ? 'parent_conversation_id' : "'' AS parent_conversation_id"},
        ${cols.has('last_user_input_time') ? 'last_user_input_time' : "'' AS last_user_input_time"}
      FROM conversation_summaries`;
      const out = new Map<string, SummaryRow>();
      for (const rawRow of db.prepare(query).all() as Array<Record<string, unknown>>) {
        const id = string(rawRow.conversation_id);
        if (!id) continue;
        const title = cleanTitle(string(rawRow.title));
        const preview = cleanTitle(string(rawRow.preview));
        const project = parseWorkspaceProject(string(rawRow.workspace_uris));
        const parentID = string(rawRow.parent_conversation_id).trim();
        const lastModified = parseSummaryTime(string(rawRow.last_modified_time));
        const lastUserInput = parseSummaryTime(string(rawRow.last_user_input_time));
        const revision = `${title}\0${preview}\0${project}\0${parentID}\0${lastModified}\0${lastUserInput}`;
        out.set(id, { title, preview, project, parentID, lastModified, lastUserInput, revision });
      }
      return out;
    });
    summaryCache.set(dbPath, { stamp: combinedStamp, rows });
    return rows;
  } catch (error) {
    onError?.(`${dbPath}: ${String(error)}`);
    return cached?.rows ?? new Map();
  }
}

async function readConversationDB(dbPath: string): Promise<{
  calls: DBCall[];
  coveredSteps: Set<number>;
  stepModels: Map<number, string>;
  firstTime: number;
  lastTime: number;
}> {
  return withReadOnlySQLite(dbPath, db => {
    const tables = new Set(
      (db.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").all() as Array<Record<string, unknown>>)
        .map(row => string(row.name))
    );
    const genModels = new Map<number, string>();
    const stepModels = new Map<number, string>();
    if (tables.has('gen_metadata')) {
      for (const row of db.prepare('SELECT idx, data FROM gen_metadata WHERE data IS NOT NULL ORDER BY idx').all() as Array<Record<string, unknown>>) {
        const idx = typeof row.idx === 'number' ? row.idx : Number(row.idx);
        const bytes = row.data instanceof Uint8Array ? row.data : null;
        if (!Number.isSafeInteger(idx) || !bytes) continue;
        const parsed = parseGeneratorMetadata(bytes);
        if (parsed.model) {
          genModels.set(idx, parsed.model);
          if (parsed.answeredStep !== undefined) stepModels.set(parsed.answeredStep, parsed.model);
        }
      }
    }
    const calls: DBCall[] = [];
    const coveredSteps = new Set<number>();
    const byResponse = new Map<string, number>();
    let firstTime = Number.POSITIVE_INFINITY;
    let lastTime = 0;
    if (tables.has('steps')) {
      for (const row of db.prepare('SELECT idx, metadata FROM steps WHERE metadata IS NOT NULL ORDER BY idx').all() as Array<Record<string, unknown>>) {
        const idx = typeof row.idx === 'number' ? row.idx : Number(row.idx);
        const bytes = row.metadata instanceof Uint8Array ? row.metadata : null;
        if (!Number.isSafeInteger(idx) || !bytes) continue;
        const parsed = parseStepMetadata(idx, bytes);
        if (parsed.time > 0) {
          firstTime = Math.min(firstTime, parsed.time);
          lastTime = Math.max(lastTime, parsed.time);
        }
        const model = genModels.get(parsed.gen) ?? '';
        if (model) stepModels.set(idx, model);
        if (!parsed.call) continue;
        parsed.call.model = model || stepModels.get(idx) || '';
        coveredSteps.add(idx);
        if (parsed.call.response) {
          const prev = byResponse.get(parsed.call.response);
          if (prev !== undefined) {
            calls[prev] = parsed.call;
            continue;
          }
          byResponse.set(parsed.call.response, calls.length);
        }
        calls.push(parsed.call);
      }
    }
    return { calls, coveredSteps, stepModels, firstTime, lastTime };
  });
}

async function readTranscript(path: string, warnings: string[]): Promise<{
  steps: Map<number, TranscriptStep>;
  promptTitle: string;
  firstTime: number;
  lastTime: number;
}> {
  const steps = new Map<number, TranscriptStep>();
  let promptTitle = '';
  let firstTime = Number.POSITIVE_INFINITY;
  let lastTime = 0;
  const stream = createReadStream(path, { encoding: 'utf8' });
  let pending = '';

  const processLine = (line: string, isTrailing: boolean) => {
    const trimmed = line.trim();
    if (!trimmed) return;
    let record: Data;
    try {
      record = object(JSON.parse(trimmed));
    } catch {
      warnings.push(isTrailing ? '尾部记录尚未写完，下次扫描重试' : '存在无法解析的完整 JSONL 记录');
      return;
    }
    const time = timestamp(record.created_at);
    if (time > 0) {
      firstTime = Math.min(firstTime, time);
      lastTime = Math.max(lastTime, time);
    }
    if (!promptTitle && record.source === 'USER_EXPLICIT' && record.type === 'USER_INPUT') {
      promptTitle = extractUserRequest(string(record.content));
    }
    const stepIndex = record.step_index;
    if (
      record.source === 'MODEL' &&
      record.type === 'PLANNER_RESPONSE' &&
      typeof stepIndex === 'number' &&
      Number.isSafeInteger(stepIndex) &&
      stepIndex >= 0 &&
      typeof record.input_tokens === 'number' &&
      typeof record.output_tokens === 'number'
    ) {
      const input = number(record.input_tokens);
      const output = number(record.output_tokens);
      const cacheRead = number(record.cache_read_tokens);
      const cacheWrite = number(record.cache_write_tokens ?? record.cache_creation_tokens);
      if (input + output + cacheRead + cacheWrite > 0 && time > 0) {
        steps.set(stepIndex, {
          stepIndex,
          time,
          model: normalizeGeminiModel(string(record.model)),
          input,
          output,
          cacheRead,
          cacheWrite,
        });
      } else {
        steps.delete(stepIndex);
      }
    }
  };

  try {
    for await (const chunk of stream) {
      pending += String(chunk);
      let end: number;
      while ((end = pending.indexOf('\n')) >= 0) {
        const line = pending.slice(0, end);
        pending = pending.slice(end + 1);
        processLine(line, false);
      }
    }
  } finally {
    stream.destroy();
  }
  if (pending.trim()) processLine(pending, true);
  return { steps, promptTitle, firstTime, lastTime };
}

async function isDataDir(path: string): Promise<boolean> {
  for (const name of ['conversations', 'brain']) {
    try {
      if ((await stat(join(path, name))).isDirectory()) return true;
    } catch {}
  }
  try {
    if ((await stat(join(path, 'conversation_summaries.db'))).isFile()) return true;
  } catch {}
  return false;
}

async function discoverDataDirs(rootPath: string): Promise<string[]> {
  const dirs: string[] = [];
  if (await isDataDir(rootPath)) dirs.push(rootPath);
  for (const sub of KNOWN_SUBDIRS) {
    const candidate = join(rootPath, sub);
    try {
      if ((await stat(candidate)).isDirectory()) dirs.push(candidate);
    } catch (error) {
      if (object(error).code !== 'ENOENT') throw error;
    }
  }
  return [...new Set(dirs)];
}

async function discoverConversations(dataDir: string): Promise<Map<string, { dbPath?: string; transcriptPath?: string }>> {
  const found = new Map<string, { dbPath?: string; transcriptPath?: string }>();
  try {
    const entries = await readdir(join(dataDir, 'conversations'), { withFileTypes: true });
    for (const entry of entries) {
      if (entry.isSymbolicLink() || !entry.isFile() || !entry.name.endsWith('.db')) continue;
      const id = entry.name.slice(0, -3);
      if (!SAFE_CONVERSATION_ID.test(id)) continue;
      found.set(id, { ...found.get(id), dbPath: join(dataDir, 'conversations', entry.name) });
    }
  } catch (error) {
    if (object(error).code !== 'ENOENT') throw error;
  }
  try {
    const entries = await readdir(join(dataDir, 'brain'), { withFileTypes: true });
    for (const entry of entries) {
      if (entry.isSymbolicLink() || !entry.isDirectory() || !SAFE_CONVERSATION_ID.test(entry.name)) continue;
      const transcriptPath = join(dataDir, 'brain', entry.name, '.system_generated', 'logs', 'transcript_full.jsonl');
      try {
        const info = await stat(transcriptPath);
        if (info.isFile()) found.set(entry.name, { ...found.get(entry.name), transcriptPath });
      } catch (error) {
        if (object(error).code !== 'ENOENT') throw error;
      }
    }
  } catch (error) {
    if (object(error).code !== 'ENOENT') throw error;
  }
  return found;
}

async function parseAntigravityConversation(
  dataDir: string,
  nativeID: string,
  files: { dbPath?: string; transcriptPath?: string },
  summary: SummaryRow | undefined,
  birthtimeMs: number,
  mtimeMs: number,
): Promise<Session> {
  const warnings: string[] = [];
  let firstTime = Number.POSITIVE_INFINITY;
  let lastTime = 0;
  let dbCalls: DBCall[] = [];
  let coveredSteps = new Set<number>();
  let stepModels = new Map<number, string>();

  if (files.dbPath) {
    try {
      const dbData = await readConversationDB(files.dbPath);
      dbCalls = dbData.calls;
      coveredSteps = dbData.coveredSteps;
      stepModels = dbData.stepModels;
      firstTime = Math.min(firstTime, dbData.firstTime);
      lastTime = Math.max(lastTime, dbData.lastTime);
    } catch (error) {
      if (!files.transcriptPath && !summary) throw error;
      warnings.push(`会话数据库无法读取：${String(error)}`);
    }
  }

  let promptTitle = '';
  let transcriptSteps = new Map<number, TranscriptStep>();
  if (files.transcriptPath) {
    const trData = await readTranscript(files.transcriptPath, warnings);
    transcriptSteps = trData.steps;
    promptTitle = trData.promptTitle;
    firstTime = Math.min(firstTime, trData.firstTime);
    lastTime = Math.max(lastTime, trData.lastTime);
  }

  const usage: Usage[] = [];
  for (const call of dbCalls) {
    const model = call.model || transcriptSteps.get(call.stepIndex)?.model || '';
    usage.push({
      id: call.response || `step:${call.stepIndex}`,
      time: call.time,
      model,
      input: call.input,
      output: call.output,
      cacheRead: call.cacheRead,
      cacheWrite: call.cacheWrite,
    });
  }
  for (const [stepIndex, trCall] of transcriptSteps) {
    if (coveredSteps.has(stepIndex)) continue;
    usage.push({
      id: `step:${stepIndex}`,
      time: trCall.time,
      model: stepModels.get(stepIndex) || trCall.model || '',
      input: trCall.input,
      output: trCall.output,
      cacheRead: trCall.cacheRead,
      cacheWrite: trCall.cacheWrite,
    });
  }
  usage.sort((a, b) => a.time - b.time);

  const title = summary?.title || summary?.preview || promptTitle || nativeID;
  const created = Number.isFinite(firstTime)
    ? firstTime
    : (summary?.lastUserInput || summary?.lastModified || birthtimeMs);
  const updated = Math.max(lastTime, summary?.lastModified ?? 0) || mtimeMs;

  return {
    id: sessionKey('antigravity', `${dataDir}\0${nativeID}`),
    nativeID,
    source: 'antigravity',
    title,
    project: summary?.project ?? '',
    home: dataDir,
    created,
    updated,
    ...(summary?.parentID ? { parentID: summary.parentID } : {}),
    usage,
    warnings: [...new Set(warnings)],
  };
}

export async function scanAntigravity(
  rootPath: string,
  onSession?: (session: Session) => void | Promise<void>,
  onError?: (message: string) => void,
): Promise<Session[]> {
  const results: Session[] = [];
  let dataDirs: string[];
  try {
    dataDirs = await discoverDataDirs(rootPath);
  } catch (error) {
    onError?.(`${rootPath}: ${String(error)}`);
    return results;
  }

  for (const dataDir of dataDirs) {
    let conversations: Map<string, { dbPath?: string; transcriptPath?: string }>;
    try {
      conversations = await discoverConversations(dataDir);
    } catch (error) {
      onError?.(`${dataDir}: ${String(error)}`);
      continue;
    }
    if (conversations.size === 0) continue;
    const summaries = await readSummaries(dataDir, onError);

    for (const [nativeID, files] of conversations) {
      const key = `${dataDir}\0${nativeID}`;
      try {
        const dbStamp = files.dbPath ? await fileStamp(files.dbPath) : null;
        const walStamp = files.dbPath ? await fileStamp(`${files.dbPath}-wal`) : null;
        const trStamp = files.transcriptPath ? await fileStamp(files.transcriptPath) : null;
        if (!dbStamp && !trStamp) continue;
        const summary = summaries.get(nativeID);
        const fingerprint = `${dbStamp?.stamp ?? ''}|${walStamp?.stamp ?? ''}|${trStamp?.stamp ?? ''}|${summary?.revision ?? ''}`;
        if (onSession && conversationFingerprints.get(key) === fingerprint) continue;

        const birthtimes = [dbStamp?.birthtimeMs, trStamp?.birthtimeMs].filter((v): v is number => v !== undefined && v > 0);
        const mtimes = [dbStamp?.mtimeMs, walStamp?.mtimeMs, trStamp?.mtimeMs].filter((v): v is number => v !== undefined && v > 0);
        const session = await parseAntigravityConversation(
          dataDir,
          nativeID,
          files,
          summary,
          birthtimes.length ? Math.min(...birthtimes) : Date.now(),
          mtimes.length ? Math.max(...mtimes) : Date.now(),
        );
        if (onSession) {
          await onSession(session);
          conversationFingerprints.set(key, fingerprint);
        } else {
          results.push(session);
        }
      } catch (error) {
        onError?.(`${files.dbPath ?? files.transcriptPath ?? dataDir}: ${String(error)}`);
      }
    }
  }
  return results;
}
