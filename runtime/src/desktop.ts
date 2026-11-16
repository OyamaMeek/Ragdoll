import { readFile, writeFile, mkdir, rename } from 'node:fs/promises';
import { join } from 'node:path';
import { unzipSync } from 'fflate';
import { object, string, timestamp, content } from './types.ts';
import { sessionKey } from './logs.ts';
import type { Session } from './types.ts';

export function importConversations(value: unknown): Session[] {
  if (!Array.isArray(value)) throw new Error('请选择包含 conversations.json 的 Claude 官方导出包');
  return value.map(record => {
    const v = object(record);
    if (!string(v.uuid) || !Array.isArray(v.chat_messages)) throw new Error('导出记录缺少 uuid 或 chat_messages');
    const session: Session = {
      id: sessionKey('desktop', string(v.uuid)), nativeID: string(v.uuid), source: 'desktop',
      title: string(v.name, 'Claude 聊天'), project: '', home: '',
      created: timestamp(v.created_at), updated: timestamp(v.updated_at), messages: [], usage: [], files: [],
      warnings: ['普通聊天用量不可用；此记录在导入后不会实时同步'],
    };
    for (const item of v.chat_messages) {
      const m = object(item);
      session.messages.push({ id: string(m.uuid, String(session.messages.length)), role: m.sender === 'human' ? 'user' : 'assistant', text: content(m.content) || string(m.text), time: timestamp(m.created_at), kind: 'text' });
      if ((Array.isArray(m.attachments) && m.attachments.length) || (Array.isArray(m.files) && m.files.length)) session.warnings.push('原始上传附件未包含在官方导出包中');
    }
    session.warnings = [...new Set(session.warnings)];
    return session;
  });
}

export async function importDesktop(path: string, root: string): Promise<Session[]> {
  const data = await readFile(path);
  let value: unknown;
  if (path.toLowerCase().endsWith('.zip')) {
    const files = unzipSync(data, { filter: entry => /(^|\/)conversations\.json$/.test(entry.name) && entry.originalSize < 512 * 1024 * 1024 });
    const found = Object.values(files)[0];
    if (!found) throw new Error('导出包中未找到 conversations.json');
    value = JSON.parse(new TextDecoder().decode(found));
  } else value = JSON.parse(data.toString('utf8'));
  const sessions = importConversations(value);
  await mkdir(root, { recursive: true });
  for (const [index, session] of sessions.entries()) {
    const file = join(root, session.id.replace(':', '_') + '.json');
    await writeFile(file + '.writing', JSON.stringify((value as unknown[])[index], null, 2));
    await rename(file + '.writing', file);
    session.files = [file];
  }
  return sessions;
}
