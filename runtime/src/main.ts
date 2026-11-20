import { createInterface } from 'node:readline';
import { watch } from 'node:fs';
import type { FSWatcher } from 'node:fs';
import { once } from 'node:events';
import { scan, defaultLocations } from './logs.ts';
import { object, string } from './types.ts';
import type { Data, Location } from './types.ts';

const output = (value: unknown) => process.stdout.write(JSON.stringify(value) + '\n');
const emit = (event: string, data: unknown) => output({ event, data });
let watchers: FSWatcher[] = [];
let scanActive = false;
let changeTimer: NodeJS.Timeout | undefined;

function watchLocations(locations: Location[]): void {
  for (const watcher of watchers) watcher.close();
  watchers = [];
  for (const location of locations) {
    try {
      const watcher = watch(location.path, { recursive: true }, () => {
        clearTimeout(changeTimer); changeTimer = setTimeout(() => emit('sourceChanged', {}), 1500);
      });
      watcher.on('error', error => emit('warning', `目录监听失败：${String(error)}`));
      watchers.push(watcher);
    } catch (error) { if (object(error).code !== 'ENOENT') emit('warning', `目录监听失败：${String(error)}`); }
  }
}

async function handle(method: string, params: Data): Promise<unknown> {
  if (method === 'initialize') return { version: '0.1.0', locations: defaultLocations() };
  if (method === 'scan') {
    if (scanActive) throw new Error('正在扫描，请稍后重试');
    const locations = params.locations === undefined ? defaultLocations() : params.locations;
    if (!Array.isArray(locations) || locations.some(value => !['codex', 'claude', 'dsh'].includes(string(object(value).source)) || !string(object(value).path))) throw new Error('扫描目录配置无效');
    scanActive = true;
    try {
      watchLocations(locations as Location[]);
      let count = 0;
      await scan(locations as Location[], async session => {
        count++;
        if (!emit('session', session)) await once(process.stdout, 'drain');
      }, error => emit('warning', error));
      return { count };
    } finally { scanActive = false; }
  }
  if (method === 'shutdown') {
    for (const watcher of watchers) watcher.close();
    clearTimeout(changeTimer);
    return {};
  }
  throw new Error(`未知助手方法：${method}`);
}

if (process.argv.includes('--self-check')) {
  output({ status: 'ok', version: '0.1.0', node: process.version, mode: 'usage-only' });
} else {
  const input = createInterface({ input: process.stdin });
  input.on('line', line => {
    let request: Data;
    try {
      request = object(JSON.parse(line));
      if ((typeof request.id !== 'number' && typeof request.id !== 'string') || typeof request.method !== 'string') throw new Error('请求必须包含 id 和 method');
    } catch (error) {
      output({ id: null, error: { status: 'error', type: 'InvalidRequest', message: String(error), suggestion: '发送有效的 NDJSON 请求' } });
      return;
    }
    void handle(request.method as string, object(request.params)).then(
      result => output({ id: request.id, result }),
      error => output({ id: request.id, error: { status: 'error', type: error instanceof Error ? error.name : 'RuntimeError', message: String(error), suggestion: '检查数据来源目录与运行日志后重试' } }),
    );
  });
  input.on('close', () => {
    for (const watcher of watchers) watcher.close();
    clearTimeout(changeTimer);
  });
}
