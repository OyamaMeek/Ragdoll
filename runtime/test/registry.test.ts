import { test } from 'node:test';
import assert from 'node:assert/strict';
import { safePath, pinnedPackage, validateAgent } from '../src/registry.ts';

test('archive paths cannot escape installation root', () => {
  assert.equal(safePath('/install/agent', './bin/agent'), '/install/agent/bin/agent');
  assert.throws(() => safePath('/install/agent', '../../outside'));
  assert.throws(() => safePath('/install/agent', '/etc/passwd'));
});

test('registry packages require an exact version', () => {
  assert.equal(pinnedPackage('@agentclientprotocol/codex-acp@2.6.0', '2.6.0', false), '@agentclientprotocol/codex-acp@2.6.0');
  assert.equal(pinnedPackage('agent==1.2.3', '1.2.3', true), 'agent==1.2.3');
  assert.throws(() => pinnedPackage('agent@latest', '1.2.3', false));
  assert.throws(() => pinnedPackage('https://example.com/agent', '1.2.3', false));
});

test('registry rejects invalid metadata before any installation', () => {
  assert.throws(() => validateAgent({ id: '../x', version: '1.0.0', name: 'bad', distribution: {} }));
  assert.equal(validateAgent({ id: 'codex-acp', name: 'Codex', version: '2.6.0', distribution: { npx: { package: '@agentclientprotocol/codex-acp@2.6.0' } } }).id, 'codex-acp');
});
