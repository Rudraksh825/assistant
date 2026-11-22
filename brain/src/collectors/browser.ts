import { statSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import type { AppContext } from '../core/context.js';
import type { Ms } from '../core/types.js';
import { DAY, MIN } from '../core/util.js';
import type { SignalInput } from '../domain/records.js';
import { clip, connector, expandHome, setHealth } from './settings.js';

type BrowserConfig = { historyPath: string; everyMin: number; patterns: string[] };
export interface Visit { url: string; title: string; at: Ms }

// Chromium-family profiles under ~/Library/Application Support.
const PROFILES = ['Google/Chrome', 'Arc/User Data', 'Dia/User Data', 'BraveSoftware/Brave-Browser', 'Microsoft Edge', 'Chromium', 'Vivaldi', 'com.operasoftware.Opera']
  .flatMap((p) => [`${p}/Default/History`, `${p}/History`]);
// Chromium stores microseconds since 1601; node:sqlite cannot return those as numbers, so convert in SQL.
const EPOCH_GAP_MS = 11_644_473_600_000;

/** The configured history file, or the most recently written one among the known browsers. */
export function findHistory(configured: string, base = join(homedir(), 'Library', 'Application Support')): string | null {
  if (configured) return statSync(expandHome(configured), { throwIfNoEntry: false }) ? expandHome(configured) : null;
  let best: { path: string; mtime: number } | null = null;
  for (const rel of PROFILES) {
    const path = join(base, rel);
    const st = statSync(path, { throwIfNoEntry: false });
    if (st?.isFile() && st.mtimeMs > (best?.mtime ?? 0)) best = { path, mtime: st.mtimeMs };
  }
  return best?.path ?? null;
}

/** Visits worth a signal: one per URL per local day, query and fragment ignored. */
export function visitSignals(visits: Visit[], patterns: string[]): SignalInput[] {
  const res = patterns.flatMap((p) => {
    try {
      return [new RegExp(p, 'i')];
    } catch {
      return [];
    }
  });
  const out = new Map<string, SignalInput>();
  for (const v of visits) {
    if (!res.some((re) => re.test(v.url))) continue;
    const url = v.url.replace(/[?#].*$/, '');
    const day = new Date(v.at).toLocaleDateString('sv');
    const externalId = `${day}|${url}`;
    if (!out.has(externalId)) out.set(externalId, { source: 'browser', kind: 'visit', externalId, title: clip(v.title || url, 200), url: v.url, occurredAt: v.at });
  }
  return [...out.values()];
}

export function createBrowserCollector(ctx: AppContext) {
  const { repos } = ctx;
  const log = ctx.log.child('browser');
  let lastMtime = 0;
  let timer: NodeJS.Timeout | null = null;

  function poll(now: Ms = Date.now()): void {
    const conf = connector<BrowserConfig>(ctx, 'browser');
    const path = conf.enabled ? findHistory(conf.historyPath) : null;
    if (!path) return setHealth(ctx, 'browser', 'off');
    const mtime = statSync(path).mtimeMs;
    if (mtime === lastMtime) return;
    try {
      // The browser holds a lock on the file; an immutable read ignores it and at worst misses the last few seconds.
      const db = new DatabaseSync(`${pathToFileURL(path).href}?mode=ro&immutable=1`, { readOnly: true });
      try {
        const since = Math.max(repos.kv.get<Ms>('browser:cursor') ?? 0, now - DAY);
        const visits = db.prepare(`SELECT u.url AS url, COALESCE(u.title, '') AS title, v.visit_time / 1000 - ${EPOCH_GAP_MS} AS at
          FROM visits v JOIN urls u ON u.id = v.url WHERE v.visit_time > (? + ${EPOCH_GAP_MS}) * 1000 ORDER BY v.visit_time LIMIT 5000`).all(since) as unknown as Visit[];
        repos.signals.ingest(visitSignals(visits, conf.patterns));
        if (visits.length) repos.kv.set('browser:cursor', visits.at(-1)!.at);
      } finally {
        db.close();
      }
      lastMtime = mtime;
      repos.health.synced('browser', now);
    } catch (err) {
      repos.health.set('browser', 'error');
      log.warn('history read failed', err);
    }
  }

  return {
    poll,
    start() {
      poll();
      timer = setInterval(poll, Math.max(1, connector<BrowserConfig>(ctx, 'browser').everyMin ?? 5) * MIN);
      timer.unref();
    },
    stop() {
      if (timer) clearInterval(timer);
    },
  };
}
