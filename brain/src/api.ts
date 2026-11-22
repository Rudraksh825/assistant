import type { AppContext, UiContext } from './core/context.js';
import type { Router } from './core/http.js';
import { VERSION } from './core/paths.js';
import { parseSchedule } from './core/scheduler.js';
import type { Id, Ms } from './core/types.js';
import { invalid, isPlainObject, notFound } from './core/util.js';
import { registerApprovalRoutes } from './approvals-api.js';
import { expandHome, settings as effectiveSettings } from './collectors/settings.js';
import { findTranscript, readTurns } from './collectors/transcript.js';
import type { SessionTurns } from './core/types.js';
import { sessionPlace, suggestionPlace, taskPlace } from './domain/places.js';
import { dismissLooseEnd, looseEnds, trackLooseEnd } from './jobs/loose-ends.js';
import { draftReply, seeMore } from './jobs/places.js';
import { buildState } from './domain/state.js';

const OK = { ok: true };
const items = <T>(list: T[]) => ({ items: list });

function text(v: unknown, name: string): string {
  if (typeof v !== 'string' || !v.trim()) throw invalid(`${name} is required`);
  return v;
}
function ids(v: unknown): Id[] {
  if (!Array.isArray(v) || v.some((id) => typeof id !== 'string')) throw invalid('ids must be an array of strings');
  return v;
}
function num(q: URLSearchParams, name: string): number | undefined {
  const raw = q.get(name);
  if (raw === null || raw === '') return undefined;
  const n = Number(raw);
  if (!Number.isFinite(n)) throw invalid(`${name} must be a number`);
  return n;
}
const str = (q: URLSearchParams, name: string) => q.get(name) || undefined;

interface Crud<T> { create(input: any): T; must(id: Id): T; update(id: Id, input: any): T; remove(id: Id): void }

/** Handlers stay thin: validate, call a repo or the agent seam, return. */
export function registerRoutes(r: Router, ctx: AppContext, startedAt: Ms): void {
  const { repos, agent } = ctx;
  const log = ctx.log.child('api');

  const mount = <T>(base: string, repo: Crud<T>, list: (q: URLSearchParams) => T[]) => {
    r.get(base, ({ query }) => items(list(query)));
    r.post(base, ({ body }) => repo.create(body));
    r.get(`${base}/:id`, ({ params }) => repo.must(params.id!));
    r.patch(`${base}/:id`, ({ params, body }) => repo.update(params.id!, body));
    r.delete(`${base}/:id`, ({ params }) => {
      repo.remove(params.id!);
      return OK;
    });
  };

  r.get('/health', () => ({ ok: true, version: VERSION, uptimeMs: Date.now() - startedAt }));
  r.get('/state', () => buildState(ctx));

  r.post('/tasks/reorder', ({ body }) => {
    repos.tasks.reorder(ids(body.ids));
    return OK;
  });
  r.post('/tasks/rerank', () => {
    repos.tasks.rerank();
    return OK;
  });
  // The task's place: where it came from, what was fetched about it, what it touches. Local reads only.
  r.get('/tasks/:id/place', ({ params }) => taskPlace(ctx, params.id!));
  r.post('/tasks/:id/context', ({ params, query }) => seeMore(ctx, 'task', params.id!, query.has('refresh')).context);
  r.post('/tasks/:id/draft-reply', ({ params }) => draftReply(ctx, params.id!).context);
  mount('/tasks', repos.tasks, (q) =>
    repos.tasks.list({ status: str(q, 'status')?.split(','), projectId: str(q, 'projectId'), parentId: str(q, 'parentId'), q: str(q, 'q'), limit: num(q, 'limit') }));
  r.post('/tasks/:id/complete', ({ params }) => repos.tasks.complete(params.id!));
  r.post('/tasks/:id/start', ({ params, query }) => repos.tasks.start(params.id!, query.get('exclusive') === '1'));
  r.post('/tasks/:id/snooze', ({ params, body }) => {
    if (typeof body.until !== 'number') throw invalid('until must be epoch milliseconds');
    return repos.tasks.snooze(params.id!, body.until);
  });

  mount('/projects', repos.projects, () => repos.projects.list());
  mount('/initiatives', repos.initiatives, () => repos.initiatives.list());
  r.get('/tree', () => {
    const open = repos.tasks.openByProject();
    const done = repos.tasks.doneByProject();
    const projects = repos.projects.list().map((p) => ({ ...p, openTasks: open.get(p.id) ?? 0, doneTasks: done.get(p.id) ?? 0 }));
    const initiatives = repos.initiatives.list();
    const known = new Set(initiatives.map((i) => i.id));
    return {
      initiatives: initiatives.map((i) => ({ ...i, projects: projects.filter((p) => p.initiativeId === i.id) })),
      looseProjects: projects.filter((p) => !p.initiativeId || !known.has(p.initiativeId)),
    };
  });

  r.get('/suggestions', ({ query }) => items(repos.suggestions.list(str(query, 'status'))));
  r.post('/suggestions/accept-all', ({ body }) => repos.suggestions.acceptAll(ids(body.ids)));
  r.post('/suggestions/:id/accept', ({ params, body }) => repos.suggestions.accept(params.id!, body.edits));
  r.post('/suggestions/:id/dismiss', ({ params }) => repos.suggestions.dismiss(params.id!));
  r.get('/suggestions/:id/place', ({ params }) => suggestionPlace(ctx, params.id!));
  r.post('/suggestions/:id/context', ({ params, query }) => seeMore(ctx, 'suggestion', params.id!, query.has('refresh')).context);

  r.get('/sessions', ({ query }) => items(repos.sessions.list(query.get('includeEnded') === '1')));
  r.get('/sessions/:id', ({ params }) => repos.sessions.must(params.id!));
  r.patch('/sessions/:id', ({ params, body }) => {
    repos.sessions.must(params.id!);
    return repos.sessions.upsert({ id: params.id!, ...('taskId' in body && { taskId: body.taskId }), ...('title' in body && { title: body.title }), ...('notes' in body && { notes: body.notes }) });
  });
  r.get('/sessions/:id/place', ({ params }) => sessionPlace(ctx, params.id!));
  // The readable tail of the conversation, from the transcript on this machine. No model, bounded work.
  r.get('/sessions/:id/turns', ({ params, query }): SessionTurns => {
    const session = repos.sessions.must(params.id!);
    const limit = Math.min(200, Math.max(1, num(query, 'limit') ?? 30));
    const file = findTranscript(expandHome(effectiveSettings(ctx).code.claudeDir), session.id, session.cwd);
    if (file) return { ...readTurns(file, limit), from: 'transcript' };
    const items: SessionTurns['items'] = [];
    if (session.lastUserPrompt) items.push({ role: 'user', at: null, text: session.lastUserPrompt });
    if (session.lastAssistantText) items.push({ role: 'assistant', at: null, text: session.lastAssistantText });
    return { items, from: items.length ? 'summary' : 'none', truncated: items.length > 0 };
  });
  r.get('/sessions/:id/recap', async ({ params, query }) => {
    const session = repos.sessions.must(params.id!);
    const key = `recap:${session.id}`;
    const cached = repos.kv.get<{ text: string; at: Ms }>(key);
    if (cached && cached.at >= session.updatedAt && !query.has('refresh')) return { text: cached.text };
    const recap = await agent.recapSession(session.id);
    repos.kv.set(key, { text: recap, at: Date.now() });
    return { text: recap };
  });

  r.get('/meetings', ({ query }) => items(repos.meetings.list(num(query, 'from'), num(query, 'to'))));
  r.get('/meetings/:id', ({ params }) => repos.meetings.must(params.id!));
  r.post('/meetings/:id/prep', ({ params }) => agent.prepMeeting(repos.meetings.must(params.id!).id));

  mount('/notes', repos.notes, (q) =>
    repos.notes.list({ kind: str(q, 'kind'), taskId: str(q, 'taskId'), meetingId: str(q, 'meetingId'), q: str(q, 'q'), limit: num(q, 'limit') }));
  mount('/people', repos.people, (q) => repos.people.list(str(q, 'q')));
  r.get('/signals', ({ query }) => items(repos.signals.list({ source: str(query, 'source'), since: num(query, 'since'), limit: num(query, 'limit') })));
  r.get('/activity/summary', ({ query }) => repos.activity.summary(num(query, 'from'), num(query, 'to')));
  r.get('/activity', ({ query }) => items(repos.activity.list(num(query, 'from'), num(query, 'to'))));

  r.post('/capture', ({ body }) => {
    const dump = text(body.text, 'text');
    const note = repos.notes.create({ kind: 'dump', title: dump.trim().split('\n')[0]!.slice(0, 80), body: dump });
    const context: UiContext = { ...(isPlainObject(body.context) ? body.context : {}), source: typeof body.source === 'string' ? body.source : undefined };
    // The note is safe on disk; parsing is the agent's job and must not hold the hotkey up.
    Promise.resolve().then(() => agent.capture(note.id, dump, context)).catch((err: Error) => {
      log.error('capture parsing failed', err);
      repos.nudges.create({ kind: 'system', title: 'Capture saved, not parsed', body: err.message, priority: 1 });
    });
    return { noteId: note.id };
  });

  r.get('/chat/threads', () => items(repos.chat.threads()));
  r.post('/chat/threads', ({ body }) => repos.chat.createThread(body));
  r.patch('/chat/threads/:id', ({ params, body }) => repos.chat.updateThread(params.id!, { title: text(body.title, 'title').trim().slice(0, 120) }));
  r.delete('/chat/threads/:id', ({ params }) => {
    const thread = repos.chat.thread(params.id!);
    agent.forget(thread.id);
    repos.chat.removeThread(thread.id);
    return OK;
  });
  r.get('/chat/questions', () => items(agent.questions()));
  r.get('/chat/threads/:id/messages', ({ params }) => items(repos.chat.messages(params.id!)));
  r.post('/chat/threads/:id/messages', async ({ params, body }) => {
    const message = repos.chat.addMessage({ threadId: params.id!, role: 'user', text: text(body.text, 'text') });
    const { runId } = await agent.chat(message.threadId, message.id, message.text, isPlainObject(body.context) ? body.context : undefined);
    return { messageId: message.id, runId };
  });
  r.post('/chat/threads/:id/interrupt', ({ params }) => {
    agent.interrupt(repos.chat.thread(params.id!).id);
    return OK;
  });
  r.post('/chat/answer', ({ body }) => {
    agent.answer(text(body.questionId, 'questionId'), text(body.answer, 'answer'));
    return OK;
  });

  registerApprovalRoutes(r, ctx);

  r.get('/loose-ends', () => looseEnds(ctx));
  r.post('/loose-ends/dismiss', ({ body }) => {
    dismissLooseEnd(ctx, text(body.id, 'id'));
    return OK;
  });
  r.post('/loose-ends/track', ({ body }) => trackLooseEnd(ctx, text(body.id, 'id')));

  r.post('/sensors/activity', ({ body }) => ({ ok: true, count: repos.activity.ingest(body.spans) }));
  r.post('/sensors/event', ({ body }) => {
    ctx.bus.emit('sensor.event', { kind: text(body.kind, 'kind'), at: typeof body.at === 'number' ? body.at : Date.now(), data: isPlainObject(body.data) ? body.data : undefined });
    return OK;
  });

  r.get('/nudges', () => items(repos.nudges.active()));
  r.post('/nudges/:id/dismiss', ({ params }) => repos.nudges.dismiss(params.id!));
  r.post('/nudges/:id/act', async ({ params, body }) => {
    const { nudge, action } = repos.nudges.act(params.id!, body.actionId);
    // `api` actions run here; every other kind is carried out by the surface that showed the nudge.
    // A nudge button is one click on a label; it must never stand in for an approval, a settings change or a rebuild.
    if (action.kind === 'api' && /^\/(approvals|settings|app|jobs|chat)(\/|$)/.test(action.path ?? '')) throw invalid('this action cannot be run from a nudge');
    const result = action.kind === 'api' && action.method && action.path
      ? await r.dispatch(action.method.toUpperCase(), action.path, { body: action.body })
      : undefined;
    return { nudge, action, result };
  });

  r.get('/runs', ({ query }) => items(ctx.cost.runs(num(query, 'limit'))));
  r.get('/cost', ({ query }) => ctx.cost.report(num(query, 'days')));

  // The effective config: what is in config.json over the defaults the collectors and jobs keep in code, so Settings shows what is really in force.
  const settings = () => ({ ...effectiveSettings(ctx), secretsSet: ctx.config.secretNames() });
  r.get('/settings', settings);
  r.put('/settings', ({ body }) => {
    const { secretsSet: _, ...patch } = body;
    ctx.config.update(patch);
    return settings();
  });
  r.post('/settings/secret', ({ body }) => {
    ctx.config.setSecret(text(body.name, 'name'), typeof body.value === 'string' ? body.value : '');
    return OK;
  });

  r.get('/jobs', () => items(ctx.scheduler.list()));
  r.patch('/jobs/:name', ({ params, body }) => {
    const name = params.name!;
    if (!ctx.scheduler.list().some((j) => j.name === name)) throw notFound(`job ${name}`);
    if ('enabled' in body) {
      if (typeof body.enabled !== 'boolean') throw invalid('enabled must be true or false');
      ctx.scheduler.setEnabled(name, body.enabled);
    }
    // null puts the job back on its own schedule.
    if ('schedule' in body) ctx.scheduler.setSchedule(name, body.schedule === null ? null : parseSchedule(body.schedule));
    return ctx.scheduler.list().find((j) => j.name === name);
  });
  r.post('/jobs/:name/run', ({ params }) => {
    // Jobs can run for minutes: start it, answer now, and let /jobs or `state.changed{jobs}` report the outcome.
    void ctx.scheduler.runNow(params.name!);
    return OK;
  });

  r.get('/memory', () => items(repos.memory.list()));
  r.get('/memory/*path', ({ params }) => repos.memory.read(params.path!));
  r.put('/memory/*path', ({ params, body }) => repos.memory.write(params.path!, body.content));
  r.delete('/memory/*path', ({ params }) => {
    repos.memory.remove(params.path!);
    return OK;
  });

  r.post('/app/rebuild', () => agent.rebuildApp());
}
