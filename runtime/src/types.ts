export type Source = 'codex' | 'claude' | 'dsh' | 'desktop' | 'acp';
export type Data = Record<string, unknown>;
export interface Usage { id: string; time: number; model: string; input: number; output: number; cacheRead: number; cacheWrite: number }
export interface Session {
  id: string; nativeID: string; source: Source; title: string; project: string; home: string;
  created: number; updated: number; parentID?: string; provider?: string;
  usage: Usage[]; warnings: string[];
  nativeSource?: string;
}
export interface Location { source: 'codex' | 'claude' | 'dsh'; path: string }
export const object = (value: unknown): Data => value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Data : {};
export const string = (value: unknown, fallback = ''): string => typeof value === 'string' ? value : fallback;
export const number = (value: unknown): number => typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : 0;
export function timestamp(value: unknown): number {
  if (typeof value === 'number') return value < 1e11 ? value * 1000 : value;
  const parsed = Date.parse(string(value));
  return Number.isFinite(parsed) ? parsed : 0;
}
export function content(value: unknown): string {
  if (typeof value === 'string') return value;
  if (Array.isArray(value)) return value.map(content).filter(Boolean).join('\n');
  const v = object(value);
  if (typeof v.text === 'string') return v.text;
  if (v.content !== undefined) return content(v.content);
  if (v.type === 'tool_use' || v.type === 'tool_call') return `${string(v.name)}\n${JSON.stringify(v.input ?? v.arguments, null, 2)}`;
  if (Object.keys(v).length) return JSON.stringify(v, null, 2);
  return '';
}
