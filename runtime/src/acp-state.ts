import type { Session, Data } from './types.ts';
import { object, string, content } from './types.ts';

export function applyUpdate(session: Session, update: Data, fallbackID: string): { idle: boolean } {
  const type = string(update.sessionUpdate ?? update.type);
  if (['agent_message_chunk', 'agent_message', 'user_message_chunk', 'user_message'].includes(type)) {
    const id = string(update.messageId, fallbackID), role = type.startsWith('user') ? 'user' : 'assistant';
    const existing = session.messages.find(m => m.id === id);
    const text = content(update.content);
    if (existing) {
      if (type.endsWith('chunk')) existing.text += text;
      else if ('content' in update) existing.text = text;
    } else session.messages.push({ id, role, text, time: Date.now(), kind: 'text' });
  }
  if (type === 'tool_call' || type === 'tool_call_update') {
    const id = string(update.toolCallId, fallbackID);
    const existing = session.messages.find(m => m.id === id);
    const text = `${string(update.title)}\n${content(update.content ?? update.rawInput ?? update.rawOutput)}`;
    if (existing) { if (text.trim()) existing.text = text; }
    else session.messages.push({ id, role: 'tool', text, time: Date.now(), kind: 'tool' });
  }
  if (type === 'terminal_output_chunk') {
    const id = `terminal:${string(update.terminalId, fallbackID)}`, text = string(update.data ?? update.output);
    const existing = session.messages.find(m => m.id === id);
    if (existing) existing.text += text;
    else session.messages.push({ id, role: 'tool', text, time: Date.now(), kind: 'tool' });
  }
  if (type === 'plan_update' || type === 'plan') {
    const id = 'agent:plan', text = content(update.entries ?? update.plan);
    const existing = session.messages.find(m => m.id === id);
    if (existing) existing.text = text;
    else session.messages.push({ id, role: 'tool', text, time: Date.now(), kind: 'tool' });
  }
  if (type === 'session_info_update' && typeof update.title === 'string') session.title = update.title;
  if (type === 'notice') session.warnings = [...new Set([...session.warnings, `${string(update.title)} ${string(update.description)}`])];
  const state = string(update.state ?? object(update.state).type);
  return { idle: type === 'state_update' && state === 'idle' };
}
