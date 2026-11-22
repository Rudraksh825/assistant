import { connector, settings, ticketsIn } from '../collectors/settings.js';
import type { AppContext } from '../core/context.js';
import type { CodeSession, Id, Link, Meeting, Origin, RelatedItems, SessionPlace, Signal, SourceKind, Suggestion, SuggestionPlace, Task, TaskPlace } from '../core/types.js';
import { DAY, notFound } from '../core/util.js';
import type { Repos } from './index.js';

const OPEN = ['inbox', 'todo', 'doing', 'waiting'];
/** Sources whose `sourceRef` is a signal's externalId. A suggestion and the task accepted from it then name the same signal. */
const SIGNAL_SOURCES = new Set<string>(['chat', 'meeting', 'ticket', 'doc', 'calendar', 'message', 'browser', 'git']);
const FAMILY: Record<string, string> = { chat: 'chat', meeting: 'meetings', ticket: 'tickets', doc: 'docs', calendar: 'calendar' };
// A page visit or a pasted link has no source of its own; where it points says which connector can read it.
const URL_FAMILY: [RegExp, string][] = [
  [/linear\.app|atlassian\.net\/browse|\bjira\b|asana\.com/i, 'tickets'],
  [/notion\.so|docs\.google\.com|atlassian\.net\/wiki|confluence/i, 'docs'],
  [/slack\.com|teams\.microsoft\.com|discord\.com/i, 'chat'],
];
/** Where a reply can be posted: a chat thread, a ticket's comments, a document's comments. A meeting or a calendar event has none. */
const REPLIES = new Set(['chat', 'tickets', 'docs']);
const MAX_ORIGINS = 6;
const MAX_RELATED = 5;

type Sourced = { id: Id; title: string; source: SourceKind; sourceRef: string | null; sourceUrl?: string | null; links?: Link[] };

const web = (url: string | null | undefined): url is string => !!url && /^https?:\/\//i.test(url);
const bare = (url: string): string => url.replace(/[?#].*$/, '').replace(/\/$/, '');

/** One row per item: shared by a suggestion and its task when a signal is behind both. */
export function subjectOf(kind: 'task' | 'suggestion', item: Pick<Sourced, 'id' | 'source' | 'sourceRef'>): string {
  return item.sourceRef && SIGNAL_SOURCES.has(item.source) ? `src:${item.source}:${item.sourceRef}` : `${kind}:${item.id}`;
}

const sessionOrigin = (s: CodeSession): Origin => ({
  source: 'claude', kind: 'session', title: s.title ?? s.name ?? s.repo ?? s.cwd, body: s.lastUserPrompt ?? '', actor: null, at: s.startedAt, url: null,
  signalId: null, sessionId: s.id, meetingId: null, noteId: null,
});

/** What is stored locally about where an item came from: its signal first, then everything else that points at the same links. */
export function originsOf(repos: Repos, item: Sourced): Origin[] {
  const out: Origin[] = [];
  const seen = new Set<string>();
  const add = (key: string, origin: Origin): void => {
    if (seen.has(key) || out.length >= MAX_ORIGINS) return;
    seen.add(key);
    out.push(origin);
  };
  const fromSignal = (s: Signal): Origin => ({
    source: s.source, kind: s.kind, title: s.title, body: s.body, actor: s.actor, at: s.occurredAt, url: s.url,
    signalId: s.id, sessionId: null, meetingId: s.source === 'meeting' ? repos.meetings.forSignal(s.url, s.externalId)?.id ?? null : null, noteId: null,
  });

  if (item.sourceRef) {
    if (item.source === 'claude') {
      const session = repos.sessions.get(item.sourceRef);
      if (session) add(`session:${session.id}`, sessionOrigin(session));
    } else if (item.source === 'capture') {
      const note = repos.notes.get(item.sourceRef);
      if (note) add(`note:${note.id}`, { source: 'capture', kind: 'capture', title: note.title, body: note.body, actor: null, at: note.createdAt, url: null, signalId: null, sessionId: null, meetingId: null, noteId: note.id });
    } else {
      const signal = repos.signals.find(item.source, item.sourceRef);
      if (signal) add(signal.id, fromSignal(signal));
    }
  }
  const links = item.links ?? [];
  const urls = [item.sourceUrl, ...links.map((l) => l.url)].filter(web);
  for (const signal of repos.signals.byUrl([...new Set(urls)], 12)) add(signal.id, fromSignal(signal));
  for (const link of links) {
    const session = link.kind === 'session' && link.ref ? repos.sessions.get(link.ref) : null;
    if (session) add(`session:${session.id}`, sessionOrigin(session));
  }
  // The signal can be gone (never stored, or the item was made by the agent) while its link survives: still worth an "Open in".
  if (!out.length && web(item.sourceUrl)) {
    out.push({ source: item.source, kind: 'link', title: item.title, body: '', actor: null, at: null, url: item.sourceUrl, signalId: null, sessionId: null, meetingId: null, noteId: null });
  }
  return out;
}

/** The connector family that can read around these origins, or null when there is nothing remote behind them or the family is switched off. */
export function familyOf(ctx: AppContext, origins: Origin[], links: Link[] = []): string | null {
  const direct = origins.map((o) => FAMILY[o.source]).find(Boolean);
  const urls = [...origins.map((o) => o.url), ...links.map((l) => l.url)].filter(web);
  const family = direct ?? URL_FAMILY.find(([re]) => urls.some((u) => re.test(u)))?.[1] ?? null;
  return family && connector(ctx, family).enabled ? family : null;
}

const normName = (s: string): string => s.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();

/** Full names match exactly; a lone first name matches a full name that starts with it ("Teo" and "Teo Alvarez"). */
export function samePerson(a: string, b: string): boolean {
  const x = normName(a);
  const y = normName(b);
  if (!x || !y) return false;
  if (x === y) return true;
  const [short, long] = x.length <= y.length ? [x, y] : [y, x];
  return !short.includes(' ') && long.split(' ')[0] === short;
}

/** A chat link's thread: channel plus thread stamp when the URL carries one, else the URL without its query. */
export function threadKey(url: string): string {
  const stamp = /[?&]thread_ts=([\d.]+)/.exec(url)?.[1];
  return stamp ? `${bare(url).replace(/\/p?\d[\d.]*$/, '')}#${stamp}` : bare(url);
}

export interface RelatedKeys { tickets: string[]; people: string[]; threads: string[] }

/** What an item can share with another: ticket ids, people and threads. `owner` is left out of the people, or everything would match. */
export function keysOf(pattern: string, item: { title: string; sourceRef?: string | null; sourceUrl?: string | null; links?: Link[]; people?: string[]; waitingOn?: string | null; actors?: (string | null)[] }, owner = ''): RelatedKeys {
  const links = item.links ?? [];
  const people: string[] = [];
  for (const name of [...(item.people ?? []), item.waitingOn, ...(item.actors ?? [])]) {
    if (name && !samePerson(name, owner) && !people.some((p) => samePerson(p, name))) people.push(name);
  }
  const threads = [...links.filter((l) => l.kind === 'thread').map((l) => l.url), item.sourceUrl].filter(web).map(threadKey);
  return { tickets: ticketsIn(pattern, item.title, item.sourceRef, ...links.flatMap((l) => [l.ref, l.url, l.title])), people, threads: [...new Set(threads)] };
}

export interface RelatedPool { tasks: Task[]; suggestions: Suggestion[]; sessions: CodeSession[]; meetings: Meeting[] }

/**
 * Other things that share this item's ticket, thread or person. Matching is exact and local; a shared ticket or
 * thread outranks a shared person, and each list is cut to the strongest few.
 */
export function relatedTo(self: { taskId?: Id; keys: RelatedKeys }, pool: RelatedPool, pattern: string, owner = ''): RelatedItems {
  const { keys } = self;
  const why = (other: RelatedKeys): { text: string; weight: number } | null => {
    const ticket = other.tickets.find((t) => keys.tickets.includes(t));
    if (ticket) return { text: `same ticket ${ticket}`, weight: 3 };
    if (other.threads.some((t) => keys.threads.includes(t))) return { text: 'same thread', weight: 3 };
    const person = other.people.find((p) => keys.people.some((k) => samePerson(k, p)));
    return person ? { text: `also with ${person}`, weight: 1 } : null;
  };
  const top = <T>(hits: { item: T; text: string; weight: number }[]): { item: T; why: string }[] =>
    hits.sort((a, b) => b.weight - a.weight).slice(0, MAX_RELATED).map((h) => ({ item: h.item, why: h.text }));

  const tasks = top(pool.tasks.filter((t) => t.id !== self.taskId).flatMap((task) => {
    const hit = why(keysOf(pattern, task, owner));
    return hit ? [{ item: task, ...hit }] : [];
  }));
  const suggestions = top(pool.suggestions.flatMap((s) => {
    if (self.taskId && s.payload.taskId === self.taskId) return [{ item: s, text: 'proposes a change to this task', weight: 4 }];
    const payload = s.payload as { people?: unknown; waitingOn?: unknown; links?: unknown };
    const hit = why(keysOf(pattern, {
      title: s.title, sourceRef: s.sourceRef, sourceUrl: s.sourceUrl,
      links: Array.isArray(payload.links) ? (payload.links as Link[]).filter((l) => typeof l?.url === 'string') : [],
      people: Array.isArray(payload.people) ? payload.people.filter((p): p is string => typeof p === 'string') : [],
      waitingOn: typeof payload.waitingOn === 'string' ? payload.waitingOn : null,
    }, owner));
    return hit ? [{ item: s, ...hit }] : [];
  }));
  const sessions = top(pool.sessions.flatMap((session) => {
    if (self.taskId && session.taskId === self.taskId) return [];
    const ticket = session.ticket && keys.tickets.includes(session.ticket) ? session.ticket : null;
    return ticket ? [{ item: session, text: `same ticket ${ticket}`, weight: 3 }] : [];
  }));
  const meetings = top(pool.meetings.flatMap((meeting) => {
    const ticket = ticketsIn(pattern, meeting.title, meeting.summary, ...meeting.actionItems).find((t) => keys.tickets.includes(t));
    if (ticket) return [{ item: meeting, text: `mentions ${ticket}`, weight: 3 }];
    const person = meeting.attendees.find((a) => keys.people.some((k) => samePerson(k, a)));
    return person ? [{ item: meeting, text: `with ${person}`, weight: 1 }] : [];
  }).sort((a, b) => b.item.startAt - a.item.startAt));

  return {
    tasks: tasks.map(({ item, why: text }) => ({ task: item, why: text })),
    suggestions: suggestions.map(({ item, why: text }) => ({ suggestion: item, why: text })),
    sessions: sessions.map(({ item, why: text }) => ({ session: item, why: text })),
    meetings: meetings.map(({ item, why: text }) => ({ meeting: item, why: text })),
  };
}

export function taskPlace(ctx: AppContext, id: Id, now = Date.now()): TaskPlace {
  const { repos } = ctx;
  const task = repos.tasks.must(id);
  const conf = settings(ctx);
  const origins = originsOf(repos, task);
  const keys = keysOf(conf.code.ticketPattern, { ...task, actors: origins.map((o) => o.actor) }, conf.user.name);
  const related = relatedTo({ taskId: id, keys }, {
    tasks: repos.tasks.list({ status: OPEN, limit: 500 }),
    suggestions: repos.suggestions.list('pending'),
    sessions: repos.sessions.list(),
    meetings: repos.meetings.list(now - 14 * DAY, now + 7 * DAY),
  }, conf.code.ticketPattern, conf.user.name);
  const family = familyOf(ctx, origins, task.links);
  return {
    task, origins, related, context: repos.contexts.get(subjectOf('task', task)), sessions: repos.sessions.forTask(id),
    seeMoreVia: family, replyVia: family && REPLIES.has(family) ? family : null,
  };
}

export function suggestionPlace(ctx: AppContext, id: Id): SuggestionPlace {
  const { repos } = ctx;
  const suggestion = repos.suggestions.get(id);
  if (!suggestion) throw notFound('suggestion');
  const links = Array.isArray(suggestion.payload.links) ? (suggestion.payload.links as Link[]).filter((l) => typeof l?.url === 'string') : [];
  const origins = originsOf(repos, { ...suggestion, links });
  return { suggestion, origins, context: repos.contexts.get(subjectOf('suggestion', suggestion)), seeMoreVia: familyOf(ctx, origins, links) };
}

export function sessionPlace(ctx: AppContext, id: Id): SessionPlace {
  const { repos } = ctx;
  const session = repos.sessions.must(id);
  const task = session.taskId ? repos.tasks.get(session.taskId) : null;
  let ticketUrl: string | null = null;
  if (session.ticket) {
    const pattern = settings(ctx).code.ticketPattern;
    const names = (l: Link): boolean => ticketsIn(pattern, l.ref, l.url, l.title).includes(session.ticket!);
    ticketUrl = task?.links.find((l) => l.kind === 'ticket' && names(l))?.url
      ?? repos.signals.list({ source: 'ticket', q: session.ticket, limit: 5 }).find((s) => web(s.url) && ticketsIn(pattern, s.title, s.url).includes(session.ticket!))?.url
      ?? null;
  }
  return { session, task, ticketUrl, recap: repos.kv.get<{ text: string; at: number }>(`recap:${session.id}`) };
}
