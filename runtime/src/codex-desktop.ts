import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { readFile, realpath } from 'node:fs/promises';
import { isAbsolute, join } from 'node:path';
import { object, string } from './types.ts';
import type { Data } from './types.ts';

export interface DesktopMessage {
  nativeID: string;
  home: string;
  project: string;
  title: string;
  text: string;
}

export async function readScheduledMessage(root: string, id: string, attemptID: string): Promise<DesktopMessage> {
  if (!isAbsolute(root) || !id || !attemptID) throw new Error('定时消息计划参数无效');
  let value: unknown;
  try { value = JSON.parse(await readFile(join(root, 'codex-scheduled-message.json'), 'utf8')); }
  catch { throw new Error('无法读取定时消息计划，未发送消息'); }
  const state = object(object(value)[id]);
  if (state.enabled !== true || state.attemptID !== attemptID) throw new Error('消息计划已取消或本次授权已失效');
  const target = object(state.target);
  if (!/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(string(target.nativeID)) ||
      !isAbsolute(string(target.home)) || !isAbsolute(string(target.project)) ||
      typeof target.text !== 'string' || !target.text.trim() || typeof target.title !== 'string') {
    throw new Error('定时消息计划的会话、项目或消息无效');
  }
  return { nativeID: string(target.nativeID), home: string(target.home), project: string(target.project), title: target.title, text: target.text };
}

export class CodexDesktopClient {
  private readonly child;
  private readonly lines;
  private serial = 0;
  private stopped = false;
  private readonly pending = new Map<number, { resolve: (value: Data) => void; reject: (error: Error) => void; timer: NodeJS.Timeout }>();

  private constructor(home: string) {
    // shortcut: 队列和唤醒依赖桌面端当前原生接口，接口变更时更新接入。
    this.child = spawn('/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex', ['app-server'], {
      env: { ...process.env, CODEX_HOME: home }, stdio: ['pipe', 'pipe', 'ignore'],
    });
    this.lines = createInterface({ input: this.child.stdout });
    this.child.on('error', () => this.fail('无法启动桌面端内置 Codex，请检查 ChatGPT 安装'));
    this.child.on('exit', () => this.fail('桌面端 Codex 队列助手已退出；消息不会自动重试'));
    this.child.stdin.on('error', () => this.fail('无法写入桌面端 Codex 队列助手'));
    this.lines.on('line', line => {
      let message: Data;
      try { message = object(JSON.parse(line)); }
      catch { this.fail('桌面端 Codex 返回无效数据'); return; }
      if (typeof message.id !== 'number') return;
      const request = this.pending.get(message.id);
      if (!request) return;
      this.pending.delete(message.id); clearTimeout(request.timer);
      if (message.error != null) request.reject(new Error('桌面端不支持此队列操作或找不到会话，请检查桌面端版本和原会话'));
      else if (message.result == null || typeof message.result !== 'object') request.reject(new Error('桌面端 Codex 队列结果无效'));
      else request.resolve(object(message.result));
    });
  }

  static async connect(home: string): Promise<CodexDesktopClient> {
    if (!isAbsolute(home)) throw new Error('Codex 桌面端数据目录无效');
    const client = new CodexDesktopClient(home);
    try {
      await client.request('initialize', { clientInfo: { name: 'ragdoll_queue', version: '0.1.0' }, capabilities: { experimentalApi: true } });
      client.child.stdin.write(JSON.stringify({ method: 'initialized' }) + '\n');
      return client;
    } catch (error) { await client.close(); throw error; }
  }

  request(method: string, params: Data): Promise<Data> {
    if (this.stopped) return Promise.reject(new Error('桌面端 Codex 队列助手不可用'));
    const id = ++this.serial;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error('桌面端 Codex 队列请求超时，请先检查原会话；消息不会自动重试'));
      }, 15000);
      this.pending.set(id, { resolve, reject, timer });
      this.child.stdin.write(JSON.stringify({ id, method, params }) + '\n');
    });
  }

  private fail(message: string) {
    this.stopped = true;
    for (const request of this.pending.values()) { clearTimeout(request.timer); request.reject(new Error(message)); }
    this.pending.clear();
  }

  async close() {
    this.fail('桌面端 Codex 队列连接已关闭');
    this.lines.close();
    this.child.stdin.end();
    if (!this.child.pid || this.child.exitCode != null || this.child.signalCode != null) return;
    await new Promise<void>(resolve => {
      const timer = setTimeout(() => { this.child.kill('SIGKILL'); }, 2000);
      this.child.once('exit', () => { clearTimeout(timer); resolve(); });
      this.child.kill();
    });
  }
}

export async function queueDesktopMessage(target: DesktopMessage, attemptID: string, beforeSend: () => Promise<void>): Promise<string> {
  const client = await CodexDesktopClient.connect(target.home);
  try {
    const thread = object((await client.request('thread/read', { threadId: target.nativeID, includeTurns: false })).thread);
    if (thread.id !== target.nativeID || typeof thread.cwd !== 'string' || await realpath(thread.cwd) !== await realpath(target.project)) {
      throw new Error('原会话与所选项目不一致，未发送消息');
    }
    await beforeSend();
    let cursor: string | undefined;
    do {
      const page = await client.request('thread/queue/list', { threadId: target.nativeID, limit: 100, cursor });
      if (!Array.isArray(page.data) || (page.nextCursor != null && typeof page.nextCursor !== 'string')) throw new Error('桌面端队列列表无效，未发送消息');
      const previous = page.data.map(object).find(item => item.clientUserMessageId === attemptID);
      if (previous) {
        const input = Array.isArray(previous.input) ? previous.input : [];
        if (!string(previous.id) || input.length !== 1 || object(input[0]).type !== 'text' || object(input[0]).text !== target.text) throw new Error('桌面端已有消息与本次计划不一致，请检查原会话');
        return string(previous.id);
      }
      if (page.nextCursor === cursor && cursor != null) throw new Error('桌面端队列分页无效，未发送消息');
      cursor = typeof page.nextCursor === 'string' ? page.nextCursor : undefined;
    } while (cursor);
    await beforeSend();
    const result = await client.request('thread/queue/add', {
      threadId: target.nativeID, clientUserMessageId: attemptID,
      input: [{ type: 'text', text: target.text, text_elements: [] }],
    });
    const receipt = object(result.queuedSubmission);
    if (receipt.clientUserMessageId !== attemptID || !string(receipt.id)) throw new Error('未能确认桌面端收到消息，请先检查原会话');
    return string(receipt.id);
  } finally { await client.close(); }
}
