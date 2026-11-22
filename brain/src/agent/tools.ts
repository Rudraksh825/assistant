import { createSdkMcpServer, tool, type McpSdkServerConfigWithInstance, type SdkMcpToolDefinition } from '@anthropic-ai/claude-agent-sdk';
import { z } from 'zod';
import type { AppContext } from '../core/context.js';
import type { Schedule } from '../core/scheduler.js';
import type { Id, Meeting, Ms, Task } from '../core/types.js';
import { DAY, HOUR, startOfDay } from '../core/util.js';
import type { Approval } from '../core/types.js';
import { looseEnds } from '../jobs/loose-ends.js';
import { approvalNote } from './executor.js';
import { decide, type Policy } from './guard.js';
import type { Self } from './self.js';

export interface ToolEnv {
  ctx: AppContext;
  self: Self;
  policy: () => Policy;
  /** The chat thread this run belongs to, when it is a chat run. */
  threadId?: Id;
  /** Chat only: put a question to the user and wait for the answer. */
  ask?: (question: string, options?: string[]) => Promise<string>;
  recap: (sessionId: Id) => Promise<string>;
  schedule: (job: { name: string; prompt?: string; schedule?: Schedule; connectors?: string[]; remove?: boolean }) => string;
  /** Connector reads relayed through a login-mode run, for runs that have no connectors of their own (API billing). */
  bridge: { tools(query: string): Promise<unknown>; read(tool: string, input: Record<string, unknown>): Promise<string> };
  knownConnectorTool: (name: string) => boolean | null;
  /** Why a payload can never be approved, or null. */
  checkApproval: (approval: Pick<Approval, 'tool' | 'input'>) => string | null;
}

/** In every chat prompt; the rest are found through ToolSearch when needed. */
const CORE = new Set(['tasks_search', 'task_create', 'task_update', 'task_complete', 'projects_list', 'memory_list', 'memory_read', 'memory_write', 'ask_user', 'request_approval', 'connector_tools', 'connector_read']);

const SOURCES = ['manual', 'capture', 'agent', 'claude', 'chat', 'meeting', 'ticket', 'doc', 'calendar', 'message', 'browser', 'git'] as const;
const STATUSES = ['inbox', 'todo', 'doing', 'waiting', 'done', 'dropped'] as const;
const LIFECYCLE = ['active', 'paused', 'done', 'dropped'] as const;
const when = z.string().describe('local ISO date or datetime');

/**
 * A bare date means "that day" in local time, never UTC midnight: its end for a deadline or the close of a range,
 * its start for the opening of a range or the moment something begins.
 */
export function toMs(value: string | null | undefined, edge: 'start' | 'end' = 'end'): Ms | null | undefined {
  if (value === undefined || value === null || value === '') return value === undefined ? undefined : null;
  // Connectors hand out epoch stamps too (chat message ids are seconds with a fraction); models pass them through.
  if (/^\d{12,14}$/.test(value)) return Number(value);
  if (/^\d{10}(\.\d+)?$/.test(value)) return Math.round(Number(value) * 1000);
  const ms = new Date(/^\d{4}-\d{2}-\d{2}$/.test(value) ? `${value}T${edge === 'end' ? '23:59' : '00:00'}:00` : value).getTime();
  if (Number.isNaN(ms)) throw new Error(`"${value}" is not a date; use 2026-01-31 or 2026-01-31T15:00`);
  return ms;
}
export const stamp = (ms: Ms) => new Date(ms).toLocaleString('sv-SE').slice(0, 16);
const clip = (text: string | null | undefined, max: number) => (!text ? '' : text.length > max ? `${text.slice(0, max)}…` : text);
const defined = <T extends Record<string, unknown>>(o: T): Partial<T> => Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined)) as Partial<T>;

export const taskBrief = (t: Task) => defined({
  id: t.id, title: t.title, status: t.status, priority: t.priority || undefined, due: t.dueAt ? stamp(t.dueAt) : undefined,
  projectId: t.projectId ?? undefined, waitingOn: t.waitingOn ?? undefined, notes: clip(t.notes, 160) || undefined,
});
const meetingBrief = (m: Meeting) => defined({
  id: m.id, title: m.title, start: m.startKnown ? stamp(m.startAt) : `${stamp(m.startAt).slice(0, 10)} (time unknown)`, end: m.startKnown ? stamp(m.endAt) : undefined, attendees: m.attendees.slice(0, 12), summary: clip(m.summary, 300) || undefined,
  actionItems: m.actionItems.length ? m.actionItems.slice(0, 10) : undefined, prepNote: m.prepNote ? 'yes' : undefined,
});

type Def = SdkMcpToolDefinition<any>;

export function stewardTools(env: ToolEnv): Def[] {
  const { ctx } = env;
  const { repos } = ctx;
  const defs: Def[] = [];
  const add = <S extends z.ZodRawShape>(name: string, description: string, shape: S, handler: (args: z.infer<z.ZodObject<S>>) => unknown, readOnly = false) => {
    const def = tool(name, description, shape, async (args: unknown) => {
      try {
        const out = await handler(args as z.infer<z.ZodObject<S>>);
        return { content: [{ type: 'text' as const, text: typeof out === 'string' ? out : JSON.stringify(out) }] };
      } catch (err) {
        return { content: [{ type: 'text' as const, text: `Error: ${(err as Error).message}` }], isError: true };
      }
    }, { annotations: { readOnlyHint: readOnly }, alwaysLoad: CORE.has(name) });
    defs.push(def as unknown as Def);
  };

  const taskFields = {
    notes: z.string().optional(),
    status: z.enum(STATUSES).optional(),
    priority: z.number().int().min(0).max(3).optional().describe('0 none, 1 low, 2 high, 3 urgent'),
    due: when.nullable().optional(),
    scheduledFor: when.nullable().optional(),
    projectId: z.string().nullable().optional(),
    waitingOn: z.string().nullable().optional(),
    people: z.array(z.string()).optional(),
    tags: z.array(z.string()).optional(),
    estimateMin: z.number().nullable().optional(),
  };
  const taskPatch = (a: { due?: string | null; scheduledFor?: string | null; snoozedUntil?: string | null } & Record<string, unknown>): Partial<Task> => {
    const { due, scheduledFor, snoozedUntil, id: _id, ...rest } = a;
    return defined({ ...rest, dueAt: toMs(due), scheduledFor: toMs(scheduledFor, 'start'), snoozedUntil: toMs(snoozedUntil, 'start') }) as Partial<Task>;
  };

  add('tasks_search', 'Find tasks. Open ones by default, ranked.', {
    q: z.string().optional(), status: z.array(z.enum(STATUSES)).optional(), projectId: z.string().optional(), limit: z.number().int().max(100).optional(),
  }, (a) => repos.tasks.list({ q: a.q, status: a.status ?? ['inbox', 'todo', 'doing', 'waiting'], projectId: a.projectId, limit: a.limit ?? 20 }).map(taskBrief), true);

  add('task_create', 'Add a task.', { title: z.string(), ...taskFields, parentId: z.string().optional() },
    (a) => taskBrief(repos.tasks.create({ status: 'todo', ...taskPatch(a), source: 'agent' })));

  add('task_update', 'Change a task. null clears a field.', { id: z.string(), title: z.string().optional(), ...taskFields, snoozedUntil: when.nullable().optional(), pinned: z.boolean().optional() },
    (a) => taskBrief(repos.tasks.update(a.id, taskPatch(a))));

  add('task_complete', 'Mark a task done.', { id: z.string() }, (a) => taskBrief(repos.tasks.complete(a.id)));

  add('task_link', 'Attach a ticket, PR, thread, doc, meeting, session, url or file to a task.', {
    id: z.string(), kind: z.enum(['ticket', 'pr', 'thread', 'doc', 'meeting', 'session', 'url', 'file']), title: z.string(), url: z.string(), ref: z.string().optional(),
  }, ({ id, ...link }) => ({ id, links: repos.tasks.addLink(id, link).links.length }));

  add('projects_list', 'Projects and initiatives with open task counts.', {}, () => {
    const open = repos.tasks.openByProject();
    return {
      initiatives: repos.initiatives.list().map((i) => ({ id: i.id, title: i.title, status: i.status })),
      projects: repos.projects.list().map((p) => defined({ id: p.id, title: p.title, status: p.status, initiativeId: p.initiativeId ?? undefined, open: open.get(p.id) ?? 0 })),
    };
  }, true);

  add('project_upsert', 'Create a project, or update one by id or exact title.', {
    id: z.string().optional(), title: z.string(), notes: z.string().optional(), status: z.enum(LIFECYCLE).optional(), weight: z.number().min(0).max(3).optional(), initiativeId: z.string().nullable().optional(),
  }, ({ id, ...fields }) => {
    const existing = id ? repos.projects.must(id) : repos.projects.list().find((p) => p.title.toLowerCase() === fields.title.toLowerCase());
    // Found by title: the stored spelling stays.
    const p = existing ? repos.projects.update(existing.id, defined({ ...fields, title: id ? fields.title : undefined })) : repos.projects.create(defined(fields));
    return { id: p.id, title: p.title, status: p.status };
  });

  add('initiative_upsert', 'Create an initiative, or update one by id or exact title.', {
    id: z.string().optional(), title: z.string(), notes: z.string().optional(), status: z.enum(LIFECYCLE).optional(), weight: z.number().min(0).max(3).optional(), horizon: z.string().nullable().optional(),
  }, ({ id, ...fields }) => {
    const existing = id ? repos.initiatives.must(id) : repos.initiatives.list().find((i) => i.title.toLowerCase() === fields.title.toLowerCase());
    const i = existing ? repos.initiatives.update(existing.id, defined({ ...fields, title: id ? fields.title : undefined })) : repos.initiatives.create(defined(fields));
    return { id: i.id, title: i.title, status: i.status };
  });

  const suggestion = z.object({
    kind: z.enum(['new_task', 'update_task', 'complete_task', 'followup', 'link', 'insight', 'question']),
    title: z.string(),
    rationale: z.string().optional(),
    payload: z.record(z.string(), z.unknown()).optional().describe('new_task/followup: task fields; update_task: {taskId, patch}; complete_task: {taskId}; link: {taskId, link}; question: {question, options}'),
    source: z.enum(SOURCES).optional(), sourceRef: z.string().optional(), sourceUrl: z.string().optional(),
    confidence: z.number().min(0).max(1).optional(),
  });
  const suggest = (items: z.infer<typeof suggestion>[]) => ({ created: items.map((s) => repos.suggestions.create(defined(s) as never).id) });
  add('suggestion_create', 'Propose one change for the user to accept or dismiss in the Inbox.', suggestion.shape, (a) => suggest([a]));
  add('suggestions_create', 'Propose changes for the user to accept or dismiss in the Inbox. Use for anything inferred rather than asked for.', { items: z.array(suggestion).max(30) }, (a) => suggest(a.items));

  add('signals_search', 'Search raw events collected from chat, tickets, meetings, calendar, git and sessions.', {
    q: z.string().optional(), source: z.enum(SOURCES).optional(), sinceHours: z.number().optional(), triage: z.enum(['new', 'ignored', 'suggested', 'linked']).optional(), limit: z.number().int().max(100).optional(),
  }, (a) => repos.signals.list({ q: a.q, source: a.source, triage: a.triage, since: a.sinceHours ? Date.now() - a.sinceHours * HOUR : undefined, limit: a.limit ?? 20 })
    .map((s) => defined({ id: s.id, source: s.source, kind: s.kind, title: s.title, body: clip(s.body, 240) || undefined, actor: s.actor ?? undefined, at: stamp(s.occurredAt), url: s.url ?? undefined, triage: s.triage })), true);

  add('signals_emit', 'Store events read from a source. Safe to repeat: an event already stored (same source and externalId) is skipped.', {
    items: z.array(z.object({
      source: z.enum(SOURCES), kind: z.string(), externalId: z.string(), title: z.string(), body: z.string().optional(), url: z.string().optional(),
      actor: z.string().optional(), occurredAt: when.optional(), payload: z.record(z.string(), z.unknown()).optional(),
    })).max(100),
  }, (a) => {
    const fresh = repos.signals.ingest(a.items.map(({ occurredAt, ...s }) => defined({ ...s, occurredAt: toMs(occurredAt, 'start') ?? undefined }) as never));
    return { stored: fresh.length, skipped: a.items.length - fresh.length };
  });

  add('sessions_list', 'Claude Code sessions on this Mac and what each is doing.', { includeEnded: z.boolean().optional() },
    (a) => repos.sessions.list(a.includeEnded).slice(0, 30).map((s) => defined({
      id: s.id, name: s.name ?? undefined, repo: s.repo ?? s.cwd, branch: s.branch ?? undefined, ticket: s.ticket ?? undefined, state: s.state,
      sinceMin: Math.round((Date.now() - s.stateSince) / 60_000), title: clip(s.title ?? s.lastUserPrompt, 120) || undefined, taskId: s.taskId ?? undefined, pr: s.pr?.url,
    })), true);

  add('session_recap', 'Short recap of one Claude Code session: goal, done, open, next.', { id: z.string() }, (a) => env.recap(a.id), true);

  add('meetings_search', 'Meetings by text and time window. Default: yesterday to a week ahead.', { q: z.string().optional(), from: when.optional(), to: when.optional() }, (a) => {
    const q = a.q?.toLowerCase();
    return repos.meetings.list(toMs(a.from, 'start') ?? Date.now() - DAY, toMs(a.to) ?? Date.now() + 7 * DAY)
      .filter((m) => !q || `${m.title} ${m.attendees.join(' ')}`.toLowerCase().includes(q)).slice(0, 25).map(meetingBrief);
  }, true);

  const meeting = z.object({
    id: z.string().optional(), source: z.enum(['calendar', 'meeting']).optional(), externalId: z.string().optional(), title: z.string().optional(),
    startAt: when.optional().describe('the real start as an ISO datetime, with the offset or Z when the source gives one. A bare date means "time unknown" and is stored that way, never as midnight'), endAt: when.optional(),
    attendees: z.array(z.string()).optional(), joinUrl: z.string().nullable().optional(), location: z.string().nullable().optional(), summary: z.string().nullable().optional(),
    actionItems: z.array(z.string()).optional(), recordingUrl: z.string().nullable().optional(), prepNote: z.string().nullable().optional(),
  });
  const BARE_DATE = /^\d{4}-\d{2}-\d{2}$/;
  const upsertMeeting = ({ id, startAt, endAt, ...rest }: z.infer<typeof meeting>) => {
    // A day without a time is kept as that: the row sorts on its day and is flagged so nothing shows it as 00:00.
    const startKnown = startAt ? !BARE_DATE.test(startAt) : undefined;
    const fields = defined({ ...rest, startAt: toMs(startAt, 'start') ?? undefined, endAt: toMs(startKnown === false && !endAt ? startAt : endAt) ?? undefined, startKnown });
    if (id) return meetingBrief(repos.meetings.update(id, fields));
    if (!fields.source || !fields.externalId) throw new Error('give id, or source and externalId');
    return meetingBrief(repos.meetings.upsert(fields as never));
  };
  add('meeting_upsert', 'Create or update a meeting by source and externalId (or by id).', meeting.shape, upsertMeeting);
  add('meetings_upsert', 'Create or update several meetings in one call, each by source and externalId (or by id). Left-out or null fields keep their stored value. With window, calendar events in it missing from items are marked cancelled.', {
    items: z.array(meeting).max(60),
    window: z.object({ from: when, to: when }).optional().describe('calendar sync only, and only when items holds every event of that window that the user has not declined'),
  }, (a) => {
    const failed: string[] = [];
    const timeless = a.items.filter((item) => item.startAt && BARE_DATE.test(item.startAt)).map((item) => item.externalId ?? item.title ?? '?');
    let saved = 0;
    for (const item of a.items) {
      try {
        // A sync that did not find a field this time says null; that must not erase what an earlier pass found.
        upsertMeeting(Object.fromEntries(Object.entries(item).filter(([, v]) => v !== null)) as typeof item);
        saved++;
      } catch (err) {
        failed.push(`${item.externalId ?? item.id ?? item.title ?? '?'}: ${(err as Error).message}`);
      }
    }
    const from = toMs(a.window?.from, 'start');
    const to = toMs(a.window?.to);
    const cancelled = typeof from === 'number' && typeof to === 'number' && !failed.length
      ? repos.meetings.reconcile(from, to, a.items.filter((item) => (item.source ?? 'calendar') === 'calendar' && item.externalId).map((item) => item.externalId!))
      : 0;
    return {
      saved, ...(failed.length && { failed }), ...(cancelled && { cancelled }),
      ...(timeless.length && { storedWithoutTime: timeless, hint: 'These had a date but no time. If the source has the real start time, send them again with it.' }),
    };
  });

  add('notes_search', 'Search notes (live scratchpad, dumps, meeting notes, journal, briefs).', {
    q: z.string().optional(), kind: z.enum(['live', 'dump', 'meeting', 'journal', 'brief']).optional(), taskId: z.string().optional(), meetingId: z.string().optional(), limit: z.number().int().max(50).optional(),
  }, (a) => repos.notes.list({ ...a, limit: a.limit ?? 10 }).map((n) => ({ id: n.id, kind: n.kind, title: n.title, body: clip(n.body, 600), updated: stamp(n.updatedAt) })), true);

  add('note_write', 'Create a note, or with id replace (or append to) its body.', {
    id: z.string().optional(), title: z.string().optional(), body: z.string(), kind: z.enum(['live', 'dump', 'meeting', 'journal', 'brief']).optional(),
    taskId: z.string().optional(), meetingId: z.string().optional(), append: z.boolean().optional(),
  }, ({ id, append, ...fields }) => {
    const note = id
      ? repos.notes.update(id, defined({ ...fields, body: append ? `${repos.notes.must(id).body}\n${fields.body}` : fields.body }))
      : repos.notes.create(defined(fields));
    return { id: note.id, title: note.title };
  });

  const personBrief = (p: { id: Id; name: string; handles: Record<string, string>; notes: string; lastContactAt: Ms | null }) =>
    defined({ id: p.id, name: p.name, handles: Object.keys(p.handles).length ? p.handles : undefined, notes: clip(p.notes, 300) || undefined, lastContact: p.lastContactAt ? stamp(p.lastContactAt) : undefined });
  const personFields = { handles: z.record(z.string(), z.string()).optional().describe('e.g. {email, chat}'), notes: z.string().optional(), lastContactAt: when.optional() };
  add('people_search', 'Look up people the user works with.', { q: z.string().optional() }, (a) => repos.people.list(a.q).slice(0, 25).map(personBrief), true);
  add('person_update', 'Change a person by id.', { id: z.string(), name: z.string().optional(), ...personFields },
    ({ id, lastContactAt, ...f }) => personBrief(repos.people.update(id, defined({ ...f, lastContactAt: toMs(lastContactAt, 'start') ?? undefined }))));
  add('person_upsert', 'Add a person, or merge into the one with the same name.', { name: z.string(), ...personFields },
    ({ lastContactAt, ...f }) => personBrief(repos.people.upsert(defined({ ...f, lastContactAt: toMs(lastContactAt, 'start') ?? undefined }) as { name: string })));

  add('memory_list', 'List memory files (markdown you keep about the user).', {}, () => repos.memory.list().map((f) => `${f.path} (${f.size}b, ${stamp(f.updatedAt)})`).join('\n') || '(empty)', true);
  add('memory_read', 'Read a memory file.', { path: z.string().describe('e.g. profile.md, people/sam.md') }, (a) => repos.memory.read(a.path).content, true);
  add('memory_write', 'Write a memory file (replaces it; append adds to the end).', { path: z.string(), content: z.string(), append: z.boolean().optional() }, (a) => {
    let content = a.content;
    if (a.append) {
      try { content = `${repos.memory.read(a.path).content.trimEnd()}\n${a.content}`; } catch { /* new file */ }
    }
    return `saved ${repos.memory.write(a.path, content).path}`;
  });

  add('nudge', 'Show the user a notification. priority 0 notch only, 1 toast, 2 toast plus system notification.', {
    title: z.string(), body: z.string().optional(), priority: z.number().int().min(0).max(2).optional(),
    kind: z.enum(['session', 'meeting', 'task', 'brief', 'question', 'insight', 'system']).optional(), url: z.string().optional(), dedupeKey: z.string().optional(),
  }, ({ url, ...n }) => ({ id: repos.nudges.create({ kind: 'insight', priority: 1, ...defined(n), actions: url ? [{ id: 'open', label: 'Open', kind: 'open_url', url }] : [] } as never).id }));

  add('ask_user', 'Ask the user one question when the decision is theirs. Returns their answer, or says there is none yet.', {
    question: z.string(), options: z.array(z.string()).max(6).optional(),
  }, async (a) => {
    if (env.ask) return env.ask(a.question, a.options);
    repos.suggestions.create({ kind: 'question', title: a.question, payload: defined({ question: a.question, options: a.options }), source: 'agent' });
    return 'The user is not here. The question is in their Inbox; continue without the answer.';
  });

  add('request_approval', 'Queue an external write, or a command the sandbox stops, for the user to approve. tool is "Bash" (input {command, cwd?}) or the exact connector tool name with its exact input: the user sees that input. Returns at once.', {
    tool: z.string(), input: z.record(z.string(), z.unknown()), summary: z.string().describe('one line saying what this does and why, e.g. "Post in #general: shipping at 5"'),
    target: z.string().optional().describe('channel, person, repo or ticket'),
  }, (a) => {
    if (a.tool !== 'Bash' && (!a.tool.startsWith('mcp__') || a.tool.startsWith('mcp__steward__'))) throw new Error('tool must be "Bash" or a connector tool name (mcp__…)');
    if (a.tool !== 'Bash' && env.knownConnectorTool(a.tool) === false) throw new Error(`${a.tool} is not a tool of a connected server; use the exact name`);
    const problem = env.checkApproval(a);
    if (problem) throw new Error(problem);
    const verdict = decide(a.tool, a.input, env.policy());
    if (verdict.verdict === 'allow') return 'This does not need approval. Just run it.';
    const [, server = ''] = a.tool.split('__');
    const approval = repos.approvals.create({
      kind: a.tool === 'Bash' ? 'bash' : `${server.replace(/^claude_ai_/, '').toLowerCase()}.${a.tool.split('__').slice(2).join('__')}`,
      summary: a.summary, tool: a.tool, input: a.input, note: approvalNote(verdict), target: a.target ?? null, threadId: env.threadId ?? null,
    });
    return `Queued as approval ${approval.id}. The user decides in the app and the result is posted back here. Do not wait or retry; say what is waiting for them.`;
  });

  add('ui_command', 'Drive the app UI: open a view, show a note, focus a session window, speak, open a url, or toast.', {
    command: z.enum(['open_view', 'show_note', 'focus_session', 'speak', 'open_url', 'toast']), args: z.record(z.string(), z.unknown()).optional().describe('{view} | {noteId} | {sessionId} | {text} | {url} | {text}'),
  }, (a) => {
    ctx.bus.emit('ui.command', { command: a.command, args: a.args ?? {} });
    return 'sent';
  });

  add('activity_summary', 'Where the time went: per app and per task. Default: today.', { from: when.optional(), to: when.optional() }, (a) => {
    const s = repos.activity.summary(toMs(a.from, 'start') ?? startOfDay(Date.now()), toMs(a.to) ?? Date.now());
    const min = (ms: number) => Math.round(ms / 60_000);
    return { focusMin: min(s.focusMs), switches: s.switches, byApp: s.byApp.slice(0, 10).map((x) => `${x.app} ${min(x.ms)}m`), byTask: s.byTask.slice(0, 10).map((x) => `${x.title} ${min(x.ms)}m`) };
  }, true);

  add('loose_ends', 'Things the user promised or started and then left: commitments still open, sessions left waiting, people gone quiet, stuck pull requests, pages opened day after day with no task. The same list the app shows.', {},
    () => looseEnds(ctx).groups.map((g) => ({ group: g.title, items: g.items.map((e) => defined({ title: clip(e.title, 120), reason: e.reason, since: stamp(e.since), url: e.url ?? undefined, opensAt: e.place?.path })) })), true);

  add('schedule_job', 'Create, replace or remove a recurring agent job that runs a prompt on the fast model.', {
    name: z.string().regex(/^[a-z0-9][a-z0-9-]{1,40}$/), prompt: z.string().optional(), everyMin: z.number().int().min(5).optional(), at: z.string().regex(/^\d{1,2}:\d{2}$/).optional(),
    days: z.array(z.number().int().min(0).max(6)).optional().describe('0 = Sunday'), connectors: z.array(z.string()).optional(), remove: z.boolean().optional(),
  }, (a) => env.schedule({ name: a.name, prompt: a.prompt, connectors: a.connectors, remove: a.remove, schedule: a.everyMin ? { everyMin: a.everyMin } : a.at ? { at: a.at, days: a.days } : undefined }));

  add('cost_status', 'Agent spend today and this month against the caps.', {}, () => {
    const t = ctx.cost.totals();
    return `today $${t.todayUsd.toFixed(2)} of $${t.dailyCapUsd}, month $${t.monthUsd.toFixed(2)} of $${t.monthlyCapUsd}, billing ${t.billing}`;
  }, true);

  add('app_snapshot', 'Checkpoint the Steward source tree before editing it.', { label: z.string().optional() }, async (a) => `checkpoint ${(await env.self.snapshot(a.label)).ref}`);
  add('app_restore', 'Put the Steward source tree back to a checkpoint (the current state is checkpointed first).', { ref: z.string() }, (a) => env.self.restore(a.ref));
  add('app_rebuild', 'Build the app from source and relaunch it. Returns the build log tail, or says the user has to approve the change first.', {}, async () => {
    const out = await env.self.rebuild({ threadId: env.threadId });
    if (out.approvalId) return out.log;
    return `${out.ok ? 'Build ok; the app is relaunching.' : 'Build failed.'}\n${out.log.slice(-2500)}`;
  });

  add('connector_tools', 'Find read tools on the user\'s connectors (chat, mail, calendar, tickets, docs, meetings). Returns names and input schemas.', { query: z.string().describe('service and intent, e.g. "calendar list events"') }, (a) => env.bridge.tools(a.query), true);
  add('connector_read', 'Run one connector read tool and get its raw result.', { tool: z.string(), input: z.record(z.string(), z.unknown()) }, (a) => env.bridge.read(a.tool, a.input), true);
  return defs;
}

export const BRIDGE_TOOLS = ['connector_tools', 'connector_read'];

/** `names` picks a subset. `deferRare` (chat) keeps only the core tools in the prompt and leaves the rest to ToolSearch. */
export function stewardServer(env: ToolEnv, names: string[] | 'all', opts: { deferRare?: boolean; except?: string[] } = {}): McpSdkServerConfigWithInstance {
  const tools = stewardTools(env).filter((t) => (names === 'all' || names.includes(t.name)) && !opts.except?.includes(t.name));
  return createSdkMcpServer({ name: 'steward', version: '1', tools, ...(!opts.deferRare && { alwaysLoad: true }) });
}
