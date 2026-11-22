import { Table, tx } from '../core/db.js';
import type { ActivitySpan, Id, Ms } from '../core/types.js';
import { invalid, newId } from '../core/util.js';
import type { Deps } from './crud.js';
import type { Tasks } from './tasks.js';

export interface ActivitySummary { byApp: { app: string; ms: number }[]; byTask: { taskId: Id; title: string; ms: number }[]; focusMs: number; switches: number }

export function createActivity({ db }: Deps, tasks: Tasks) {
  const table = new Table<ActivitySpan>(db, 'activity', {
    id: 's', app: 's', bundleId: 's', title: 's', startAt: 'n', endAt: 'n', idle: 'b', sessionId: 's', taskId: 's',
  });

  const list = (from: Ms = 0, to: Ms = Number.MAX_SAFE_INTEGER): ActivitySpan[] =>
    table.where('WHERE endAt > ? AND startAt < ? ORDER BY startAt', from, to);

  return {
    list,

    /** Stores sensor spans. Non-idle time is attributed to the task in `doing` at ingest, unless the span names one. */
    ingest(spans: unknown): number {
      if (!Array.isArray(spans)) throw invalid('spans must be an array');
      const currentTask = tasks.current()?.id ?? null;
      tx(db, () => {
        for (const raw of spans) {
          const given = table.pick(raw, ['id']);
          if (!given.app || given.startAt == null || given.endAt == null || given.endAt < given.startAt) throw invalid('a span needs app, startAt and endAt');
          table.insert({ id: newId(), bundleId: null, title: null, idle: false, sessionId: null, taskId: given.idle ? null : currentTask, ...given } as ActivitySpan);
        }
      });
      return spans.length;
    },

    /** Time per app and per task inside [from, to], clipped to the range. `switches` counts app changes. */
    summary(from: Ms = 0, to: Ms = Date.now()): ActivitySummary {
      const byApp = new Map<string, number>();
      const byTask = new Map<Id, number>();
      let focusMs = 0;
      let switches = 0;
      let lastApp: string | null = null;
      for (const s of list(from, to)) {
        if (s.idle) continue;
        const ms = Math.min(s.endAt, to) - Math.max(s.startAt, from);
        focusMs += ms;
        byApp.set(s.app, (byApp.get(s.app) ?? 0) + ms);
        if (s.taskId) byTask.set(s.taskId, (byTask.get(s.taskId) ?? 0) + ms);
        if (lastApp !== null && lastApp !== s.app) switches++;
        lastApp = s.app;
      }
      const desc = (a: { ms: number }, b: { ms: number }) => b.ms - a.ms;
      return {
        byApp: [...byApp].map(([app, ms]) => ({ app, ms })).sort(desc),
        byTask: [...byTask].map(([taskId, ms]) => ({ taskId, title: tasks.get(taskId)?.title ?? '', ms })).sort(desc),
        focusMs,
        switches,
      };
    },
  };
}
