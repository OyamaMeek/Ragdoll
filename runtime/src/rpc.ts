import { spawn } from 'node:child_process';
import type { ChildProcessWithoutNullStreams } from 'node:child_process';
import { constants } from 'node:fs';
import { access } from 'node:fs/promises';
import { createInterface } from 'node:readline';
import { object, string } from './types.ts';
import type { AgentConfig, Data } from './types.ts';

export function childEnvironment(env: Record<string, string> = {}): NodeJS.ProcessEnv {
  const result: NodeJS.ProcessEnv = { ...process.env, PATH: `${process.env.PATH || ''}:/opt/homebrew/bin:/usr/local/bin`, ...env };
  delete result.ELECTRON_RUN_AS_NODE;
  return result;
}

export async function openCodexAppServer(agent: Pick<AgentConfig, 'id' | 'command' | 'args' | 'env'>, cwd: string): Promise<RpcProcess> {
  const args = [...agent.args, 'app-server'];
  if (process.platform === 'darwin' && agent.id === 'native-codex' && agent.command === 'codex' && agent.env?.PATH === undefined) {
    const desktopCommand = '/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex';
    if (await access(desktopCommand, constants.X_OK).then(() => true, () => false)) {
      return new RpcProcess(desktopCommand, args, cwd, agent.env);
    }
  }
  return new RpcProcess(agent.command, args, cwd, agent.env);
}

export class RpcProcess {
  readonly child: ChildProcessWithoutNullStreams;
  private serial = 0;
  private pending = new Map<string, { resolve: (v: unknown) => void; reject: (e: Error) => void; timer?: NodeJS.Timeout }>();
  private stderr = '';
  onNotification: (method: string, params: Data) => void = () => {};
  onRequest: (method: string, params: Data) => Promise<unknown> = async method => { throw new Error(`不支持代理请求：${method}`); };
  onExit: (message: string) => void = () => {};
  private stopped = false;

  constructor(command: string, args: string[], cwd: string, env: Record<string, string> = {}) {
    if (!command || command.includes('\0')) throw new Error('请设置有效程序路径');
    this.child = spawn(command, args, { cwd, env: childEnvironment(env), stdio: 'pipe', detached: true });
    this.child.stderr.on('data', data => { this.stderr = (this.stderr + String(data)).slice(-4000); });
    this.child.on('error', error => this.fail(error));
    this.child.on('exit', (code, signal) => {
      this.fail(new Error(`代理进程已退出 (${code ?? signal})：${this.stderr}`));
      if (!this.stopped) this.onExit(`代理进程已退出 (${code ?? signal})`);
    });
    const input = createInterface({ input: this.child.stdout });
    input.on('line', line => {
      let message: Data;
      try { message = object(JSON.parse(line)); }
      catch { this.fail(new Error('代理 stdout 包含无效 JSON-RPC 数据')); void this.close(); return; }
      if ('method' in message) {
        if ('id' in message) {
          void this.onRequest(string(message.method), object(message.params)).then(
            result => this.write({ jsonrpc: '2.0', id: message.id, result }),
            error => this.write({ jsonrpc: '2.0', id: message.id, error: { code: -32603, message: String(error) } }),
          );
        } else this.onNotification(string(message.method), object(message.params));
      } else if ('id' in message) {
        const key = String(message.id), pending = this.pending.get(key);
        if (!pending) return;
        this.pending.delete(key); clearTimeout(pending.timer);
        if (message.error) pending.reject(new Error(JSON.stringify(message.error)));
        else pending.resolve(message.result);
      }
    });
  }
  private write(message: unknown): void {
    if (this.child.stdin.destroyed) return;
    this.child.stdin.write(JSON.stringify(message) + '\n');
  }
  request(method: string, params: unknown = {}, timeout = 30000): Promise<unknown> {
    if (this.stopped) return Promise.reject(new Error('代理进程已经停止'));
    const id = ++this.serial;
    return new Promise((resolve, reject) => {
      const timer = timeout > 0 ? setTimeout(() => { this.pending.delete(String(id)); reject(new Error(`代理请求超时：${method}`)); }, timeout) : undefined;
      this.pending.set(String(id), { resolve, reject, timer });
      this.write({ jsonrpc: '2.0', id, method, params });
    });
  }
  notify(method: string, params: unknown = {}): void { this.write({ jsonrpc: '2.0', method, params }); }
  private fail(error: Error): void {
    for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(error); }
    this.pending.clear();
  }
  async close(): Promise<void> {
    if (this.stopped) return;
    this.stopped = true; this.child.stdin.end();
    const pid = this.child.pid;
    if (pid && this.child.exitCode === null && this.child.signalCode === null) {
      try { process.kill(-pid, 'SIGTERM'); } catch { /* 进程已经退出。 */ }
      const timer = setTimeout(() => { try { process.kill(-pid, 'SIGKILL'); } catch { /* 进程已经退出。 */ } }, 3000);
      timer.unref();
      await new Promise<void>(resolve => { if (this.child.exitCode !== null || this.child.signalCode !== null) resolve(); else this.child.once('exit', () => resolve()); });
      clearTimeout(timer);
    }
    this.fail(new Error('执行已停止'));
  }
}
