import { readFile } from 'node:fs/promises';
import { isAbsolute, join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { setTimeout } from 'node:timers/promises';
import { createParser } from 'eventsource-parser';
import { object, string } from './types.ts';

let warmingUp = false;
const responseLimit = 1024 * 1024;

export function parseCodexQuota(value: unknown, now = Date.now() / 1000) {
  const rate = object(object(value).rate_limit);
  const windows = [rate.primary_window, rate.secondary_window].filter(value => value != null).map(value => {
    const window = object(value);
    const { used_percent: used, limit_window_seconds: seconds, reset_at: reset } = window;
    if (typeof used !== 'number' || !Number.isFinite(used) || used < 0 || used > 100 ||
        typeof seconds !== 'number' || !Number.isInteger(seconds) || seconds <= 0 ||
        typeof reset !== 'number' || !Number.isFinite(reset) || reset < 0) throw new Error('Codex 额度窗口数据无效');
    return { used, seconds, reset };
  });
  if (!windows.length) throw new Error('无法读取 Codex 额度状态');
  const fiveHour = windows.find(window => window.seconds === 18000);
  if (!fiveHour) throw new Error('此账号未返回 5h 额度窗口，不支持激活');
  return {
    active: fiveHour.used > 0 && fiveHour.reset > now,
    exhausted: windows.some(window => window.used >= 100 && window.reset > now),
    resetAt: fiveHour.reset,
  };
}

async function* responseChunks(response: Response) {
  if (!response.body) throw new Error('Codex 返回空响应');
  const reader = response.body.getReader();
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) return;
      size += value.byteLength;
      if (size > responseLimit) throw new Error('Codex 响应超过 1 MiB 上限');
      yield value;
    }
  } finally { await reader.cancel(); reader.releaseLock(); }
}

export async function readWarmupCompletion(response: Response): Promise<void> {
  if (!response.headers.get('content-type')?.includes('text/event-stream')) {
    await response.body?.cancel();
    throw new Error('Codex 未返回 SSE 推理响应');
  }
  let completed = false;
  const parser = createParser({ onEvent(event) {
    if (completed) return;
    let value: unknown;
    try { value = JSON.parse(event.data); } catch { throw new Error('Codex 推理事件不是有效 JSON'); }
    const data = object(value), type = string(data.type);
    if (['response.completed', 'response.done'].includes(type) && object(data.response).status === 'completed') completed = true;
    else if (['response.completed', 'response.done', 'response.failed', 'response.incomplete', 'response.cancelled', 'response.canceled', 'error'].includes(type)) {
      throw new Error('Codex 推理未成功完成；请求不会自动重试，请检查额度或登录状态');
    }
  } });
  const decoder = new TextDecoder();
  for await (const chunk of responseChunks(response)) {
    parser.feed(decoder.decode(chunk, { stream: true }));
    if (completed) return;
  }
  throw new Error('Codex 响应未包含完整的成功完成事件；请先检查额度，避免重复发送');
}

async function officialRequest(path: string, headers: Record<string, string>, body?: string) {
  const response = await fetch(`https://chatgpt.com/backend-api/${path}`, {
    method: body ? 'POST' : 'GET', headers, body, redirect: 'error',
    signal: AbortSignal.timeout(body ? 45000 : 15000),
  }).catch(() => { throw new Error('Codex 网络请求失败或超时；请检查网络，请求不会自动重试'); });
  if (!response.ok) {
    await response.body?.cancel();
    const guidance = response.status === 401 || response.status === 403 ? '请在 Codex 中重新登录对应账号' : '请检查网络与账号额度';
    throw new Error(`Codex 请求失败（HTTP ${response.status}），${guidance}；请求不会自动重试`);
  }
  return response;
}

async function readQuota(headers: Record<string, string>) {
  const response = await officialRequest('wham/usage', headers);
  const chunks: Uint8Array[] = [];
  for await (const chunk of responseChunks(response)) chunks.push(chunk);
  let value: unknown;
  try { value = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { throw new Error('Codex 额度响应不是有效 JSON'); }
  return parseCodexQuota(value);
}

export async function warmupCodex(home: string) {
  if (!home || !isAbsolute(home)) throw new Error('请选择有效的 Codex 绝对目录');
  if (warmingUp) throw new Error('正在激活 Codex 窗口，请等待当前请求结束');
  warmingUp = true;
  try {
    let auth: unknown;
    try { auth = JSON.parse(await readFile(join(home, 'auth.json'), 'utf8')); }
    catch { throw new Error('无法读取 Codex 登录信息，请在该目录对应的 Codex 中重新登录'); }
    const tokens = object(object(auth).tokens);
    const accessToken = string(tokens.access_token), accountID = string(tokens.account_id);
    if (!accessToken || !accountID) throw new Error('此目录缺少 ChatGPT 登录凭据；API Key 账号不支持 5h 窗口，请通过 Codex 登录');
    if (/\s/.test(accessToken) || /\s/.test(accountID)) throw new Error('Codex 登录凭据格式无效，请重新登录');
    const headers = {
      Authorization: `Bearer ${accessToken}`, 'ChatGPT-Account-Id': accountID,
      'User-Agent': 'codex_cli_rs/0.159.0', Originator: 'codex_cli_rs', Version: '0.159.0',
    };
    const before = await readQuota(headers);
    if (before.exhausted) return { status: 'exhausted', message: 'Codex 额度已耗尽，请等待额度重置；未发送激活请求。' };
    if (before.active) return { status: 'alreadyActive', message: '5h 窗口已经激活，未发送额外请求。', resetAt: before.resetAt };
    // shortcut: 上游不支持 max_output_tokens，使用固定短回复提示及传输上限；支持该参数后改用服务端输出预算。
    const body = JSON.stringify({
      model: 'gpt-5.6-sol', stream: true, store: false,
      input: [
        { type: 'additional_tools', role: 'developer', tools: [] },
        { type: 'message', role: 'developer', content: [{ type: 'input_text', text: 'Reply exactly hello, using at most 8 output tokens.' }] },
        { type: 'message', role: 'user', content: [{ type: 'input_text', text: 'hello' }] },
      ],
      reasoning: { effort: 'none', summary: 'auto', context: 'all_turns' },
      text: { verbosity: 'low' }, parallel_tool_calls: false, tool_choice: 'auto',
    });
    try {
      await readWarmupCompletion(await officialRequest('codex/responses', {
        ...headers, Accept: 'text/event-stream', 'Content-Type': 'application/json',
        'session-id': randomUUID(), 'x-openai-internal-codex-responses-lite': 'true',
      }, body));
    } catch (error) {
      throw new Error(`激活请求未确认完成，可能已消耗额度；不会自动重试。${error instanceof Error ? error.message : '网络错误'}`);
    }
    await setTimeout(1500);
    try {
      const after = await readQuota(headers);
      if (after.active) return { status: 'activated', message: '5h 窗口已激活，额度状态已刷新。', resetAt: after.resetAt };
      return { status: 'requestSent', message: '激活请求已完成，服务端尚未确认 5h 窗口；请稍后再次检查。' };
    } catch {
      return { status: 'requestSent', message: '激活请求已完成，但重新读取额度失败；尚未确认 5h 窗口，请稍后检查网络和登录状态。' };
    }
  } finally { warmingUp = false; }
}
