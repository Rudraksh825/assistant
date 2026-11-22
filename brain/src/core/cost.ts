import type { Bus } from './bus.js';
import type { ConfigStore } from './config.js';
import { Table, type Db } from './db.js';
import type { AgentRun, Id, Nudge } from './types.js';
import { DAY, newId, startOfDay } from './util.js';

export interface CostTotals { todayUsd: number; monthUsd: number; dailyCapUsd: number; monthlyCapUsd: number; billing: 'api' | 'login' | 'mixed' }
export interface CostReport { today: number; month: number; byDay: { day: string; usd: number }[]; byKind: { kind: string; usd: number }[]; byDayKind: { day: string; kind: string; usd: number }[] }

type RunStart = Pick<AgentRun, 'kind' | 'trigger' | 'model' | 'billing'>;
type RunEnd = { status: 'ok' | 'error' | 'cancelled' } & Partial<Pick<AgentRun, 'inputTokens' | 'outputTokens' | 'costUsd' | 'summary'>>;

export interface Cost {
  /** Open a ledger row before an LLM call. */
  start(run: RunStart): AgentRun;
  /** Close it with usage. Checks the budget and nudges at 80% and 100%. */
  finish(id: Id, end: RunEnd): AgentRun;
  /** start + finish for calls that are already over. */
  record(run: RunStart & RunEnd): AgentRun;
  runs(limit?: number): AgentRun[];
  totals(): CostTotals;
  report(days?: number): CostReport;
  /** False once a daily or monthly cap is reached: scheduled and event-driven LLM work must stop. */
  canSpendBackground(): boolean;
}

type BudgetNudge = Pick<Nudge, 'kind' | 'title' | 'body' | 'priority' | 'dedupeKey'>;

export function createCost(db: Db, bus: Bus, config: ConfigStore, nudge: (n: BudgetNudge) => void): Cost {
  const table = new Table<AgentRun>(db, 'runs', {
    id: 's', kind: 's', trigger: 's', model: 's', status: 's', inputTokens: 'n', outputTokens: 'n',
    costUsd: 'n', billing: 's', summary: 's', startedAt: 'n', endedAt: 'n',
  }, () => bus.changed('budget'));

  // Rows left 'running' belong to a previous process that died mid-run.
  db.prepare("UPDATE runs SET status = 'cancelled', endedAt = startedAt WHERE status = 'running'").run();

  const sumSince = (since: number) =>
    (db.prepare('SELECT COALESCE(SUM(costUsd), 0) AS usd FROM runs WHERE startedAt >= ?').get(since) as { usd: number }).usd;
  const monthStart = () => {
    const d = new Date(startOfDay(Date.now()));
    d.setDate(1);
    return d.getTime();
  };

  const cost: Cost = {
    start(run) {
      return table.insert({ ...run, id: newId(), status: 'running', inputTokens: 0, outputTokens: 0, costUsd: 0, summary: null, startedAt: Date.now(), endedAt: null });
    },

    finish(id, end) {
      const run = table.update(id, { ...end, endedAt: Date.now() });
      const t = cost.totals();
      const used = Math.max(t.todayUsd / t.dailyCapUsd, t.monthUsd / t.monthlyCapUsd);
      const day = new Date(startOfDay(Date.now())).toDateString();
      if (used >= 1) {
        nudge({ kind: 'budget', title: 'Budget reached', body: 'Background agent work is paused until the budget resets. Chat still works.', priority: 2, dedupeKey: `budget:100:${day}` });
      } else if (used >= 0.8) {
        nudge({ kind: 'budget', title: 'Budget at 80%', body: `$${t.todayUsd.toFixed(2)} of $${t.dailyCapUsd} today, $${t.monthUsd.toFixed(2)} of $${t.monthlyCapUsd} this month.`, priority: 1, dedupeKey: `budget:80:${day}` });
      }
      return run;
    },

    record(run) {
      const { kind, trigger, model, billing, ...end } = run;
      return cost.finish(cost.start({ kind, trigger, model, billing }).id, end);
    },

    runs(limit = 50) {
      return table.where('ORDER BY startedAt DESC LIMIT ?', limit);
    },

    totals() {
      const { budget, agent } = config.get();
      const modes = db.prepare('SELECT DISTINCT billing FROM runs WHERE startedAt >= ?').all(startOfDay(Date.now())) as { billing: 'api' | 'login' }[];
      return {
        todayUsd: sumSince(startOfDay(Date.now())),
        monthUsd: sumSince(monthStart()),
        dailyCapUsd: budget.dailyCapUsd,
        monthlyCapUsd: budget.monthlyCapUsd,
        billing: modes.length > 1 ? 'mixed' : modes[0]?.billing ?? agent.billing,
      };
    },

    report(days = 30) {
      const since = startOfDay(Date.now()) - (days - 1) * DAY;
      return {
        today: sumSince(startOfDay(Date.now())),
        month: sumSince(monthStart()),
        byDay: db.prepare("SELECT date(startedAt / 1000, 'unixepoch', 'localtime') AS day, SUM(costUsd) AS usd FROM runs WHERE startedAt >= ? GROUP BY day ORDER BY day").all(since) as { day: string; usd: number }[],
        byKind: db.prepare('SELECT kind, SUM(costUsd) AS usd FROM runs WHERE startedAt >= ? GROUP BY kind ORDER BY usd DESC').all(since) as { kind: string; usd: number }[],
        byDayKind: db.prepare("SELECT date(startedAt / 1000, 'unixepoch', 'localtime') AS day, kind, SUM(costUsd) AS usd FROM runs WHERE startedAt >= ? GROUP BY day, kind HAVING usd > 0 ORDER BY day, usd DESC").all(since) as { day: string; kind: string; usd: number }[],
      };
    },

    canSpendBackground() {
      const t = cost.totals();
      return t.todayUsd < t.dailyCapUsd && t.monthUsd < t.monthlyCapUsd;
    },
  };
  return cost;
}
