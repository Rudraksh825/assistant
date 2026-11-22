import type { CodeSession, Initiative, Meeting, Ms, Project, Task, TaskStatus } from '../core/types.js';
import { DAY, MIN, startOfDay } from '../core/util.js';

/** What a task's score depends on besides the task itself. */
export interface RankInput {
  project: Project | null;
  initiative: Initiative | null;
  /** Code sessions linked to the task. */
  sessions: CodeSession[];
  /** Meetings linked to the task. */
  meetings: Meeting[];
}

const STATUS: Record<TaskStatus, number> = { doing: 30, todo: 20, waiting: 10, inbox: 8, done: 0, dropped: 0 };
const PRIORITY: [points: number, reason: string | null][] = [[0, null], [4, null], [12, 'high priority'], [22, 'urgent']];

const span = (min: number) => (min < 60 ? `${min}m` : min < 48 * 60 ? `${Math.round(min / 60)}h` : `${Math.round(min / (24 * 60))}d`);

/**
 * Deterministic 0..100 score plus the reasons a person would give for it.
 * Points add up and then pass through a saturating curve, so a pile of boosts still orders
 * correctly instead of flattening against a hard cap.
 */
export function scoreTask(t: Task, x: RankInput, now: Ms): { score: number; reasons: string[] } {
  if (t.status === 'done' || t.status === 'dropped') return { score: 0, reasons: [] };
  if (t.snoozedUntil !== null && t.snoozedUntil > now) return { score: 0, reasons: ['snoozed'] };

  let points = STATUS[t.status] ?? 0;
  const reasons: string[] = [];
  const add = (n: number, reason?: string | null) => {
    points += n;
    if (reason) reasons.push(reason);
  };

  if (t.pinned) add(25, 'pinned');
  add(...(PRIORITY[t.priority] ?? PRIORITY[0]!));

  const today = startOfDay(now);
  if (t.dueAt !== null) {
    // Round, not floor: a DST change makes a calendar day 23 or 25 hours long.
    const days = Math.round((startOfDay(t.dueAt) - today) / DAY);
    const minutes = Math.ceil((t.dueAt - now) / MIN);
    if (days < 0) add(25 + Math.min(5, -days), `overdue ${-days}d`);
    else if (days === 0 && minutes > 0 && minutes <= 180) add(25, `due in ${span(minutes)}`);
    else if (days === 0) add(22, 'due today');
    else if (days === 1) add(14, 'due tomorrow');
    else if (days <= 3) add(8, `due in ${days}d`);
    else if (days <= 7) add(4, 'due this week');
  }
  if (t.scheduledFor !== null && startOfDay(t.scheduledFor) <= today) {
    add(12, startOfDay(t.scheduledFor) === today ? 'scheduled today' : 'scheduled earlier');
  }

  if (x.project?.status === 'active') add(x.project.weight * 2, x.project.weight >= 2 ? `project: ${x.project.title}` : null);
  if (x.initiative?.status === 'active') add(x.initiative.weight * 2, x.initiative.weight >= 2 ? `initiative: ${x.initiative.title}` : null);

  const stuck = x.sessions
    .filter((s) => s.state === 'waiting' || s.state === 'blocked')
    .sort((a, b) => a.stateSince - b.stateSince)[0];
  if (stuck) {
    const minutes = Math.max(0, Math.floor((now - stuck.stateSince) / MIN));
    add((stuck.state === 'blocked' ? 18 : 15) + Math.min(5, Math.floor(minutes / 6)), `session ${stuck.state} ${span(minutes)}`);
  }

  const meeting = x.meetings.filter((m) => m.endAt > now).sort((a, b) => a.startAt - b.startAt)[0];
  if (meeting) {
    const minutes = Math.ceil((meeting.startAt - now) / MIN);
    if (minutes <= 0) add(15, 'meeting now');
    else if (minutes <= 60) add(15, `meeting in ${span(minutes)}`);
    else if (minutes <= 24 * 60) add(6, `meeting in ${span(minutes)}`);
  }

  if (t.status === 'doing') {
    reasons.push('in progress');
    // Untouched "doing" work loses its head start over "todo" so it cannot squat at the top.
    const idleDays = Math.floor((now - t.updatedAt) / DAY);
    if (idleDays >= 2) add(-Math.min(10, idleDays * 2), `stale ${idleDays}d`);
  }
  if (t.status === 'waiting' && t.waitingOn) reasons.push(`waiting on ${t.waitingOn}`);

  const weeks = Math.floor((now - t.createdAt) / (7 * DAY));
  if (weeks >= 1) add(Math.min(5, weeks), weeks >= 2 ? `open ${weeks}w` : null);

  return { score: Math.round(100 * (1 - Math.exp(-Math.max(0, points) / 60))), reasons };
}

/** Resolves each task's RankInput from the current projects, initiatives, sessions and upcoming meetings. */
export function rankInputs(src: { projects: Project[]; initiatives: Initiative[]; sessions: CodeSession[]; meetings: Meeting[] }): (t: Task) => RankInput {
  const projects = new Map(src.projects.map((p) => [p.id, p]));
  const initiatives = new Map(src.initiatives.map((i) => [i.id, i]));
  return (t) => {
    const project = (t.projectId && projects.get(t.projectId)) || null;
    const refs = (kind: string) => new Set(t.links.filter((l) => l.kind === kind && l.ref).map((l) => l.ref));
    const sessionRefs = refs('session');
    const meetingRefs = refs('meeting');
    return {
      project,
      initiative: (project?.initiativeId && initiatives.get(project.initiativeId)) || null,
      sessions: src.sessions.filter((s) => s.taskId === t.id || sessionRefs.has(s.id)),
      meetings: src.meetings.filter((m) => meetingRefs.has(m.id) || (t.sourceRef !== null && (t.sourceRef === m.id || t.sourceRef === m.externalId))),
    };
  };
}

