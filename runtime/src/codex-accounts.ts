import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { readFile, realpath } from 'node:fs/promises';
import { homedir } from 'node:os';
import { isAbsolute, join } from 'node:path';
import { object, string } from './types.ts';
import { warmupCodexAuth } from './codex-warmup.ts';
import { readScheduledMessage, queueDesktopMessage } from './codex-desktop.ts';

const execute = promisify(execFile);
const toolsPath = '/Applications/Codex Tools.app/Contents/MacOS/app';
let busy = false;

function quotaWindow(value: unknown, seconds: number) {
  if (value == null) return null;
  const { usedPercent, windowSeconds, resetAt } = object(value);
  if (typeof usedPercent !== 'number' || !Number.isFinite(usedPercent) || usedPercent < 0 || usedPercent > 100 ||
      windowSeconds !== seconds || (resetAt != null && (typeof resetAt !== 'number' || !Number.isFinite(resetAt) || resetAt < 0))) {
    throw new Error('Codex 账号额度数据无效');
  }
  return { usedPercent, resetAt: typeof resetAt === 'number' ? resetAt : null };
}

export function parseCodexAccounts(value: unknown) {
  if (!Array.isArray(value)) throw new Error('Codex 账号列表格式无效');
  const ids = new Set<string>();
  return value.flatMap(value => {
    const account = object(value);
    if (account.sourceKind === 'relay') return [];
    const id = string(account.id), label = string(account.label);
    if (!id || id.startsWith('-') || !label || account.sourceKind !== 'chatgpt' || typeof account.isCurrent !== 'boolean') throw new Error('Codex 账号身份数据无效');
    if (ids.has(id)) throw new Error('Codex 账号 ID 重复');
    ids.add(id);
    const usage = object(account.usage);
    return [{
      id, label, email: string(account.email), planType: string(account.planType), isCurrent: account.isCurrent,
      fiveHour: quotaWindow(usage.fiveHour, 18000), oneWeek: quotaWindow(usage.oneWeek, 604800),
      fetchedAt: typeof usage.fetchedAt === 'number' && Number.isFinite(usage.fetchedAt) ? usage.fetchedAt : null,
      usageError: account.usageError || account.authRefreshBlocked ? '额度读取失败，请在 Codex Tools 中刷新或重新登录。' : null,
    }];
  });
}

export function parseCodexSwitchResult(value: unknown, id: string) {
  const result = object(value);
  const [account] = parseCodexAccounts([result.account]);
  if (account.id !== id || !account.isCurrent) throw new Error('未确认切换到指定 Codex 账号，请刷新列表检查');
  const preservation = object(result.localProjectPreservation);
  const attention = !!(preservation.warning || result.providerSyncError ||
    (result.localProjectPreservation != null && !['verified', 'noOp'].includes(string(preservation.status))));
  return attention
    ? { status: 'attention', message: '账号登录已切换，但历史数据同步或客户端状态仍需检查，请在 Codex Tools 中确认后使用。' }
    : { status: 'switched', message: '已切换本机登录。' };
}

async function runTools(args: string[]): Promise<unknown> {
  let stdout: string;
  try {
    const timeout = args[0] === 'switch' ? 180000 : args[0] === 'list' && !args.includes('--refresh') ? 15000 : 90000;
    ({ stdout } = await execute(toolsPath, ['cli', ...args, '--json'], { timeout, maxBuffer: 1024 * 1024, encoding: 'utf8' }));
  } catch (error) {
    const code = object(error).code;
    if (code === 'ENOENT') throw new Error('未找到 Codex Tools，请将它安装到“应用程序”后重试');
    throw new Error('Codex Tools 操作未完成，请检查其登录、配置和网络；操作不会自动重试');
  }
  try { return JSON.parse(stdout); } catch { throw new Error('Codex Tools 未返回有效 JSON，请更新后重试'); }
}

export async function checkAutomaticAttempt(root: string, id: string, attemptID: string) {
  if (!isAbsolute(root) || !id || !attemptID) throw new Error('自动激活状态参数无效');
  let states: unknown;
  try { states = JSON.parse(await readFile(join(root, 'codex-auto-activation.json'), 'utf8')); }
  catch { throw new Error('无法读取自动激活状态，未发送请求'); }
  const state = object(object(states)[id]);
  if (state.enabled !== true || state.attemptID !== attemptID) throw new Error('自动激活已关闭或本次授权已失效，未发送请求');
}

export async function codexAccounts(action: string, id: string, automatic?: { root: string; attemptID: string }) {
  if (!['list', 'refresh', 'switch', 'warmup', 'send'].includes(action)) throw new Error('不支持的 Codex 账号操作');
  if (['switch', 'warmup', 'send'].includes(action) && !id) throw new Error('请选择 Codex 账号');
  if (action === 'send' && !automatic) throw new Error('发送消息需要有效的定时消息计划');
  if (busy) throw new Error('正在处理 Codex 账号，请等待当前操作完成');
  busy = true;
  try {
    if (automatic) {
      if (action === 'send') await readScheduledMessage(automatic.root, id, automatic.attemptID);
      else await checkAutomaticAttempt(automatic.root, id, automatic.attemptID);
    }
    if (action === 'list' || action === 'refresh') {
      return { accounts: parseCodexAccounts(await runTools(action === 'refresh' ? ['list', '--refresh'] : ['list'])) };
    }
    const accounts = parseCodexAccounts(await runTools(['list']));
    if (!accounts.some(account => account.id === id)) throw new Error('找不到所选 Codex 账号，请刷新列表');
    if (action === 'switch') {
      const result = parseCodexSwitchResult(await runTools(['switch', id]), id);
      return { ...result, accounts: parseCodexAccounts(await runTools(['list'])) };
    }
    const refreshed = parseCodexAccounts(await runTools(['usage', id]));
    const account = refreshed.find(account => account.id === id);
    if (!account || account.usageError) throw new Error('无法确认此账号的额度或登录，请在 Codex Tools 中刷新或重新登录');
    if (action === 'send' && automatic) {
      if (!account.isCurrent) throw new Error('本机当前登录已改变，请切换到计划账号后重新设置');
      if (!account.fiveHour) throw new Error('无法确认此账号的 5h 额度，未发送消息');
      if (account.fiveHour.usedPercent >= 100 || (account.oneWeek?.usedPercent ?? 0) >= 100) {
        return { status: 'exhausted', message: '额度耗尽，等待服务端重置', accounts: refreshed };
      }
      const target = await readScheduledMessage(automatic.root, id, automatic.attemptID);
      if (await realpath(target.home) !== await realpath(process.env.CODEX_HOME || join(homedir(), '.codex'))) throw new Error('所选会话不在桌面端当前数据目录中，未发送消息');
      const queuedSubmissionID = await queueDesktopMessage(target, automatic.attemptID, async () => {
        if (!parseCodexAccounts(await runTools(['list'])).some(account => account.id === id && account.isCurrent)) throw new Error('本机当前登录已改变，未发送消息');
        await readScheduledMessage(automatic.root, id, automatic.attemptID);
      });
      try {
        await execute('/usr/bin/open', ['-g', `codex://threads/wake/${target.nativeID}`], { timeout: 10000 });
        return { status: 'queued', queuedSubmissionID, message: '消息已交给桌面端原会话，计划已完成；可在原会话查看排队和执行结果。', accounts: refreshed };
      } catch {
        return { status: 'queued', queuedSubmissionID, message: '消息已进入原会话队列，但无法唤醒桌面端；请手动打开原会话。计划已关闭，不会重复发送。', accounts: refreshed };
      }
    }
    let store: unknown;
    try { store = JSON.parse(await readFile(join(homedir(), 'Library/Application Support/com.carry.codex-tools/accounts.json'), 'utf8')); }
    catch { throw new Error('无法读取 Codex Tools 账号库，请更新并打开该应用检查'); }
    const stored = object(store).accounts;
    if (!Array.isArray(stored)) throw new Error('Codex Tools 账号库格式无效');
    const selected = object(stored.find(value => object(value).id === id));
    const auth = object(selected.authJson);
    if (!selected.accountId || selected.accountId !== object(auth.tokens).account_id) throw new Error('所选账号的登录身份不一致，请在 Codex Tools 中重新登录');
    const result = await warmupCodexAuth(auth, automatic ? () => checkAutomaticAttempt(automatic.root, id, automatic.attemptID) : undefined);
    try {
      await runTools(['usage', id]);
      return { ...result, accounts: parseCodexAccounts(await runTools(['list'])) };
    } catch {
      return { ...result, message: `${result.message} 账号列表刷新未完成，请手动刷新。`, accounts: accounts.map(account => account.id === id ? { ...account, usageError: '激活后的额度尚未更新，请手动刷新。' } : account) };
    }
  } finally { busy = false; }
}
