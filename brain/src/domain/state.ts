import type { AppContext } from '../core/context.js';
import type { StateSnapshot } from '../core/types.js';

/** A dozen indexed queries; cheap enough to call on every `state.changed`. */
export function buildState(ctx: AppContext): StateSnapshot {
  const now = Date.now();
  const { repos } = ctx;
  const totals = ctx.cost.totals();
  return {
    now: repos.tasks.current(),
    top: repos.tasks.top(12, now),
    sessions: repos.sessions.list(),
    nextMeeting: repos.meetings.next(now),
    currentMeeting: repos.meetings.current(now),
    counts: { ...repos.tasks.counts(now), suggestions: repos.suggestions.count('pending'), approvals: repos.approvals.count('pending') },
    nudges: repos.nudges.active(now),
    liveNote: repos.notes.live(),
    budget: { todayUsd: totals.todayUsd, dailyCapUsd: totals.dailyCapUsd, monthUsd: totals.monthUsd, billing: totals.billing },
    agent: { ...ctx.agent.status(), available: ctx.agent.available() },
    health: repos.health.snapshot(),
    serverTime: now,
  };
}
