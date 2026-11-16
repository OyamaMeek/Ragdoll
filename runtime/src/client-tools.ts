import { readFile, writeFile, rename, realpath } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { spawn } from 'node:child_process';
import type { ChildProcessWithoutNullStreams } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { object, string, number } from './types.ts';
import { childEnvironment } from './rpc.ts';
import type { Data } from './types.ts';

export type Ask = (method: string, params: Data, signal?: AbortSignal) => Promise<Data>;

export class ClientTools {
  private terminals = new Map<string, { child: ChildProcessWithoutNullStreams; output: string; done: Promise<unknown>; status?: Data }>();
  private cwd: string;
  private ask: Ask;
  constructor(cwd: string, ask: Ask) { this.cwd = cwd; this.ask = ask; }
  private async path(value: unknown): Promise<string> {
    if (typeof value !== 'string') throw new Error('缺少文件路径');
    const path = resolve(this.cwd, value), root = await realpath(this.cwd);
    const target = await realpath(path).catch(async error => { if (object(error).code !== 'ENOENT') throw error; return resolve(await realpath(dirname(path)), path.split('/').at(-1)!); });
    if (target !== root && !target.startsWith(root + '/')) throw new Error('文件路径超出当前项目授权范围');
    return target;
  }
  async handle(method: string, p: Data, signal?: AbortSignal): Promise<unknown> {
    if (method === 'fs/read_text_file') {
      const data = await readFile(await this.path(p.path), 'utf8');
      const start = Math.max(0, number(p.line || 1) - 1);
      return { content: data.split('\n').slice(start, p.limit ? start + number(p.limit) : undefined).join('\n') };
    }
    if (method === 'fs/write_text_file') {
      const path = await this.path(p.path);
      if ((await this.ask(method, p, signal)).allowed !== true) throw new Error('用户拒绝写入文件');
      if (typeof p.content !== 'string') throw new Error('文件内容必须为文本');
      const temp = `${path}.ragdoll-${randomUUID()}`;
      await writeFile(temp, p.content); await rename(temp, path); return {};
    }
    if (method === 'terminal/create') {
      const cwd = await this.path(p.cwd ?? this.cwd);
      if ((await this.ask(method, p, signal)).allowed !== true) throw new Error('用户拒绝执行命令');
      if (typeof p.command !== 'string' || !Array.isArray(p.args ?? []) || (p.args as unknown[] | undefined)?.some(v => typeof v !== 'string')) throw new Error('命令参数无效');
      const id = randomUUID();
      const env: Record<string, string> = {};
      for (const value of Array.isArray(p.env) ? p.env : []) { const pair = object(value); if (typeof pair.name === 'string' && typeof pair.value === 'string') env[pair.name] = pair.value; }
      const child = spawn(p.command, p.args as string[] ?? [], { cwd, env: childEnvironment(env), stdio: 'pipe', detached: true });
      const entry: { child: ChildProcessWithoutNullStreams; output: string; done: Promise<unknown>; status?: Data } = { child, output: '', done: Promise.resolve() };
      const append = (data: Buffer) => { entry.output = (entry.output + data.toString()).slice(-256000); };
      child.stdout.on('data', append); child.stderr.on('data', append);
      entry.done = new Promise(resolve => {
        child.on('error', error => { entry.output += String(error); entry.status = { exitCode: 1 }; resolve(entry.status); });
        child.on('exit', (exitCode, signal) => { entry.status = { exitCode, signal }; resolve(entry.status); });
      });
      this.terminals.set(id, entry); return { terminalId: id };
    }
    if (method.startsWith('terminal/')) {
      const id = string(p.terminalId), entry = this.terminals.get(id);
      if (!entry) throw new Error('未知终端');
      if (method === 'terminal/output') return { output: entry.output, truncated: entry.output.length >= 256000, exitStatus: entry.status };
      if (method === 'terminal/wait_for_exit') return await entry.done;
      if (method === 'terminal/kill' || method === 'terminal/release') {
        await this.terminate(entry);
        if (method === 'terminal/release') this.terminals.delete(id);
        return {};
      }
    }
    throw new Error(`不支持的客户端方法：${method}`);
  }
  private async terminate(entry: { child: ChildProcessWithoutNullStreams; done: Promise<unknown>; status?: Data }): Promise<void> {
    const pid = entry.child.pid;
    if (entry.status || !pid || entry.child.exitCode !== null || entry.child.signalCode !== null) return;
    try { process.kill(-pid, 'SIGTERM'); } catch {}
    const timer = setTimeout(() => { try { process.kill(-pid, 'SIGKILL'); } catch {} }, 3000);
    try { await entry.done; try { process.kill(-pid, 'SIGKILL'); } catch {} }
    finally { clearTimeout(timer); }
  }
  async close(): Promise<void> {
    await Promise.all([...this.terminals.values()].map(entry => this.terminate(entry)));
    this.terminals.clear();
  }
}
