import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, writeFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { codexAccounts, parseCodexAccounts, parseCodexSwitchResult, checkAutomaticAttempt } from '../src/codex-accounts.ts';

test('automatic Codex activation rechecks persisted consent and rejects canceled or stale attempts', async t => {
  const base = join(import.meta.dirname, '../../.cache');
  await mkdir(base, { recursive: true });
  const root = await mkdtemp(join(base, 'codex-auto-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const path = join(root, 'codex-auto-activation.json');
  const persist = (enabled: boolean, attemptID: string) => writeFile(path, JSON.stringify({ a: { enabled, attemptID } }));
  await persist(true, 'current');
  await checkAutomaticAttempt(root, 'a', 'current');
  await assert.rejects(checkAutomaticAttempt(root, 'a', 'old'), /关闭|失效/);
  await persist(false, 'current');
  await assert.rejects(checkAutomaticAttempt(root, 'a', 'current'), /关闭|失效/);
  await writeFile(path, 'broken');
  await assert.rejects(checkAutomaticAttempt(root, 'a', 'current'), /状态/);
});

test('Codex account summaries validate identities and quota while excluding credentials', () => {
  const input = [{ id: 'account-a', label: 'Work', email: 'work@example.com', planType: 'plus', sourceKind: 'chatgpt', isCurrent: true,
    authJson: { access_token: 'PRIVATE_TOKEN' }, usage: { fetchedAt: 100, fiveHour: { usedPercent: 12, windowSeconds: 18000, resetAt: 200 }, oneWeek: null },
  }];
  const [account] = parseCodexAccounts(input);
  assert.equal(account.id, 'account-a');
  assert.equal(account.isCurrent, true);
  assert.equal(account.fiveHour?.usedPercent, 12);
  assert.equal(account.oneWeek, null);
  assert.equal(JSON.stringify(account).includes('PRIVATE_TOKEN'), false);
  assert.throws(() => parseCodexAccounts({ accounts: input }), /账号/);
  assert.throws(() => parseCodexAccounts([...input, ...input]), /重复/);
  assert.throws(() => parseCodexAccounts([{ ...input[0], id: '' }]), /账号/);
  assert.throws(() => parseCodexAccounts([{ ...input[0], id: '--launch' }]), /账号/);
  assert.throws(() => parseCodexAccounts([{ ...input[0], isCurrent: 'true' }]), /账号/);
  assert.throws(() => parseCodexAccounts([{ ...input[0], usage: { fiveHour: { usedPercent: -1, windowSeconds: 18000, resetAt: 200 } } }]), /额度/);
  assert.equal(parseCodexAccounts([{ ...input[0], usageError: 'PRIVATE_TOKEN' }])[0].usageError?.includes('PRIVATE_TOKEN'), false);
});

test('Codex switch results verify selected account and expose incomplete preservation', () => {
  const result = { account: { id: 'a', label: 'A', isCurrent: true, sourceKind: 'chatgpt' }, localProjectPreservation: { status: 'verified', warning: null } };
  assert.equal(parseCodexSwitchResult(result, 'a').status, 'switched');
  assert.throws(() => parseCodexSwitchResult(result, 'b'), /切换/);
  assert.throws(() => parseCodexSwitchResult({ ...result, account: { ...result.account, isCurrent: false } }, 'a'), /切换/);
  assert.equal(parseCodexSwitchResult({ ...result, localProjectPreservation: { status: 'pending', warning: 'PRIVATE_TOKEN' } }, 'a').status, 'attention');
  assert.equal(parseCodexSwitchResult({ ...result, providerSyncError: 'PRIVATE_TOKEN' }, 'a').message.includes('PRIVATE_TOKEN'), false);
});

test('Codex account actions reject unknown methods and missing IDs before launching tools', async () => {
  await assert.rejects(codexAccounts('delete', ''), /操作/);
  await assert.rejects(codexAccounts('warmup', ''), /账号/);
  await assert.rejects(codexAccounts('switch', ''), /账号/);
});

test('live Codex Tools account summaries', { skip: !process.env.RAGDOLL_CODEX_ACCOUNTS_LIVE, timeout: 90000 }, async () => {
  const result = await codexAccounts('refresh', '');
  assert.ok(result.accounts.length >= 2);
  assert.equal(result.accounts.filter(account => account.isCurrent).length, 1);
  assert.equal(JSON.stringify(result).includes('authJson'), false);
  console.log(JSON.stringify(result.accounts.map(account => ({ id: account.id, isCurrent: account.isCurrent, hasQuota: !!account.fiveHour, usageError: account.usageError }))));
});

test('live Codex accounts warm up independently without switching the active login', { skip: !process.env.RAGDOLL_CODEX_ACCOUNTS_WARMUP_LIVE, timeout: 360000 }, async () => {
  const before = (await codexAccounts('list', '')).accounts;
  const current = before.find(account => account.isCurrent)?.id;
  assert.ok(current);
  assert.equal(before.length, 2);
  for (const account of before) {
    const result = await codexAccounts('warmup', account.id);
    assert.ok('status' in result && typeof result.status === 'string' && ['activated', 'alreadyActive', 'exhausted', 'requestSent'].includes(result.status));
    assert.equal(result.accounts.find(account => account.isCurrent)?.id, current);
    console.log(JSON.stringify({ id: account.id, status: 'status' in result ? result.status : null, message: 'message' in result ? result.message : null }));
  }
});
