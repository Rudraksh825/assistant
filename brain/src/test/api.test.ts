import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, test } from 'node:test';
import { startBrain, type Brain } from '../app.js';
import type { StateSnapshot, Task } from '../core/types.js';

const home = mkdtempSync(join(tmpdir(), 'steward-test-'));
process.env.STEWARD_HOME = home;
process.env.STEWARD_LOG_LEVEL = 'silent';

let brain: Brain;
let base: string;

async function api<T = any>(method: string, path: string, body?: unknown, token: string | null = brain.token): Promise<{ status: number; data: T }> {
  const res = await fetch(base + path, {
    method,
    headers: { ...(token && { authorization: `Bearer ${token}` }), ...(body !== undefined && { 'content-type': 'application/json' }) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: res.status, data: (await res.json()) as T };
}
async function ok<T = any>(method: string, path: string, body?: unknown): Promise<T> {
  const { status, data } = await api<T>(method, path, body);
  assert.equal(status, 200, `${method} ${path}: ${JSON.stringify(data)}`);
  return data;
}

/** Opens /events and resolves with the first event of `type` that satisfies `match`. */
async function nextEvent(type: string, match: (data: any) => boolean, trigger: () => Promise<unknown>): Promise<any> {
  const res = await fetch(`${base}/events?token=${brain.token}`);
  assert.equal(res.status, 200);
  const reader = res.body!.getReader();
  const timeout = setTimeout(() => void reader.cancel(), 3000);
  let buffer = '';
  let triggered = false;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) throw new Error(`no ${type} event within 3s`);
      buffer += Buffer.from(value).toString('utf8');
      let end: number;
      while ((end = buffer.indexOf('\n\n')) !== -1) {
        const [eventLine, dataLine] = buffer.slice(0, end).split('\n');
        buffer = buffer.slice(end + 2);
        const name = eventLine!.replace('event: ', '');
        const data = JSON.parse(dataLine!.replace('data: ', ''));
        if (name === 'hello' && !triggered) {
          triggered = true;
          await trigger();
        }
        if (name === type && match(data)) return data;
      }
    }
  } finally {
    clearTimeout(timeout);
    await reader.cancel();
  }
}

before(async () => {
  brain = await startBrain({ port: 0 });
  base = `http://127.0.0.1:${brain.port}`;
});
after(async () => {
  await brain.stop();
  rmSync(home, { recursive: true, force: true });
});

test('data dir is private and advertises token + port', () => {
  assert.equal(statSync(home).mode & 0o777, 0o700);
  assert.equal(statSync(join(home, 'brain.token')).mode & 0o777, 0o600);
  assert.equal(readFileSync(join(home, 'brain.token'), 'utf8'), brain.token);
  assert.equal(readFileSync(join(home, 'brain.port'), 'utf8'), String(brain.port));
  assert.ok(JSON.parse(readFileSync(join(home, 'config.json'), 'utf8')).budget.dailyCapUsd > 0);
});

test('auth: /health is open, everything else needs the bearer token', async () => {
  const health = await api('GET', '/health', undefined, null);
  assert.equal(health.status, 200);
  assert.equal(health.data.ok, true);
  for (const token of [null, 'wrong', brain.token.slice(0, -1)]) {
    const res = await api('GET', '/state', undefined, token);
    assert.equal(res.status, 401);
    assert.equal(res.data.error.code, 'unauthorized');
  }
  // The query-string token is for SSE only.
  assert.equal((await fetch(`${base}/tasks?token=${brain.token}`)).status, 401);
  assert.equal((await api('GET', '/nope')).status, 404);
});

test('tasks: create, read, patch, list, complete, delete', async () => {
  const created = await ok<Task>('POST', '/tasks', { title: 'Write the brief', priority: 2, tags: ['acme'], bogus: 1, score: 99 });
  assert.equal(created.status, 'todo');
  assert.equal(created.source, 'manual');
  assert.deepEqual(created.tags, ['acme']);
  assert.ok(created.score > 0 && created.score < 99);
  assert.deepEqual(created.scoreReasons, ['high priority']);

  assert.deepEqual(await ok('GET', `/tasks/${created.id}`), created);

  const patched = await ok<Task>('PATCH', `/tasks/${created.id}`, { priority: 3, pinned: true, links: [{ kind: 'ticket', title: 'ENG-123', url: 'https://example.com/ENG-123' }] });
  assert.equal(patched.pinned, true);
  assert.ok(patched.score > created.score);
  assert.deepEqual(patched.scoreReasons, ['pinned', 'urgent']);

  const started = await ok<Task>('POST', `/tasks/${created.id}/start`);
  assert.equal(started.status, 'doing');

  const listed = await ok<{ items: Task[] }>('GET', '/tasks?status=doing,todo&q=brief');
  assert.deepEqual(listed.items.map((t) => t.id), [created.id]);
  assert.deepEqual((await ok<{ items: Task[] }>('GET', '/tasks?status=waiting')).items, []);

  const snoozed = await ok<Task>('POST', `/tasks/${created.id}/snooze`, { until: Date.now() + 3_600_000 });
  assert.equal(snoozed.score, 0);

  const done = await ok<Task>('POST', `/tasks/${created.id}/complete`);
  assert.equal(done.status, 'done');
  assert.ok(done.completedAt);

  await ok('DELETE', `/tasks/${created.id}`);
  assert.equal((await api('GET', `/tasks/${created.id}`)).status, 404);
});

test('tasks: bad input is a 400, not a 500', async () => {
  for (const body of [{}, { title: 'x', priority: 9 }, { title: 'x', status: 'nope' }, { title: 'x', tags: 'acme' }, { title: 'x', projectId: 'missing' }]) {
    const res = await api('POST', '/tasks', body);
    assert.equal(res.status, 400, JSON.stringify(body));
    assert.equal(res.data.error.code, 'invalid');
  }
  const res = await fetch(`${base}/tasks`, { method: 'POST', headers: { authorization: `Bearer ${brain.token}` }, body: '{nope' });
  assert.equal(res.status, 400);
});

test('tasks: reorder puts manually ranked tasks first, in the given order', async () => {
  const a = await ok<Task>('POST', '/tasks', { title: 'Reorder A', priority: 3 });
  const b = await ok<Task>('POST', '/tasks', { title: 'Reorder B' });
  const c = await ok<Task>('POST', '/tasks', { title: 'Reorder C', priority: 1 });
  const titles = async () => (await ok<{ items: Task[] }>('GET', '/tasks?q=Reorder')).items.map((t) => t.title);
  assert.deepEqual(await titles(), ['Reorder A', 'Reorder C', 'Reorder B']);
  assert.deepEqual(await ok('POST', '/tasks/reorder', { ids: [b.id, c.id] }), { ok: true });
  assert.deepEqual(await titles(), ['Reorder B', 'Reorder C', 'Reorder A']);
  assert.equal((await api('POST', '/tasks/reorder', { ids: 'x' })).status, 400);
  for (const t of [a, b, c]) await ok('DELETE', `/tasks/${t.id}`);
});

test('projects and initiatives feed the tree and the ranking', async () => {
  const initiative = await ok('POST', '/initiatives', { title: 'Grow', weight: 3 });
  const project = await ok('POST', '/projects', { title: 'Acme launch', weight: 3, initiativeId: initiative.id });
  const loose = await ok('POST', '/projects', { title: 'Chores' });
  const task = await ok<Task>('POST', '/tasks', { title: 'Ship it', projectId: project.id });
  assert.deepEqual(task.scoreReasons, ['project: Acme launch', 'initiative: Grow']);

  const tree = await ok('GET', '/tree');
  assert.equal(tree.initiatives[0].projects[0].openTasks, 1);
  assert.deepEqual(tree.looseProjects.map((p: any) => p.title), ['Chores']);

  // Pausing the project is a ranking input: the task is rescored without being touched.
  await ok('PATCH', `/projects/${project.id}`, { status: 'paused' });
  await new Promise((r) => setTimeout(r, 20));
  const rescored = await ok<Task>('GET', `/tasks/${task.id}`);
  assert.ok(rescored.score < task.score);
  assert.equal(rescored.updatedAt, task.updatedAt);

  await ok('DELETE', `/projects/${project.id}`);
  assert.equal((await ok<Task>('GET', `/tasks/${task.id}`)).projectId, null);
  for (const path of [`/tasks/${task.id}`, `/projects/${loose.id}`, `/initiatives/${initiative.id}`]) await ok('DELETE', path);
});

test('suggestions: accept applies each kind and returns the affected task', async () => {
  const { suggestions } = brain.ctx.repos;
  const fresh = suggestions.create({ kind: 'new_task', title: 'Reply to the vendor', payload: { priority: 1 }, source: 'chat', sourceRef: 'msg-1', sourceUrl: 'https://example.com/t/1' });
  assert.equal((await ok('GET', '/suggestions?status=pending')).items.length, 1);

  const accepted = await ok('POST', `/suggestions/${fresh.id}/accept`, { edits: { title: 'Reply to Acme', priority: 2 } });
  assert.equal(accepted.suggestion.status, 'accepted');
  assert.equal(accepted.task.title, 'Reply to Acme');
  assert.equal(accepted.task.priority, 2);
  assert.equal(accepted.task.status, 'todo');
  assert.equal(accepted.task.source, 'chat');
  assert.equal(accepted.task.links[0].url, 'https://example.com/t/1');
  assert.equal((await api('POST', `/suggestions/${fresh.id}/accept`)).status, 409);
  const taskId = accepted.task.id;

  const update = suggestions.create({ kind: 'update_task', title: 'Bump', payload: { taskId, patch: { priority: 3 } } });
  assert.equal((await ok('POST', `/suggestions/${update.id}/accept`)).task.priority, 3);

  const link = suggestions.create({ kind: 'link', title: 'PR', payload: { taskId, link: { kind: 'pr', title: 'PR 7', url: 'https://example.com/pr/7' } } });
  assert.equal((await ok('POST', `/suggestions/${link.id}/accept`)).task.links.length, 2);

  const followup = suggestions.create({ kind: 'followup', title: 'Chase the contract', payload: { waitingOn: 'Sam' } });
  const waiting = (await ok('POST', `/suggestions/${followup.id}/accept`)).task;
  assert.equal(waiting.status, 'waiting');
  assert.equal(waiting.waitingOn, 'Sam');

  const complete = suggestions.create({ kind: 'complete_task', title: 'Done?', payload: { taskId } });
  const insight = suggestions.create({ kind: 'insight', title: 'You context-switch a lot on Tuesdays' });
  const broken = suggestions.create({ kind: 'complete_task', title: 'No target' });
  const all = await ok('POST', '/suggestions/accept-all', { ids: [complete.id, insight.id, broken.id] });
  assert.equal(all.accepted[0].task.status, 'done');
  assert.equal(all.accepted[1].task, undefined);
  assert.deepEqual(all.failed.map((f: any) => f.id), [broken.id]);

  assert.equal((await ok('POST', `/suggestions/${broken.id}/dismiss`)).status, 'dismissed');
  assert.equal((await ok('GET', '/suggestions?status=pending')).items.length, 0);
  for (const id of [taskId, waiting.id]) await ok('DELETE', `/tasks/${id}`);
});

test('state snapshot reflects tasks, sessions, meetings, nudges and budget', async () => {
  const now = Date.now();
  const doing = await ok<Task>('POST', '/tasks', { title: 'Current thing', status: 'doing' });
  const later = await ok<Task>('POST', '/tasks', { title: 'Snoozed thing', snoozedUntil: now + 3_600_000 });
  await ok('POST', '/tasks', { title: 'Overdue thing', dueAt: now - 3 * 86_400_000, status: 'inbox' });
  brain.ctx.repos.sessions.upsert({ id: 'sess-1', cwd: '/tmp/acme', state: 'waiting', taskId: doing.id });
  brain.ctx.repos.sessions.upsert({ id: 'sess-2', cwd: '/tmp/acme', state: 'ended' });
  brain.ctx.repos.meetings.upsert({ source: 'calendar', externalId: 'ev-1', title: 'Standup', startAt: now - 60_000, endAt: now + 600_000 });
  brain.ctx.repos.meetings.upsert({ source: 'calendar', externalId: 'ev-2', title: 'Review', startAt: now + 3_600_000, endAt: now + 7_200_000 });
  await ok('POST', '/notes', { kind: 'live', body: 'scratch' });
  brain.ctx.repos.nudges.create({ kind: 'task', title: 'Heads up', dedupeKey: 'k1' });
  brain.ctx.repos.nudges.create({ kind: 'task', title: 'Heads up again', dedupeKey: 'k1' });
  await new Promise((r) => setTimeout(r, 20));

  // A collector re-sending the same record is not a mutation.
  const before = brain.ctx.repos.meetings.list()[0]!;
  let events = 0;
  const off = brain.ctx.bus.on('state.changed', () => events++);
  assert.deepEqual(brain.ctx.repos.meetings.upsert({ source: 'calendar', externalId: 'ev-1', title: 'Standup' }), before);
  brain.ctx.repos.sessions.upsert({ id: 'sess-1', cwd: '/tmp/acme', state: 'waiting' });
  assert.deepEqual(await ok('PATCH', `/tasks/${doing.id}`, { title: 'Current thing' }), await ok('GET', `/tasks/${doing.id}`));
  await new Promise((r) => setTimeout(r, 5));
  off();
  assert.equal(events, 0);

  const state = await ok<StateSnapshot>('GET', '/state');
  assert.equal(state.now?.id, doing.id);
  assert.ok(state.now!.scoreReasons.includes('session waiting 0m'));
  assert.ok(state.top.length >= 2 && state.top.length <= 12);
  assert.ok(!state.top.some((t) => t.id === later.id));
  assert.deepEqual(state.sessions.map((s) => s.id), ['sess-1']);
  assert.equal(state.currentMeeting?.title, 'Standup');
  assert.equal(state.nextMeeting?.title, 'Review');
  assert.equal(state.counts.inbox, 1);
  assert.equal(state.counts.overdue, 1);
  assert.deepEqual(state.nudges.map((n) => n.title), ['Heads up']);
  assert.equal(state.liveNote?.body, 'scratch');
  assert.deepEqual(state.budget, { todayUsd: 0, dailyCapUsd: 15, monthUsd: 0, billing: 'login' });
  assert.deepEqual(state.agent, { busy: false, activity: null, available: false });
  assert.ok(Math.abs(state.serverTime - Date.now()) < 5000);
});

test('SSE: a mutation is followed by state.changed', async () => {
  const event = await nextEvent('state.changed', (d) => d.entities.includes('tasks'), () => ok('POST', '/tasks', { title: 'Announce me' }));
  assert.deepEqual(event.entities, ['tasks']);
  assert.equal((await fetch(`${base}/events`)).status, 401);
});

test('agent seam: capture, chat and approvals persist first and degrade clearly', async () => {
  const { noteId } = await ok('POST', '/capture', { text: 'Call Sam about the contract\nand book travel', source: 'hotkey' });
  assert.equal((await ok('GET', `/notes/${noteId}`)).kind, 'dump');

  const thread = await ok('POST', '/chat/threads', {});
  const error = await nextEvent('chat.error', (d) => d.threadId === thread.id, async () => {
    const sent = await ok('POST', `/chat/threads/${thread.id}/messages`, { text: 'What is next?' });
    assert.ok(sent.messageId && sent.runId);
  });
  assert.match(error.message, /not installed/);
  const messages = (await ok('GET', `/chat/threads/${thread.id}/messages`)).items;
  assert.deepEqual(messages.map((m: any) => [m.role, m.text]), [['user', 'What is next?']]);
  assert.equal((await ok('GET', '/chat/threads')).items[0].title, 'What is next?');

  const approval = brain.ctx.repos.approvals.create({ kind: 'chat.post', summary: 'Post to #general', tool: 'chat_post', input: { text: 'hi' }, threadId: thread.id });
  assert.ok((await ok('GET', '/nudges')).items.some((n: any) => n.kind === 'approval'));
  const decided = await ok('POST', `/approvals/${approval.id}/approve`, { edits: { text: 'hello' } });
  assert.equal(decided.status, 'failed');
  assert.deepEqual(decided.input, { text: 'hello' });
  assert.match(decided.result, /not installed/);
  assert.equal((await api('POST', `/approvals/${approval.id}/deny`)).status, 409);
  // A nudge button cannot be made into an approve button.
  const waiting = brain.ctx.repos.approvals.create({ kind: 'bash', summary: 'Push', tool: 'Bash', input: { command: 'git push' } });
  const bait = brain.ctx.repos.nudges.create({ kind: 'insight', title: 'Open the report', priority: 1, actions: [{ id: 'open', label: 'Open', kind: 'api', method: 'POST', path: `/approvals/${waiting.id}/approve` }] });
  assert.equal((await api('POST', `/nudges/${bait.id}/act`, { actionId: 'open' })).status, 400);
  assert.equal(brain.ctx.repos.approvals.must(waiting.id).status, 'pending');
  assert.equal((await api('POST', `/approvals/${waiting.id}/approve`, { edits: 'git push' })).status, 400, 'edits must be the whole input object');
  await ok('POST', `/approvals/${waiting.id}/deny`);
  assert.ok(!(await ok('GET', '/nudges')).items.some((n: any) => n.kind === 'approval'));
  assert.equal((await ok('GET', `/chat/threads/${thread.id}/messages`)).items.at(-1).role, 'system');

  assert.equal((await api('GET', '/sessions/sess-1/recap')).status, 503);
});

test('settings never leak secrets; memory cannot escape its directory', async () => {
  await ok('POST', '/settings/secret', { name: 'ANTHROPIC_API_KEY', value: 'sk-test-123' });
  const settings = await ok('PUT', '/settings', { budget: { dailyCapUsd: 20 } });
  assert.equal(settings.budget.dailyCapUsd, 20);
  assert.equal(settings.budget.monthlyCapUsd, 300);
  assert.deepEqual(settings.secretsSet, ['ANTHROPIC_API_KEY']);
  assert.ok(!JSON.stringify(await ok('GET', '/settings')).includes('sk-test-123'));
  assert.equal(statSync(join(home, 'secrets.env')).mode & 0o777, 0o600);
  assert.equal(brain.ctx.config.secret('ANTHROPIC_API_KEY'), 'sk-test-123');
  assert.equal((await api('PUT', '/settings', { budget: { dailyCapUsd: 'lots' } })).status, 400);

  await ok('PUT', '/memory/people/sam.md', { content: '# Sam\n' });
  assert.equal((await ok('GET', '/memory/people/sam.md')).content, '# Sam\n');
  assert.deepEqual((await ok('GET', '/memory')).items.map((f: any) => f.path), ['people/sam.md']);
  for (const path of ['/memory/..%2Fsecrets.env', '/memory/..%2F..%2Fescape.md', '/memory/%2Fetc%2Fhosts.md', '/memory/notes.txt']) {
    assert.equal((await api('GET', path)).status, 400, path);
    assert.equal((await api('PUT', path, { content: 'x' })).status, 400, path);
    assert.equal((await api('DELETE', path)).status, 400, path);
  }
  await ok('DELETE', '/memory/people/sam.md');
  assert.equal((await api('GET', '/memory/people/sam.md')).status, 404);
  assert.equal((await api('DELETE', '/memory/people/sam.md')).status, 404);
});

test('cost ledger: totals, budget nudge at 80%, background spend stops at the cap', async () => {
  const { cost } = brain.ctx;
  brain.ctx.config.update({ budget: { dailyCapUsd: 20 } });
  assert.equal(cost.canSpendBackground(), true);
  cost.record({ kind: 'triage', trigger: 'schedule', model: 'fast', billing: 'api', status: 'ok', costUsd: 17, inputTokens: 10, outputTokens: 5 });
  assert.equal(cost.canSpendBackground(), true);
  assert.ok((await ok('GET', '/nudges')).items.some((n: any) => n.kind === 'budget' && n.title === 'Budget at 80%'));
  cost.record({ kind: 'brief', trigger: 'schedule', model: 'main', billing: 'api', status: 'ok', costUsd: 4 });
  assert.equal(cost.canSpendBackground(), false);
  const report = await ok('GET', '/cost?days=7');
  assert.equal(report.today, 21);
  assert.deepEqual(report.byKind, [{ kind: 'triage', usd: 17 }, { kind: 'brief', usd: 4 }]);
  assert.equal((await ok('GET', '/runs?limit=1')).items.length, 1);
  assert.equal((await ok<StateSnapshot>('GET', '/state')).budget.billing, 'api');
});

test('jobs: listed, run on demand, never overlap', async () => {
  let runs = 0;
  let release!: () => void;
  brain.ctx.scheduler.register({ name: 'test.slow', schedule: { at: '03:00' }, run: () => new Promise<void>((r) => { runs++; release = r; }) });
  const listed = (await ok('GET', '/jobs')).items;
  assert.ok(listed.some((j: any) => j.name === 'core.rerank' && j.schedule === 'every 5m' && j.lastStatus === 'ok'));
  await ok('POST', '/jobs/test.slow/run');
  assert.equal((await api('POST', '/jobs/test.slow/run')).status, 409);
  brain.ctx.scheduler.tick();
  assert.equal(runs, 1);
  // Re-registering mid-run must not strand the job in "running".
  brain.ctx.scheduler.register({ name: 'test.slow', schedule: { at: '03:00' }, run: () => {} });
  release();
  await new Promise((r) => setTimeout(r, 10));
  const job = (await ok('GET', '/jobs')).items.find((j: any) => j.name === 'test.slow');
  assert.equal(job.lastStatus, 'ok');
  assert.equal(job.running, false);
  assert.equal((await api('POST', '/jobs/nope/run')).status, 404);

  const off = await ok('PATCH', '/jobs/test.slow', { enabled: false, schedule: { everyMin: 45 } });
  assert.deepEqual([off.enabled, off.schedule, off.scheduleSpec, off.customSchedule, off.nextRunAt], [false, 'every 45m', { everyMin: 45 }, true, null]);
  const stored = brain.ctx.db.prepare("SELECT enabled, schedule FROM jobs WHERE name = 'test.slow'").get() as { enabled: number; schedule: string };
  assert.deepEqual([stored.enabled, JSON.parse(stored.schedule)], [0, { everyMin: 45 }], 'both survive a restart');
  // A definition registered again (settings changed) does not undo the user's schedule.
  brain.ctx.scheduler.register({ name: 'test.slow', schedule: { at: '03:00' }, run: () => {} });
  assert.equal((await ok('GET', '/jobs')).items.find((j: any) => j.name === 'test.slow').schedule, 'every 45m');
  const back = await ok('PATCH', '/jobs/test.slow', { enabled: true, schedule: null });
  assert.deepEqual([back.enabled, back.schedule, back.customSchedule], [true, '03:00 daily', false]);
  assert.equal((await api('PATCH', '/jobs/test.slow', { schedule: { at: '9am' } })).status, 400);
  assert.equal((await api('PATCH', '/jobs/nope', { enabled: true })).status, 404);
});

test('a brain stopped in the tick it started in does not run its first tick on a closed database', async () => {
  const saved = process.env.STEWARD_HOME;
  const other = mkdtempSync(join(tmpdir(), 'steward-stop-'));
  process.env.STEWARD_HOME = other;
  const errors: unknown[] = [];
  const onError = (err: unknown) => errors.push(err);
  process.on('uncaughtException', onError);
  try {
    const second = await startBrain({ port: 0 });
    await second.stop();
    await new Promise((r) => setImmediate(r));
    assert.deepEqual(errors, []);
  } finally {
    process.off('uncaughtException', onError);
    process.env.STEWARD_HOME = saved;
    rmSync(other, { recursive: true, force: true });
  }
});

test('main-window additions: subtasks, startedAt, tree done counts, people, chat threads, questions, cost series', async () => {
  const parent = await ok<Task>('POST', '/tasks', { title: 'Parent' });
  const child = await ok<Task>('POST', '/tasks', { title: 'Child', parentId: parent.id });
  assert.deepEqual((await ok('GET', `/tasks?parentId=${parent.id}`)).items.map((t: Task) => t.id), [child.id]);

  assert.equal(parent.startedAt, null);
  const started = await ok<Task>('POST', `/tasks/${parent.id}/start`);
  assert.ok(started.startedAt! >= parent.createdAt);
  assert.equal((await ok<Task>('PATCH', `/tasks/${parent.id}`, { notes: 'still on it', startedAt: 1 })).startedAt, started.startedAt, 'kept while doing, and not the client\'s to set');
  assert.equal((await ok<Task>('PATCH', `/tasks/${parent.id}`, { status: 'todo' })).startedAt, null);

  const project = await ok('POST', '/projects', { title: 'Counted' });
  const done = await ok<Task>('POST', '/tasks', { title: 'Finished', projectId: project.id });
  await ok('POST', '/tasks', { title: 'Open', projectId: project.id });
  await ok('POST', `/tasks/${done.id}/complete`);
  const node = (await ok('GET', '/tree')).looseProjects.find((p: any) => p.id === project.id);
  assert.deepEqual([node.openTasks, node.doneTasks], [1, 1]);

  const person = await ok('POST', '/people', { name: 'Sam Rivera', handles: { chat: '@sam' } });
  assert.equal((await api('POST', '/people', { notes: 'nameless' })).status, 400);
  assert.ok((await ok('GET', '/people?q=rivera')).items.some((p: any) => p.id === person.id));
  await ok('DELETE', `/people/${person.id}`);
  assert.equal((await api('PATCH', `/people/${person.id}`, { notes: 'gone' })).status, 404);

  const thread = await ok('POST', '/chat/threads', {});
  brain.ctx.repos.chat.addMessage({ threadId: thread.id, role: 'assistant', text: 'Hello', costUsd: 0.12 });
  assert.deepEqual((await ok('GET', `/chat/threads/${thread.id}/messages`)).items.map((m: any) => [m.text, m.costUsd]), [['Hello', 0.12]]);
  assert.equal((await ok('PATCH', `/chat/threads/${thread.id}`, { title: '  Renamed  ' })).title, 'Renamed');
  assert.equal((await api('PATCH', `/chat/threads/${thread.id}`, { title: ' ' })).status, 400);
  await ok('DELETE', `/chat/threads/${thread.id}`);
  assert.equal((await api('GET', `/chat/threads/${thread.id}/messages`)).status, 404);
  assert.equal(brain.ctx.db.prepare('SELECT COUNT(*) AS n FROM chat_messages WHERE threadId = ?').get(thread.id)!.n, 0);
  assert.deepEqual((await ok('GET', '/chat/questions')).items, []);

  brain.ctx.cost.record({ kind: 'sync:chat', trigger: 'schedule', model: 'm', billing: 'login', status: 'ok', costUsd: 0.25 });
  const cost = await ok('GET', '/cost?days=2');
  const day = new Date().toLocaleDateString('sv');
  assert.ok(cost.byDayKind.some((r: any) => r.day === day && r.kind === 'sync:chat' && r.usd >= 0.25));
});

test('activity: spans are stored and summarised', async () => {
  const t0 = Date.now() - 600_000;
  const spans = [
    { app: 'Editor', bundleId: 'com.example.editor', title: 'main.ts', startAt: t0, endAt: t0 + 120_000, idle: false },
    { app: 'Browser', bundleId: null, title: 'Docs', startAt: t0 + 120_000, endAt: t0 + 180_000, idle: false },
    { app: 'Editor', bundleId: null, title: null, startAt: t0 + 180_000, endAt: t0 + 240_000, idle: true },
  ];
  assert.equal((await ok('POST', '/sensors/activity', { spans })).count, 3);
  assert.equal((await api('POST', '/sensors/activity', { spans: [{ app: 'x' }] })).status, 400);
  const summary = await ok('GET', `/activity/summary?from=${t0}&to=${t0 + 240_000}`);
  assert.deepEqual(summary.byApp, [{ app: 'Editor', ms: 120_000 }, { app: 'Browser', ms: 60_000 }]);
  assert.equal(summary.focusMs, 180_000);
  assert.equal(summary.switches, 1);
  assert.equal(summary.byTask[0].title, 'Current thing');
  await ok('POST', '/sensors/event', { kind: 'wake', at: Date.now() });
});
