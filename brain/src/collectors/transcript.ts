import { closeSync, existsSync, fstatSync, openSync, readdirSync, readSync } from 'node:fs';
import { join } from 'node:path';
import type { Ms, SessionTurn } from '../core/types.js';
import { isPlainObject } from '../core/util.js';
import { clip } from './settings.js';

/** What a Claude Code transcript says about its session. Every field is "latest wins" except `firstPrompt`. */
export interface Derived {
  firstPrompt: string | null;
  lastUserPrompt: string | null;
  lastAssistantText: string | null;
  /** Follows `cd`, unlike the session file's launch dir. */
  cwd: string | null;
  aiTitle: string | null;
  lastAt: Ms | null;
}

export interface TailState { ino: number; offset: number; derived: Derived }

export const emptyDerived = (): Derived => ({ firstPrompt: null, lastUserPrompt: null, lastAssistantText: null, cwd: null, aiTitle: null, lastAt: null });

const PROMPT_MAX = 1200;
const TEXT_MAX = 2000;
const COLD_TAIL = 512 * 1024;
const HEAD_SCAN = 1024 * 1024;
const MAX_DELTA = 4 * 1024 * 1024;
const WANTED = new Set(['user', 'assistant', 'system', 'ai-title', 'last-prompt']);

function textOf(content: unknown): string {
  if (typeof content === 'string') return content.trim();
  if (!Array.isArray(content)) return '';
  const parts: string[] = [];
  for (const block of content) {
    if (!isPlainObject(block)) continue;
    if (block.type === 'tool_result') return '';
    if (block.type === 'text' && typeof block.text === 'string') parts.push(block.text);
  }
  return parts.join('\n').trim();
}

/** One transcript line as an object, or null for torn lines, sub-agent rows and line types that carry nothing for us. */
function rowOf(line: string): Record<string, unknown> | null {
  // Bookkeeping lines lead with their type; request blobs and attachments are about half the bytes, so drop them unparsed.
  const head = /^\{"type":"([a-z-]+)"/.exec(line);
  if (head ? !WANTED.has(head[1]!) : !line.startsWith('{') || line.includes('"type":"attachment"')) return null;
  let row: unknown;
  try {
    row = JSON.parse(line);
  } catch {
    return null;
  }
  return isPlainObject(row) && row.isSidechain !== true ? row : null;
}

/** What a person typed in a `user` row, or '' when the row is a tool result, a command wrapper or a system notice. */
function typedText(row: Record<string, unknown>): string {
  const origin = isPlainObject(row.origin) ? row.origin.kind : undefined;
  const typed = row.isMeta !== true && !('toolUseResult' in row) && (origin === undefined || origin === 'human') && row.promptSource !== 'system';
  const text = typed ? textOf(isPlainObject(row.message) ? row.message.content : undefined) : '';
  // "<..." is a command or notification wrapper, not something the user typed.
  return text.startsWith('<') ? '' : text;
}

/** Folds one JSONL line into `d`. Unparseable (torn) lines and line types that carry nothing for us are skipped. */
export function foldLine(d: Derived, line: string): void {
  const row = rowOf(line);
  if (!row) return;
  const message = isPlainObject(row.message) ? row.message : {};

  if (row.type === 'ai-title') {
    if (typeof row.aiTitle === 'string' && row.aiTitle.trim()) d.aiTitle = row.aiTitle.trim();
    return;
  }
  if (row.type === 'last-prompt') {
    if (typeof row.lastPrompt === 'string' && row.lastPrompt.trim()) d.lastUserPrompt = clip(row.lastPrompt.trim(), PROMPT_MAX);
    return;
  }
  if (row.type === 'user') {
    const text = typedText(row);
    if (text) {
      d.lastUserPrompt = clip(text, PROMPT_MAX);
      d.firstPrompt ??= d.lastUserPrompt;
    }
  } else if (row.type === 'assistant') {
    const text = textOf(message.content);
    if (text) d.lastAssistantText = clip(text, TEXT_MAX);
  } else if (row.type !== 'system') {
    return;
  }
  if (typeof row.cwd === 'string' && row.cwd) d.cwd = row.cwd;
  const at = typeof row.timestamp === 'string' ? Date.parse(row.timestamp) : NaN;
  if (at) d.lastAt = at;
}

const TURN_TEXT_MAX = 6000;
const TURNS_TAIL = 1536 * 1024;

/** "Read ×3 · Bash · Edit ×2", in order of first use. */
function burstLine(names: string[]): string {
  const counts = new Map<string, number>();
  for (const name of names) counts.set(name, (counts.get(name) ?? 0) + 1);
  return [...counts].map(([name, n]) => (n > 1 ? `${name} ×${n}` : name)).join(' · ');
}

/**
 * The conversation in `lines` as a person would read it back: what they typed, what the assistant said, and each
 * run of tool calls between two pieces of text folded into one `tools` entry. Keeps the last `limit` prompts and
 * replies (tool lines ride along and do not count).
 */
export function turnsOf(lines: string[], limit = 30): { items: SessionTurn[]; truncated: boolean } {
  const all: SessionTurn[] = [];
  let burst: string[] = [];
  let burstAt: Ms | null = null;
  const flush = (): void => {
    if (burst.length) all.push({ role: 'tools', at: burstAt, text: burstLine(burst) });
    burst = [];
    burstAt = null;
  };
  for (const line of lines) {
    const row = rowOf(line);
    if (!row || (row.type !== 'user' && row.type !== 'assistant')) continue;
    const at = (typeof row.timestamp === 'string' && Date.parse(row.timestamp)) || null;
    if (row.type === 'user') {
      const text = typedText(row);
      if (!text) continue;
      flush();
      all.push({ role: 'user', at, text: clip(text, TURN_TEXT_MAX) });
      continue;
    }
    const content = isPlainObject(row.message) ? row.message.content : undefined;
    const text = typeof content === 'string' ? content.trim()
      : Array.isArray(content) ? content.filter((b): b is { type: 'text'; text: string } => isPlainObject(b) && b.type === 'text' && typeof b.text === 'string').map((b) => b.text).join('\n').trim() : '';
    if (text) {
      flush();
      all.push({ role: 'assistant', at, text: clip(text, TURN_TEXT_MAX) });
    }
    if (Array.isArray(content)) {
      for (const block of content) {
        if (!isPlainObject(block) || block.type !== 'tool_use' || typeof block.name !== 'string') continue;
        // A connector tool reads as its server and verb, not as its wire name.
        burst.push(block.name.startsWith('mcp__') ? block.name.split('__').slice(1).join(' ').replace(/^claude_ai_/, '').replace(/_/g, ' ') : block.name);
        burstAt ??= at;
      }
    }
  }
  flush();
  let spoken = 0;
  let start = all.length;
  while (start > 0 && spoken < limit) if (all[--start]!.role !== 'tools') spoken++;
  // A tail must not open on the tool calls of a reply that was cut off.
  while (start < all.length && all[start]!.role === 'tools') start++;
  return { items: all.slice(start), truncated: start > 0 };
}

/** The tail of a transcript file as turns. Reads at most the last 1.5 MB, so a week-long session costs the same as a short one. */
export function readTurns(path: string, limit = 30): { items: SessionTurn[]; truncated: boolean } {
  const fd = openSync(path, 'r');
  try {
    const size = fstatSync(fd).size;
    const from = Math.max(0, size - TURNS_TAIL);
    const lines = read(fd, from, size).toString('utf8').split('\n');
    // The first line of a mid-file read is the end of a line that started earlier.
    if (from > 0) lines.shift();
    const out = turnsOf(lines, limit);
    return { items: out.items, truncated: out.truncated || from > 0 };
  } finally {
    closeSync(fd);
  }
}

/** Where Claude Code keeps a session's transcript: under the launch directory's slug, or (after a resume elsewhere) under another one. */
export function findTranscript(claudeDir: string, sessionId: string, cwd: string): string | null {
  const projects = join(claudeDir, 'projects');
  const direct = join(projects, cwd.replace(/[^A-Za-z0-9]/g, '-'), `${sessionId}.jsonl`);
  if (existsSync(direct)) return direct;
  try {
    for (const slug of readdirSync(projects)) {
      const path = join(projects, slug, `${sessionId}.jsonl`);
      if (existsSync(path)) return path;
    }
  } catch { /* no projects dir */ }
  return null;
}

function read(fd: number, from: number, to: number): Buffer {
  const buf = Buffer.allocUnsafe(Math.max(0, to - from));
  return buf.subarray(0, readSync(fd, buf, 0, buf.length, from));
}

/**
 * Advances a transcript tail to the file's current end and returns the new state (`prev` itself when
 * nothing whole was appended). Only complete lines are consumed: the CLI appends while we read, so the
 * last line is often torn and is picked up on the next call.
 *
 * A first read, a rotated file or a huge backlog starts from the last 512 KB plus a scan of the head
 * for the first prompt, so history is never parsed in full.
 */
export function readTail(path: string, st: { ino: number; size: number }, prev: TailState | null): TailState {
  const fd = openSync(path, 'r');
  try {
    let state = prev;
    if (!state || state.ino !== st.ino || st.size < state.offset) {
      state = { ino: st.ino, offset: Math.max(0, st.size - COLD_TAIL), derived: emptyDerived() };
      if (state.offset > 0) {
        const head = emptyDerived();
        for (const line of read(fd, 0, Math.min(st.size, HEAD_SCAN)).toString('utf8').split('\n')) {
          foldLine(head, line);
          if (head.firstPrompt) break;
        }
        state.derived.firstPrompt = head.firstPrompt;
      }
    } else if (st.size - state.offset > MAX_DELTA) {
      state = { ...state, offset: st.size - COLD_TAIL };
    }
    const chunk = read(fd, state.offset, st.size);
    const end = chunk.lastIndexOf(10);
    if (end === -1) return state;
    const derived = { ...state.derived };
    for (const line of chunk.toString('utf8', 0, end).split('\n')) foldLine(derived, line);
    return { ino: st.ino, offset: state.offset + end + 1, derived };
  } finally {
    closeSync(fd);
  }
}
