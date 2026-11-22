import type { AppContext } from '../core/context.js';
import type { Ms } from '../core/types.js';
import { HOUR, MIN } from '../core/util.js';

/** kv `sync:<family>` (and `triage:attempts`): where the next run starts and when it may run again. */
export interface Attempts { cursor: Ms | null; okAt: Ms | null; failures: number; retryAt: Ms; error: string | null }

export const loadAttempts = (ctx: AppContext, key: string): Attempts =>
  ctx.repos.kv.get<Attempts>(key) ?? { cursor: null, okAt: null, failures: 0, retryAt: 0, error: null };

export const MAX_BACKOFF = 6 * HOUR;
/** Wait after the n-th consecutive failure: the job's own period doubled each time, capped at six hours. */
export const backoffMs = (failures: number, everyMin: number): number => Math.min(everyMin * MIN * 2 ** failures, MAX_BACKOFF);

export function failed(ctx: AppContext, key: string, st: Attempts, everyMin: number, err: unknown, now: Ms): void {
  const failures = st.failures + 1;
  ctx.repos.kv.set(key, { ...st, failures, retryAt: now + backoffMs(failures, everyMin), error: String((err as Error)?.message ?? err).slice(0, 300) });
}
