import { basename } from 'node:path';
import { matchSession } from '../collectors/activity.js';
import { blockedReasons } from '../collectors/claude-sessions.js';
import { clip, settings } from '../collectors/settings.js';
import type { AppContext } from '../core/context.js';
import type { CodeSession, Id, Ms, NudgeAction } from '../core/types.js';
import { DAY, MIN, startOfDay } from '../core/util.js';
import { notify } from './notify.js';

const SEEN = 'nudged:sessions';
const SESSION_TTL = 30 * MIN;
const APPROVAL_STALE = 30 * MIN;
const DOING_STALE = 2 * DAY;
// The app repeats the frontmost window every minute; older than this and it is no longer known.
const FOCUS_FRESH = 150_000;
const stuck = (s: CodeSession): boolean => s.state === 'waiting' || s.state === 'blocked';
const label = (s: CodeSession): string => s.title ?? s.name ?? basename(s.cwd);

/**
 * Deterministic nudges. `open_view` actions name one of the app's routes; when the nudge is about a single
 * record, `path` carries that record's API path so a surface can open it directly.
 */
export function createNudger(ctx: AppContext) {
  const { repos } = ctx;
  // session id -> the stateSince we already nudged for: one nudge per waiting episode, also across restarts.
  const seen: Record<Id, Ms> = repos.kv.get<Record<Id, Ms>>(SEEN) ?? {};
  const timers = new Map<Id, NodeJS.Timeout>();
  let digestDay = 0;
  // Sessions already stuck when Steward first ran on this data dir sit on the radar; only what happens from then on interrupts.
  const baseline = repos.kv.get<Ms>('sessions:baseline') ?? 0;
  // The session whose editor or terminal window is frontmost (from the app's `focus` sensor events), and when each one stopped being it.
  let front: { sessionId: Id | null; at: Ms } | null = null;
  const leftAt = new Map<Id, Ms>();
  const watching = (id: Id, now: Ms): boolean => front !== null && front.sessionId === id && now - front.at < FOCUS_FRESH;
  // A session the user is looking at needs no nudge; the wait starts when they leave its window.
  const waitedFrom = (s: CodeSession): Ms => Math.max(s.stateSince, leftAt.get(s.id) ?? 0);
  const arm = (id: Id, at: Ms): void => {
    clearTimeout(timers.get(id));
    timers.set(id, setTimeout(() => {
      timers.delete(id);
      try {
        sessions();
      } catch (err) {
        // The timer can outlive a shutdown and find the database closed.
        ctx.log.child('nudges').warn('session nudge failed', err);
      }
    }, Math.max(0, at - Date.now()) + 25).unref());
  };

  /** Sessions stuck past the threshold and not yet nudged. One is a nudge of its own; several become one combined nudge. */
  function sessions(now: Ms = Date.now()): void {
    const after = settings(ctx).nudges.sessionWaitingAfterSec * 1000;
    const live = repos.sessions.list();
    const due = live.filter((s) => stuck(s) && s.stateSince > baseline && seen[s.id] !== s.stateSince && !watching(s.id, now) && now - waitedFrom(s) >= after).sort((a, b) => a.stateSince - b.stateSince);
    const gone = Object.keys(seen).filter((id) => !live.some((s) => s.id === id));
    for (const id of gone) delete seen[id];
    for (const id of leftAt.keys()) if (!live.some((s) => s.id === id)) leftAt.delete(id);
    if (due.length) {
      const blocked = due.filter((s) => s.state === 'blocked');
      // Episodes that began long ago (found on startup) are worth showing, not worth interrupting for.
      const priority = due.every((s) => now - s.stateSince > SESSION_TTL) ? 0 : blocked.length ? 2 : 1;
      const focus = (s: CodeSession, text = 'Go to session'): NudgeAction => ({ id: `focus:${s.id}`, label: text, kind: 'focus_session', sessionId: s.id });
      const one = due[0]!;
      if (due.length === 1) {
        notify(ctx, {
          kind: 'session', priority, expiresAt: now + SESSION_TTL, dedupeKey: `session:${one.id}:${one.stateSince}`,
          title: `${one.state === 'blocked' ? 'Session needs you' : 'Session finished'}: ${label(one)}`,
          body: clip(one.state === 'blocked' ? blockedReasons.get(one.id) ?? 'Waiting for permission or an answer.' : one.lastAssistantText ?? '', 240),
          actions: [focus(one)],
        }, now);
      } else {
        notify(ctx, {
          kind: 'session', priority, expiresAt: now + SESSION_TTL, dedupeKey: `sessions:${due.map((s) => s.stateSince).join('.')}`,
          title: `${due.length} sessions waiting for you${blocked.length ? ` (${blocked.length} blocked)` : ''}`,
          body: clip(due.map(label).join(' · '), 300),
          actions: [{ id: 'open', label: 'Show sessions', kind: 'open_view', view: 'sessions' }, focus(blocked[0] ?? one, 'Go to the first')],
        }, now);
      }
      for (const s of due) seen[s.id] = s.stateSince;
    }
    if (due.length || gone.length) repos.kv.set(SEEN, seen);
  }

  function meetings(now: Ms): void {
    const lead = settings(ctx).nudges.meetingLeadMin * MIN;
    for (const m of repos.meetings.list(now - 10 * MIN, now + lead + MIN)) {
      if (m.source !== 'calendar') continue;
      if (m.startAt > now && m.startAt - now <= lead + MIN) {
        const actions: NudgeAction[] = [{ id: 'prep', label: 'Open prep', kind: 'open_view', view: 'meetings', path: `/meetings/${m.id}` }];
        if (m.joinUrl) actions.unshift({ id: 'join', label: 'Join', kind: 'open_url', url: m.joinUrl });
        notify(ctx, { kind: 'meeting', title: `${m.title} in ${Math.max(1, Math.round((m.startAt - now) / MIN))} min`, body: clip(m.attendees.join(', '), 200), priority: 2, urgent: true, actions, expiresAt: m.endAt, dedupeKey: `meeting:start:${m.id}:${m.startAt}` }, now);
      } else if (m.endAt <= now && m.attendees.length >= 2) {
        notify(ctx, {
          kind: 'meeting', title: `Follow-ups from ${m.title}?`, body: 'Capture what you took on while it is fresh.', priority: 1, expiresAt: m.endAt + 60 * MIN, dedupeKey: `meeting:end:${m.id}:${m.endAt}`,
          actions: [{ id: 'open', label: 'Add follow-ups', kind: 'open_view', view: 'meetings', path: `/meetings/${m.id}` }],
        }, now);
      }
    }
  }

  function tasks(now: Ms): void {
    const today = startOfDay(now);
    if (digestDay !== today) {
      digestDay = today;
      const { dueToday, overdue } = repos.tasks.counts(now);
      if (dueToday + overdue > 0) {
        const titles = repos.tasks.list({ status: ['inbox', 'todo', 'doing', 'waiting'] }).filter((t) => t.dueAt !== null && t.dueAt < today + DAY).slice(0, 5).map((t) => t.title);
        notify(ctx, {
          kind: 'task', title: [dueToday && `${dueToday} due today`, overdue && `${overdue} overdue`].filter(Boolean).join(', '), body: clip(titles.join(' · '), 300),
          priority: 1, expiresAt: today + DAY, dedupeKey: `tasks:due:${today}`, actions: [{ id: 'open', label: 'Show today', kind: 'open_view', view: 'today' }],
        }, now);
      }
    }
    for (const t of repos.tasks.list({ status: ['doing'] })) {
      if (now - t.updatedAt < DOING_STALE) continue;
      notify(ctx, {
        kind: 'task', title: `Still on "${clip(t.title, 60)}"?`, body: `In progress, untouched for ${Math.floor((now - t.updatedAt) / DAY)} days.`, priority: 1, dedupeKey: `task:stale:${t.id}:${t.updatedAt}`,
        actions: [
          { id: 'done', label: 'Done', kind: 'api', method: 'POST', path: `/tasks/${t.id}/complete` },
          { id: 'later', label: 'Not now', kind: 'api', method: 'PATCH', path: `/tasks/${t.id}`, body: { status: 'todo' } },
          { id: 'open', label: 'Open', kind: 'open_view', view: 'today', path: `/tasks/${t.id}` },
        ],
      }, now);
    }
  }

  function approvals(now: Ms): void {
    for (const a of repos.approvals.list('pending')) {
      if (now - a.createdAt < APPROVAL_STALE) continue;
      notify(ctx, { kind: 'approval', title: 'Still waiting for your approval', body: clip(a.summary, 200), priority: 1, dedupeKey: `approval:stale:${a.id}`, actions: [{ id: 'review', label: 'Review', kind: 'open_view', view: 'approvals' }] }, now);
    }
  }

  function sweep(now: Ms = Date.now()): void {
    sessions(now);
    meetings(now);
    approvals(now);
    // Sessions and meetings happen when they happen; reminders about the list keep to work hours.
    if (ctx.scheduler.isWorkHours(now)) tasks(now);
  }

  // The per-minute sweep is too coarse for "finished 45 seconds ago": time each episode exactly.
  const off = ctx.bus.on('session.updated', (s) => {
    const nudged = seen[s.id];
    if (nudged !== undefined && (!stuck(s) || s.stateSince !== nudged)) {
      // The user is back on it (or it ended): a toast still saying "waiting" is now wrong.
      repos.nudges.dismissByKey(`session:${s.id}:${nudged}`);
      delete seen[s.id];
      repos.kv.set(SEEN, seen);
    }
    clearTimeout(timers.get(s.id));
    timers.delete(s.id);
    if (!stuck(s) || seen[s.id] === s.stateSince) return;
    arm(s.id, waitedFrom(s) + settings(ctx).nudges.sessionWaitingAfterSec * 1000);
  });

  const offFocus = ctx.bus.on('sensor.event', ({ kind, at, data }) => {
    if (kind !== 'focus') return;
    const live = repos.sessions.list();
    const span = { app: String(data?.app ?? ''), bundleId: typeof data?.bundleId === 'string' ? data.bundleId : null, title: typeof data?.title === 'string' ? data.title : null };
    // Idle at the keyboard counts as away, whatever is in front.
    const sessionId = data?.idle === true ? null : matchSession(span, live, settings(ctx).code.editorApps);
    const was = front?.sessionId ?? null;
    front = { sessionId, at: Date.now() };
    if (!was || was === sessionId) return;
    leftAt.set(was, at);
    const s = live.find((x) => x.id === was);
    if (s && stuck(s) && seen[s.id] !== s.stateSince) arm(s.id, waitedFrom(s) + settings(ctx).nudges.sessionWaitingAfterSec * 1000);
  });

  return {
    sessions,
    sweep,
    stop() {
      off();
      offFocus();
      for (const t of timers.values()) clearTimeout(t);
    },
  };
}
