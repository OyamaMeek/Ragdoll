import { mkdir, readFile, writeFile, rename, rm, chmod, readdir, stat } from 'node:fs/promises';
import { resolve, isAbsolute, join, basename, dirname } from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { unzipSync } from 'fflate';
import { x as extractTar, t as listTar } from 'tar';
import { object, string } from './types.ts';
import type { Data, AgentConfig } from './types.ts';

const exec = promisify(execFile);
const registryURL = 'https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json';
export interface RegistryAgent { id: string; name: string; version: string; description: string; repository: string; license: string; license_url: string; distribution: Data }

export function safePath(root: string, path: string): string {
  const full = resolve(root, path);
  if (!path || isAbsolute(path) || !full.startsWith(resolve(root) + '/') || path.includes('\0') || path.split(/[\\/]/).includes('..')) throw new Error(`不安全的安装路径：${path}`);
  return full;
}

export function pinnedPackage(spec: string, version: string, python: boolean): string {
  if (!/^\d+\.\d+\.\d+(?:[-.][a-zA-Z0-9.-]+)?$/.test(version)) throw new Error('Registry 缺少有效版本');
  if (python) {
    const match = /^([a-zA-Z0-9][a-zA-Z0-9._-]*)(?:==([^\s]+))?$/.exec(spec);
    if (!match || (match[2] && match[2] !== version)) throw new Error('Python 包必须使用目录中的精确版本');
    return `${match[1]}==${version}`;
  }
  const match = /^(@[a-z0-9._-]+\/[a-z0-9._-]+|[a-z0-9._-]+)(?:@([^\s]+))?$/.exec(spec);
  if (!match || (match[2] && match[2] !== version)) throw new Error('npm 包必须使用目录中的精确版本');
  return `${match[1]}@${version}`;
}

export function validateAgent(value: unknown): RegistryAgent {
  const v = object(value);
  if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(string(v.id)) || !string(v.name) || !/^\d+\.\d+\.\d+/.test(string(v.version)) || !Object.keys(object(v.distribution)).length) throw new Error('无效的 ACP Registry 条目');
  return { id: string(v.id), name: string(v.name), version: string(v.version), description: string(v.description), repository: string(v.repository), license: string(v.license), license_url: string(v.license_url), distribution: object(v.distribution) };
}

export async function registry(): Promise<RegistryAgent[]> {
  const response = await fetch(registryURL, { signal: AbortSignal.timeout(30000) });
  if (!response.ok) throw new Error(`Registry 请求失败：HTTP ${response.status}`);
  const body = object(await response.json());
  if (!Array.isArray(body.agents)) throw new Error('Registry 缺少 agents 列表');
  return body.agents.map(validateAgent);
}

export async function extractArchive(data: Uint8Array, url: string, root: string): Promise<void> {
  if (/\.zip(?:\?|$)/i.test(url)) {
    let declared = 0;
    const entries = unzipSync(data, { filter: file => { declared += file.originalSize; if (declared > 1024 * 1024 * 1024) throw new Error('解压文件超过 1 GiB'); return true; } });
    let total = 0;
    for (const [path, bytes] of Object.entries(entries)) {
      const full = safePath(root, path);
      total += bytes.length;
      if (total > 1024 * 1024 * 1024) throw new Error('解压文件超过 1 GiB');
      if (path.endsWith('/')) { await mkdir(full, { recursive: true }); continue; }
      await mkdir(dirname(full), { recursive: true });
      await writeFile(full, bytes, { flag: 'wx' });
    }
    return;
  }
  const archive = join(root, '.archive');
  await writeFile(archive, data);
  let total = 0;
  let invalid: Error | undefined;
  await listTar({ file: archive, strict: true, onReadEntry: entry => {
    if (entry.path === './' || entry.path === '.') return;
    try {
      safePath(root, entry.path);
      if (!['File', 'Directory', 'ExtendedHeader', 'GlobalExtendedHeader'].includes(entry.type)) throw new Error('安装包不允许符号链接或硬链接');
      total += entry.size;
      if (total > 1024 * 1024 * 1024) throw new Error('解压文件超过 1 GiB');
    } catch (error) { invalid = error instanceof Error ? error : new Error(String(error)); }
  } });
  if (invalid) throw invalid;
  await extractTar({ file: archive, cwd: root, strict: true, preservePaths: false });
  await rm(archive);
}

function literalArgs(value: unknown): string[] {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.some(v => typeof v !== 'string')) throw new Error('Agent 参数必须为字符串数组');
  return value as string[];
}

export async function install(agentValue: unknown, tools: string): Promise<AgentConfig> {
  const agent = validateAgent(agentValue);
  const parent = safePath(tools, agent.id), target = safePath(parent, agent.version);
  const stage = safePath(parent, `.install-${randomUUID()}`);
  await mkdir(stage, { recursive: true });
  let directTarget = false;
  try {
    let command: string, args: string[], env: Record<string, string> = {};
    const binary = object(object(agent.distribution.binary)['darwin-aarch64']);
    if (binary.archive) {
      const url = new URL(string(binary.archive));
      if (url.protocol !== 'https:') throw new Error('安装包必须使用 HTTPS');
      const response = await fetch(url, { signal: AbortSignal.timeout(120000) });
      if (!response.ok) throw new Error(`下载失败：HTTP ${response.status}`);
      if (!response.body) throw new Error('安装包响应为空');
      const reader = response.body.getReader(), chunks: Uint8Array[] = [];
      let length = 0;
      while (true) {
        const chunk = await reader.read(); if (chunk.done) break;
        length += chunk.value.length;
        if (length > 512 * 1024 * 1024) { await reader.cancel(); throw new Error('安装包超过 512 MiB'); }
        chunks.push(chunk.value);
      }
      const bytes = Buffer.concat(chunks);
      if (binary.sha256) {
        if (!/^[a-f0-9]{64}$/i.test(string(binary.sha256)) || createHash('sha256').update(bytes).digest('hex') !== string(binary.sha256).toLowerCase()) throw new Error('安装包 SHA-256 校验失败');
      }
      const archive = /\.(zip|tar\.gz|tgz|tar\.bz2|tbz2)(?:\?|$)/i.test(url.pathname);
      const relative = string(binary.cmd);
      safePath(stage, relative);
      if (archive) await extractArchive(bytes, url.href, stage);
      else { await mkdir(dirname(safePath(stage, relative)), { recursive: true }); await writeFile(safePath(stage, relative), bytes); }
      await chmod(safePath(stage, relative), 0o755);
      command = safePath(target, relative); args = literalArgs(binary.args);
      for (const [key, value] of Object.entries(object(binary.env))) {
        if (typeof value !== 'string') throw new Error('Agent 环境变量必须为字符串');
        env[key] = value;
      }
    } else if (agent.distribution.npx) {
      const distribution = object(agent.distribution.npx);
      const spec = pinnedPackage(string(distribution.package), agent.version, false);
      const npm = join(dirname(process.execPath), '../lib/node_modules/npm/bin/npm-cli.js');
      const npmExists = await stat(npm).then(() => true, () => false);
      const npmCommand = npmExists ? process.execPath : 'npm';
      const prefix = npmExists ? [npm] : [];
      await exec(npmCommand, [...prefix, 'install', '--prefix', stage, '--cache', join(tools, '.npm-cache'), '--ignore-scripts', '--no-audit', '--no-fund', spec], { timeout: 240000, maxBuffer: 4 * 1024 * 1024 });
      const packageName = spec.replace(/@[^@]+$/, '');
      const pkg = object(JSON.parse(await readFile(join(stage, 'node_modules', packageName, 'package.json'), 'utf8')));
      const bin = typeof pkg.bin === 'string' ? pkg.bin : Object.values(object(pkg.bin))[0];
      if (typeof bin !== 'string') throw new Error('npm 包没有可执行入口');
      const installed = join('node_modules', packageName, bin);
      safePath(stage, installed);
      command = process.execPath; args = [safePath(target, installed), ...literalArgs(distribution.args)];
    } else if (agent.distribution.uvx) {
      const distribution = object(agent.distribution.uvx);
      const spec = pinnedPackage(string(distribution.package), agent.version, true);
      await mkdir(target); directTarget = true;
      const uvEnv = { ...process.env, UV_TOOL_DIR: join(target, 'python-tools'), UV_TOOL_BIN_DIR: join(target, 'bin'), UV_CACHE_DIR: join(tools, '.uv-cache') };
      try { await exec('uv', ['tool', 'install', spec], { env: uvEnv, timeout: 240000, maxBuffer: 4 * 1024 * 1024 }); }
      catch (error) { if (object(error).code === 'ENOENT') throw new Error('需要安装 uv：请先安装 uv，再重试此 Python Agent'); throw error; }
      const entries = await readdir(join(target, 'bin'));
      const supplied = literalArgs(distribution.args);
      const entry = supplied[0] && entries.includes(supplied[0]) ? supplied.shift()! : entries[0];
      if (!entry) throw new Error('Python 包没有可执行入口');
      command = safePath(target, `bin/${entry}`); args = supplied;
    } else throw new Error('此 Agent 没有适用于 macOS Apple Silicon 的分发包');
    const config: AgentConfig = { id: agent.id, name: agent.name, kind: 'acp', command, args, env, version: agent.version, registryID: agent.id, installPath: target };
    if (directTarget) {
      await writeFile(join(target, 'ragdoll-agent.json'), JSON.stringify(config));
      await rm(stage, { recursive: true, force: true }); return config;
    }
    await writeFile(join(stage, 'ragdoll-agent.json'), JSON.stringify(config));
    try { await rename(stage, target); }
    catch (error) {
      if (object(error).code !== 'ENOTEMPTY' && object(error).code !== 'EEXIST') throw error;
      const existing = JSON.parse(await readFile(join(target, 'ragdoll-agent.json'), 'utf8')) as AgentConfig;
      await rm(stage, { recursive: true, force: true }); return existing;
    }
    return config;
  } catch (error) { await rm(stage, { recursive: true, force: true }); if (directTarget) await rm(target, { recursive: true, force: true }); throw error; }
}

export async function uninstall(config: AgentConfig, tools: string): Promise<void> {
  if (!config.registryID || !config.installPath) return;
  const parent = safePath(tools, config.registryID);
  if (!resolve(config.installPath).startsWith(parent + '/')) throw new Error('拒绝删除应用安装目录以外的文件');
  await rm(config.installPath, { recursive: true, force: true });
}
