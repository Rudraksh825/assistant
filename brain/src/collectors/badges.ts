import type { AppContext } from '../core/context.js';
import type { Ms } from '../core/types.js';
import { MIN } from '../core/util.js';
import { connector, run, setHealth, type BadgeApp } from './settings.js';

export interface Badge { label: string | null; weight: number; at: Ms }
/** kv `badges`. `increasedAt` is per connector family; sync jobs compare it with their last success. */
export interface BadgeState { apps: Record<string, Badge>; increasedAt: Record<string, Ms> }

type BadgesConfig = { everySec: number; apps: BadgeApp[] };

const LSAPPINFO = '/usr/bin/lsappinfo';
const SETTLE = 45_000;
const EARLY_GAP = 3 * MIN;
const HEALTH_EVERY = 5 * MIN;
// An app that is not running answers with nothing; ask again only every few rounds.
const SKIP_ROUNDS = 4;

/**
 * `lsappinfo info -only StatusLabel <app>` prints `"StatusLabel"={ "label"="5" }`, a NULL label when the
 * app shows no badge, and nothing at all when the app is not running (label null). A badge without a
 * number ("•") counts as less than any number, so "•" then "1" is an increase.
 */
export function parseBadge(out: string): { label: string | null; weight: number } {
  if (!out.includes('StatusLabel')) return { label: null, weight: 0 };
  const label = /"label"="([^"]*)"/.exec(out)?.[1] ?? '';
  const n = parseInt(label.replace(/[^\d]/g, ''), 10);
  return { label, weight: Number.isFinite(n) ? n : label ? 0.5 : 0 };
}

/** True when the Dock says nothing new arrived for `family` since `since`, so a blind sync can be skipped. */
export function badgeQuiet(ctx: AppContext, family: string, since: Ms, now: Ms = Date.now()): boolean {
  const conf = connector<BadgesConfig>(ctx, 'badges');
  const state = ctx.repos.kv.get<BadgeState>('badges');
  if (!conf.enabled || !state || now - (ctx.repos.health.snapshot().lastSyncAt.badges ?? 0) > 2 * HEALTH_EVERY) return false;
  const running = conf.apps.some((a) => a.family === family && state.apps[a.id] && state.apps[a.id]!.label !== null);
  return running && (state.increasedAt[family] ?? 0) <= since;
}

export function createBadgeCollector(ctx: AppContext) {
  const { repos } = ctx;
  const state: BadgeState = repos.kv.get<BadgeState>('badges') ?? { apps: {}, increasedAt: {} };
  const skip = new Map<string, number>();
  const pending = new Map<string, NodeJS.Timeout>();
  const earlyAt = new Map<string, Ms>();
  let healthAt = 0;
  let polling = false;
  let timer: NodeJS.Timeout | null = null;

  // A burst of messages moves the badge several times; sync once it settles, and not back to back.
  function early(family: string): void {
    if (pending.has(family)) return;
    pending.set(family, setTimeout(() => {
      pending.delete(family);
      const ok = connector(ctx, family).enabled && ctx.agent.available() && ctx.scheduler.isWorkHours() && ctx.cost.canSpendBackground();
      if (!ok || Date.now() - (earlyAt.get(family) ?? 0) < EARLY_GAP) return;
      earlyAt.set(family, Date.now());
      // Rejects when the job is already running or not registered; either way there is nothing to do.
      try {
        ctx.scheduler.runNow(`sync:${family}`).catch(() => {});
      } catch { /* same */ }
    }, SETTLE).unref());
  }

  async function poll(now: Ms = Date.now()): Promise<void> {
    const conf = connector<BadgesConfig>(ctx, 'badges');
    if (polling) return;
    if (!conf.enabled) {
      setHealth(ctx, 'badges', 'off');
      return;
    }
    polling = true;
    try {
      let changed = false;
      let failed = false;
      await Promise.all(conf.apps.map(async (app) => {
        const wait = skip.get(app.id) ?? 0;
        if (wait > 0) return void skip.set(app.id, wait - 1);
        const res = await run(LSAPPINFO, ['info', '-only', 'StatusLabel', app.id], { timeoutMs: 4000 });
        if (res.code !== 0) return void (failed = true);
        const next = parseBadge(res.stdout);
        if (next.label === null) skip.set(app.id, SKIP_ROUNDS);
        const prev = state.apps[app.id];
        if (prev && prev.label === next.label) return;
        state.apps[app.id] = { ...next, at: now };
        changed = true;
        // The first reading is a baseline, not news.
        if (prev && next.weight > prev.weight) {
          state.increasedAt[app.family] = now;
          early(app.family);
        }
      }));
      if (changed) repos.kv.set('badges', state);
      if (failed) repos.health.set('badges', 'error');
      else if (changed || now - healthAt > HEALTH_EVERY) {
        healthAt = now;
        repos.health.synced('badges', now);
      }
    } finally {
      polling = false;
    }
  }

  return {
    poll,
    start() {
      void poll();
      timer = setInterval(() => void poll(), Math.max(5, connector<BadgesConfig>(ctx, 'badges').everySec) * 1000);
      timer.unref();
    },
    stop() {
      if (timer) clearInterval(timer);
      for (const t of pending.values()) clearTimeout(t);
    },
  };
}
