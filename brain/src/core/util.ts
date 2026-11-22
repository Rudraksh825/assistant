import { randomBytes } from 'node:crypto';
import type { Id, Ms } from './types.js';

export const MIN = 60_000;
export const HOUR = 60 * MIN;
export const DAY = 24 * HOUR;

export class HttpError extends Error {
  constructor(readonly status: number, readonly code: string, message: string) {
    super(message);
  }
}
export const notFound = (what: string) => new HttpError(404, 'not_found', `${what} not found`);
export const invalid = (message: string) => new HttpError(400, 'invalid', message);
export const conflict = (message: string) => new HttpError(409, 'conflict', message);

// UUID v7: time-ordered, so ids sort by creation.
export function newId(): Id {
  const b = randomBytes(16);
  b.writeUIntBE(Date.now(), 0, 6);
  b[6] = (b[6]! & 0x0f) | 0x70;
  b[8] = (b[8]! & 0x3f) | 0x80;
  const h = b.toString('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

/** Local-time midnight at or before `ms`. */
export function startOfDay(ms: Ms): Ms {
  const d = new Date(ms);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

export function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

/** Objects merge recursively; arrays, scalars and null replace. */
export function deepMerge<T>(base: T, patch: unknown): T {
  if (!isPlainObject(base) || !isPlainObject(patch)) return (patch === undefined ? base : patch) as T;
  const out: Record<string, unknown> = { ...base };
  for (const [k, v] of Object.entries(patch)) out[k] = deepMerge(out[k], v);
  return out as T;
}
