import { mkdir, writeFile, readFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { randomUUID } from 'node:crypto';
import { childEnvironment } from './rpc.ts';
import { object, string } from './types.ts';
import type { AgentConfig, Data } from './types.ts';

const quote = (value: string) => `'${value.replaceAll("'", "'\\''")}'`;

export async function createTerminalAuth(agent: AgentConfig, method: Data, cwd: string, root: string): Promise<Data> {
  if (!Array.isArray(method.args ?? []) || (method.args as unknown[] | undefined)?.some(a => typeof a !== 'string')) throw new Error('终端认证参数无效');
  const dir = join(root, 'auth'); await mkdir(dir, { recursive: true });
  const path = join(dir, `${randomUUID()}.json`), script = path.replace(/\.json$/, '.command');
  await writeFile(path, JSON.stringify({ agent: { ...agent, env: {} }, method, cwd }), { mode: 0o600 });
  const main = process.env.RAGDOLL_MAIN_SCRIPT || fileURLToPath(import.meta.url).replace(/\/terminal-auth\.ts$/, '/main.ts');
  const command = [process.execPath, main, '--terminal-auth', path].map(quote).join(' ');
  await writeFile(script, `#!/bin/sh\n${command}\nresult=$?\nprintf '\\n登录进程已结束，退出码：%s\\n请返回 Ragdoll 检测连接。\\n' "$result"\nexit "$result"\n`, { mode: 0o700 });
  return { terminalScript: script };
}

export async function runTerminalAuth(path: string): Promise<number> {
  const value = object(JSON.parse(await readFile(path, 'utf8'))), agent = object(value.agent), method = object(value.method);
  let secrets: Record<string, string> = {};
  try {
    const result = await promisify(execFile)('/usr/bin/security', ['find-generic-password', '-s', 'Ragdoll.AgentEnvironment', '-a', string(agent.id), '-w']);
    secrets = JSON.parse(result.stdout.trim()) as Record<string, string>;
  } catch (error) { if (object(error).code !== 44) throw new Error('无法从钥匙串读取 Agent 环境变量'); }
  const methodEnv: Record<string, string> = {};
  if (Array.isArray(method.env)) {
    for (const value of method.env) { const v = object(value); if (typeof v.name === 'string' && typeof v.value === 'string') methodEnv[v.name] = v.value; }
  } else for (const [key, value] of Object.entries(object(method.env))) if (typeof value === 'string') methodEnv[key] = value;
  const args = [...(agent.args as string[] ?? []), ...(method.args as string[] ?? [])];
  try {
    return await new Promise<number>((resolve, reject) => {
      const child = spawn(string(agent.command), args, { cwd: string(value.cwd), stdio: 'inherit', env: childEnvironment({ ...secrets, ...methodEnv }) });
      child.on('error', reject); child.on('exit', code => resolve(code ?? 1));
    });
  } finally { await rm(path, { force: true }); }
}
