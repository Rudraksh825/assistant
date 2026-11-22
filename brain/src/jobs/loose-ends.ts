import type { PrSnapshot, Pr } from '../collectors/git-prs.js';
import { clip, settings, ticketsIn, type Settings } from '../collectors/settings.js';
import type { AppContext } from '../core/context.js';
import type { CodeSession, Id, LooseEnd, LooseEnds, Ms, Signal, Suggestion, Task } from '../core/types.js';
import { DAY, HOUR, invalid, isPlainObject, notFound, startOfDay } from '../core/util.js';
import { samePerson } from '../domain/places.js';
import { notify } from './notify.js';

const OPEN = new Set(['inbox', 'todo', 'doing', 'waiting']);
const DISMISSED = 'looseEnds:dismissed';
const NUDGED = 'looseEnds:nudged';
const ENDED_WINDOW = 14 * DAY;
const TITLES: Record<LooseEnd['kind'], string> = {
  commitment: 'You said you would', session: 'Sessions left waiting', waiting: 'Waiting with no word', pr: 'Pull requests stuck', page: 'Pages you keep opening',
};

export interface Commitment { quote: string; to: string | null; madeAt: Ms }

export function commitmentOf(s: Pick<Suggestion, 'payload' | 'createdAt'>): Commitment | null {
  const c = s.payload.commitment;
  if (!isPlainObject(c)) return null;
  return { quote: typeof c.quote === 'string' ? c.quote : '', to: typeof c.to === 'string' && c.to ? c.to : null, madeAt: typeof c.madeAt === 'number' ? c.madeAt : s.createdAt };
}

export interface LooseEndInput {
  /** Pending and accepted suggestions. */
  suggestions: Suggestion[];
  /** Every task; the rules look at the open ones. */
  tasks: Task[];
  /** Live sessions. */
  sessions: CodeSession[];
  ended: CodeSession[];
  prs: Pr[];
  /** Browser `visit` signals inside the page window. */
  visits: Signal[];
  /** Lower-cased actor name -> their latest signal. */
  lastHeard: Map<string, Ms>;
  /** Loose-end id -> the `since` it had when the owner dismissed it. */
  dismissed: Record<string, Ms>;
}

export function ago(since: Ms, now: Ms): string {
  const ms = Math.max(0, now - since);
  if (ms >= 2 * DAY) return `${Math.floor(ms / DAY)} days`;
  if (ms >= DAY) return 'a day';
  if (ms >= 2 * HOUR) return `${Math.floor(ms / HOUR)} hours`;
  return ms >= HOUR ? 'an hour' : 'under an hour';
}

const bare = (url: string): string => url.replace(/[?#].*$/, '').replace(/\/$/, '');
const taskPath = (id: Id) => ({ view: 'today', path: `/tasks/${id}` });
const sessionPath = (id: Id) => ({ view: 'sessions', path: `/sessions/${id}` });

/**
 * The rules, over plain data. Nothing here reads the clock, the database or a model, so the same input always
 * gives the same list. Within a group the oldest comes first; a dismissed item stays away until its `since` moves.
 */
export function computeLooseEnds(input: LooseEndInput, conf: Settings['looseEnds'], pattern: string, now: Ms): LooseEnds {
  const open = input.tasks.filter((t) => OPEN.has(t.status));
  const byId = new Map(input.tasks.map((t) => [t.id, t]));
  const found: LooseEnd[] = [];

  for (const s of input.suggestions) {
    const c = commitmentOf(s);
    if (!c || now - c.madeAt < conf.commitmentAfterDays * DAY) continue;
    const to = c.to ? ` ${c.to}` : '';
    if (s.status === 'pending') {
      found.push({ id: `commitment:s:${s.id}`, kind: 'commitment', title: s.title, since: c.madeAt, reason: `You told${to || ' someone'} this ${ago(c.madeAt, now)} ago; it is still in the Inbox.`, place: { view: 'inbox', path: `/suggestions/${s.id}` }, url: s.sourceUrl });
    } else if (s.status === 'accepted' && s.sourceRef) {
      const task = open.find((t) => t.source === s.source && t.sourceRef === s.sourceRef);
      if (task) found.push({ id: `commitment:t:${task.id}`, kind: 'commitment', title: task.title, since: c.madeAt, reason: `Promised${to} ${ago(c.madeAt, now)} ago and not done.`, place: taskPath(task.id), url: s.sourceUrl });
    }
  }

  for (const s of input.sessions) {
    // `idle` with a prompt behind it is a session that waited so long the radar stopped counting it.
    const stuck = s.state === 'waiting' || s.state === 'blocked' || (s.state === 'idle' && !!s.lastUserPrompt);
    if (!stuck || now - s.stateSince < conf.sessionWaitingHours * HOUR) continue;
    found.push({
      id: `session:${s.id}`, kind: 'session', title: s.title ?? s.name ?? s.repo ?? s.cwd, since: s.stateSince, place: sessionPath(s.id), url: null,
      reason: `${s.state === 'blocked' ? 'Blocked on a question' : 'Finished and waiting on you'} for ${ago(s.stateSince, now)}${s.repo ? ` in ${s.repo}` : ''}.`,
    });
  }
  const liveTasks = new Set(input.sessions.map((s) => s.taskId).filter(Boolean));
  const endedFor = new Set<Id>();
  for (const s of [...input.ended].sort((a, b) => b.updatedAt - a.updatedAt)) {
    const task = s.taskId ? byId.get(s.taskId) : undefined;
    if (!task || !OPEN.has(task.status) || liveTasks.has(task.id) || endedFor.has(task.id) || now - s.updatedAt > ENDED_WINDOW) continue;
    endedFor.add(task.id);
    found.push({ id: `session:${s.id}`, kind: 'session', title: s.title ?? task.title, since: s.updatedAt, place: sessionPath(s.id), url: null, reason: `Its session ended ${ago(s.updatedAt, now)} ago; the task “${clip(task.title, 60)}” is still open.` });
  }

  for (const t of open) {
    if (t.status !== 'waiting' || !t.waitingOn) continue;
    const heard = [...input.lastHeard].filter(([name]) => samePerson(name, t.waitingOn!)).map(([, at]) => at);
    const since = Math.max(t.updatedAt, ...heard);
    if (now - since < conf.waitingSilentDays * DAY) continue;
    found.push({ id: `waiting:${t.id}`, kind: 'waiting', title: t.title, since, place: taskPath(t.id), url: null, reason: `Nothing from ${t.waitingOn} for ${ago(since, now)}.` });
  }

  for (const pr of input.prs) {
    const failing = pr.checks === 'FAILURE' || pr.checks === 'ERROR';
    if (pr.state !== 'OPEN' || (!failing && !pr.unresolved) || now - pr.updatedAt < conf.prStaleDays * DAY) continue;
    const session = input.sessions.find((s) => s.pr?.url === pr.url) ?? input.ended.find((s) => s.pr?.url === pr.url);
    const task = open.find((t) => t.links.some((l) => bare(l.url) === bare(pr.url)));
    const problems = [failing && 'checks failing', pr.unresolved && `${pr.unresolved} unresolved thread${pr.unresolved === 1 ? '' : 's'}`].filter(Boolean).join(', ');
    found.push({
      id: `pr:${pr.url}`, kind: 'pr', title: `#${pr.number} ${pr.title}`, since: pr.updatedAt, url: pr.url, place: task ? taskPath(task.id) : session ? sessionPath(session.id) : null,
      reason: `${problems[0]!.toUpperCase()}${problems.slice(1)}, untouched for ${ago(pr.updatedAt, now)}.`,
    });
  }

  const tracked = new Set([...input.tasks.flatMap((t) => t.links.map((l) => bare(l.url))), ...input.suggestions.flatMap((s) => (s.sourceUrl ? [bare(s.sourceUrl)] : []))]);
  const ticketed = new Set(input.tasks.flatMap((t) => ticketsIn(pattern, t.title, t.sourceRef, ...t.links.flatMap((l) => [l.ref, l.url, l.title]))));
  const pages = new Map<string, { days: Set<string>; first: Ms; latest: Signal }>();
  for (const v of input.visits) {
    if (!v.url || now - v.occurredAt > conf.pageWindowDays * DAY) continue;
    const url = bare(v.url);
    const page = pages.get(url) ?? { days: new Set<string>(), first: v.occurredAt, latest: v };
    page.days.add(new Date(v.occurredAt).toLocaleDateString('sv'));
    page.first = Math.min(page.first, v.occurredAt);
    if (v.occurredAt >= page.latest.occurredAt) page.latest = v;
    pages.set(url, page);
  }
  for (const [url, page] of pages) {
    if (page.days.size < conf.pageVisitDays || tracked.has(url) || ticketsIn(pattern, url, page.latest.title).some((t) => ticketed.has(t))) continue;
    found.push({ id: `page:${url}`, kind: 'page', title: page.latest.title || url, since: page.first, place: null, url: page.latest.url, reason: `Opened on ${page.days.size} days since ${new Date(page.first).toLocaleDateString('en-GB', { day: 'numeric', month: 'short' })}; nothing tracks it.` });
  }

  const kept = found.filter((e) => input.dismissed[e.id] !== e.since).sort((a, b) => a.since - b.since);
  const groups = (Object.keys(TITLES) as LooseEnd['kind'][])
    .map((kind) => ({ kind, title: TITLES[kind], items: kept.filter((e) => e.kind === kind).slice(0, conf.maxPerGroup) }))
    .filter((g) => g.items.length);
  return { groups, count: groups.reduce((n, g) => n + g.items.length, 0), at: now };
}

export function looseEnds(ctx: AppContext, now: Ms = Date.now()): LooseEnds {
  const { repos } = ctx;
  const conf = settings(ctx);
  return computeLooseEnds({
    suggestions: repos.suggestions.list().filter((s) => s.status !== 'dismissed' && isPlainObject(s.payload.commitment)),
    tasks: repos.tasks.list({ limit: 5000 }),
    sessions: repos.sessions.list(),
    ended: repos.sessions.endedSince(now - ENDED_WINDOW),
    prs: repos.kv.get<PrSnapshot>('prs')?.items ?? [],
    visits: repos.signals.list({ source: 'browser', since: now - conf.looseEnds.pageWindowDays * DAY, limit: 2000 }),
    lastHeard: repos.signals.lastByActor(now - 60 * DAY),
    dismissed: repos.kv.get<Record<string, Ms>>(DISMISSED) ?? {},
  }, conf.looseEnds, conf.code.ticketPattern, now);
}

const find = (ctx: AppContext, id: string): LooseEnd => {
  const end = looseEnds(ctx).groups.flatMap((g) => g.items).find((e) => e.id === id);
  if (!end) throw notFound('loose end');
  return end;
};

/** "Not a loose end": hidden until the thing behind it changes again. */
export function dismissLooseEnd(ctx: AppContext, id: string): void {
  const end = find(ctx, id);
  ctx.repos.kv.set(DISMISSED, { ...(ctx.repos.kv.get<Record<string, Ms>>(DISMISSED) ?? {}), [id]: end.since });
  ctx.bus.changed('places');
}

/** Gives a loose end with no task behind it (a page, a pull request) one, so it has a place and stops being loose. */
export function trackLooseEnd(ctx: AppContext, id: string): Task {
  const end = find(ctx, id);
  if (end.place?.path.startsWith('/tasks/')) return ctx.repos.tasks.must(end.place.path.slice('/tasks/'.length));
  if (!end.url) throw invalid('this loose end already has a place');
  const signal = end.kind === 'page' ? ctx.repos.signals.byUrl([end.url], 1)[0] : undefined;
  return ctx.repos.tasks.create({
    title: clip(end.title, 120), status: 'todo', source: end.kind === 'pr' ? 'git' : 'browser', sourceRef: signal?.externalId ?? null,
    links: [{ kind: end.kind === 'pr' ? 'pr' : 'url', title: clip(end.title, 120), url: end.url }],
  });
}

export function looseEndLines(ctx: AppContext, now: Ms = Date.now()): string[] {
  return looseEnds(ctx, now).groups.flatMap((g) => g.items.slice(0, 4).map((e) => `- ${g.title.toLowerCase()}: ${clip(e.title, 90)} (${e.reason})`));
}

/** At most one nudge a day, and only when the list is not the one already nudged about. */
export function nudgeLooseEnds(ctx: AppContext, now: Ms = Date.now()): boolean {
  const day = startOfDay(now);
  const last = ctx.repos.kv.get<{ day: Ms; ids: string[] }>(NUDGED);
  if (last?.day === day) return false;
  const list = looseEnds(ctx, now);
  const items = list.groups.flatMap((g) => g.items);
  const ids = items.map((e) => e.id).sort();
  if (!ids.length || ids.join('\n') === last?.ids.join('\n')) return false;
  ctx.repos.kv.set(NUDGED, { day, ids });
  notify(ctx, {
    kind: 'task', priority: 1, title: `${ids.length} loose end${ids.length === 1 ? '' : 's'}`, body: clip(items.slice(0, 3).map((e) => e.title).join(' · '), 240),
    dedupeKey: `loose-ends:${day}`, expiresAt: day + DAY, actions: [{ id: 'open', label: 'Show', kind: 'open_view', view: 'today', path: '/loose-ends' }],
  }, now);
  return true;
}

export function registerLooseEnds(ctx: AppContext): void {
  ctx.scheduler.register({ name: 'loose-ends', schedule: { everyMin: 60 }, workHoursOnly: true, run: () => void nudgeLooseEnds(ctx) });
}
