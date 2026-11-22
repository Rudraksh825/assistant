import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, beforeEach, test } from 'node:test';
import { startBrain, type Brain } from '../app.js';
import { Bus } from '../core/bus.js';
import { ConfigStore, DEFAULTS } from '../core/config.js';
import type { QuickRequest, RunRequest, RunResult } from '../core/context.js';
import type { Log } from '../core/log.js';
import { resolvePaths } from '../core/paths.js';
import { isWorkHours } from '../core/scheduler.js';
import type { Nudge } from '../core/types.js';
import { DAY, HOUR, MIN } from '../core/util.js';
import { backoffMs, loadAttempts } from '../jobs/attempts.js';
import { applySeeds, runBrief, runMeetingPrep, runSessionTitles, shiftTime } from '../jobs/briefs.js';
import { installJobs } from '../jobs/index.js';
import { inQuietHours, notify } from '../jobs/notify.js';
import { createNudger } from '../jobs/nudges.js';
import { runSync } from '../jobs/sync.js';
import { runTriage } from '../jobs/triage.js';

const home = mkdtempSync(join(tmpdir(), 'steward-jobs-'));
process.env.STEWARD_HOME = home;
process.env.STEWARD_LOG_LEVEL = 'silent';

let brain: Brain;
/** What the fake runtime was asked, and what it answers next. */
const fake = {
  available: true,
  quick: [] as QuickRequest[],
  runs: [] as RunRequest[],
  prepped: [] as string[],
  quickReply: (_req: QuickRequest): string => '{"items":[]}',
  runReply: (_req: RunRequest): Partial<RunResult> => ({}),
};

before(async () => {
  brain = await startBrain({ port: 0 });
  brain.ctx.agent = {
    ...brain.ctx.agent,
    available: () => fake.available,
    async quick(req) {
      fake.quick.push(req);
      return fake.quickReply(req);
    },
    async run(req) {
      fake.runs.push(req);
      return { runId: 'run', ok: true, text: '3 items', costUsd: 0.01, ...fake.runReply(req) };
    },
    async prepMeeting(id) {
      fake.prepped.push(id);
      return { runId: 'prep' };
    },
  };
  brain.ctx.scheduler.isWorkHours = () => true;
});
after(async () => {
  await brain.stop();
  rmSync(home, { recursive: true, force: true });
});
beforeEach(() => {
  Object.assign(fake, { available: true, quick: [], runs: [], prepped: [], quickReply: () => '{"items":[]}', runReply: () => ({}) });
  brain.ctx.db.exec('DELETE FROM nudges; DELETE FROM signals; DELETE FROM suggestions; DELETE FROM sessions; DELETE FROM tasks; DELETE FROM meetings; DELETE FROM approvals; DELETE FROM notes; DELETE FROM projects; DELETE FROM initiatives; DELETE FROM kv;');
  brain.ctx.config.update({ nudges: { quietHours: null, sessionWaitingAfterSec: 45, maxPer10Min: 3 } });
});

const nudges = (): Nudge[] => brain.ctx.repos.nudges.active().sort((a, b) => a.createdAt - b.createdAt || a.id.localeCompare(b.id));

test('notify: quiet hours and the ten-minute rate limit demote to priority 0', () => {
  const at = (h: number, m = 0) => new Date(2026, 0, 15, h, m).getTime();
  assert.equal(inQuietHours({ start: '22:00', end: '07:00' }, at(23)), true);
  assert.equal(inQuietHours({ start: '22:00', end: '07:00' }, at(6, 59)), true);
  assert.equal(inQuietHours({ start: '22:00', end: '07:00' }, at(12)), false);
  assert.equal(inQuietHours({ start: '12:00', end: '13:00' }, at(12, 30)), true);
  assert.equal(inQuietHours(null, at(3)), false);

  const { ctx } = brain;
  const sent = [1, 2, 3, 4, 5].map((n) => notify(ctx, { kind: 'task', title: `n${n}`, priority: 1, dedupeKey: `k${n}` }).priority);
  assert.deepEqual(sent, [1, 1, 1, 0, 0], 'the fourth and fifth are queued as passive');
  assert.equal(notify(ctx, { kind: 'meeting', title: 'Standup in 3 min', priority: 2, urgent: true }).priority, 2, 'urgent skips the limit');
  assert.equal(notify(ctx, { kind: 'task', title: 'again', priority: 1, dedupeKey: 'k1' }).title, 'n1', 'one nudge per dedupeKey');

  ctx.db.exec('DELETE FROM nudges');
  const now = new Date();
  const hhmm = (d: Date) => `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
  ctx.config.update({ nudges: { quietHours: { start: hhmm(new Date(now.getTime() - HOUR)), end: hhmm(new Date(now.getTime() + HOUR)) } } });
  assert.equal(notify(ctx, { kind: 'meeting', title: 'quiet', priority: 2, urgent: true }).priority, 0);
});

test('session nudges: one per waiting episode, several at once become one', () => {
  const { ctx } = brain;
  const { repos } = ctx;
  const nudger = createNudger(ctx);
  const now = Date.now();
  repos.sessions.upsert({ id: 's1', cwd: '/work/acme-api', title: 'Invoice export', state: 'waiting', stateSince: now - 10_000, lastAssistantText: 'Export added.' });
  nudger.sessions(now);
  assert.equal(nudges().length, 0, 'not waiting long enough yet');

  nudger.sessions(now + 40_000);
  nudger.sessions(now + 50_000);
  assert.deepEqual(nudges().map((n) => [n.title, n.priority, n.actions[0]!.kind, n.actions[0]!.sessionId]), [['Session finished: Invoice export', 1, 'focus_session', 's1']]);

  repos.sessions.upsert({ id: 's1', state: 'working', stateSince: now + 60_000 });
  assert.equal(nudges().length, 0, 'the nudge goes away once the session is picked up again');
  repos.sessions.upsert({ id: 's1', state: 'waiting', stateSince: now + 90_000 });
  nudger.sessions(now + 200_000);
  assert.equal(nudges().length, 1, 'a new episode nudges again');

  ctx.db.exec('DELETE FROM nudges');
  for (const id of ['s2', 's3', 's4']) repos.sessions.upsert({ id, cwd: `/work/${id}`, title: `Task ${id}`, state: id === 's3' ? 'blocked' : 'waiting', stateSince: now + 100_000 });
  nudger.sessions(now + 200_000);
  nudger.sessions(now + 210_000);
  assert.deepEqual(nudges().map((n) => [n.title, n.priority]), [['3 sessions waiting for you (1 blocked)', 2]]);
  nudger.stop();
});

test('session nudges wait while the session\'s own window is in front', () => {
  const { ctx } = brain;
  const { repos } = ctx;
  const nudger = createNudger(ctx);
  const now = Date.now();
  const focus = (title: string | null, at: number, idle = false) => ctx.bus.emit('sensor.event', { kind: 'focus', at, data: { app: 'Terminal', bundleId: 'com.apple.Terminal', title, idle } });
  repos.sessions.upsert({ id: 's1', cwd: '/work/acme-api', repo: 'acme-api', title: 'Invoice export', state: 'waiting', stateSince: now - 60_000, lastAssistantText: 'Export added.' });

  focus('acme-api — claude', now - 90_000);
  nudger.sessions(now);
  assert.equal(nudges().length, 0, 'the user is looking at it');

  focus('notes — vim', now);
  nudger.sessions(now + 30_000);
  assert.equal(nudges().length, 0, 'the wait starts when they leave the window');
  nudger.sessions(now + 50_000);
  assert.equal(nudges().length, 1);

  ctx.db.exec('DELETE FROM nudges');
  repos.sessions.upsert({ id: 's2', cwd: '/work/billing', repo: 'billing', title: 'Proration', state: 'waiting', stateSince: now - 60_000 });
  focus('billing — claude', now, true);
  nudger.sessions(now);
  assert.equal(nudges().length, 1, 'idle at the keyboard counts as away');
  nudger.stop();
});

test('sweep: meeting about to start, meeting just ended, due digest, stale doing, stale approval', () => {
  const { ctx } = brain;
  const { repos } = ctx;
  const now = Date.now();
  ctx.config.update({ nudges: { maxPer10Min: 50 } });
  const soon = repos.meetings.upsert({ source: 'calendar', externalId: 'ev1', title: 'Acme sync', startAt: now + 2 * MIN, endAt: now + 32 * MIN, attendees: ['Ana', 'Ben'], joinUrl: 'https://meet.example.com/abc' });
  repos.meetings.upsert({ source: 'calendar', externalId: 'ev2', title: 'Design review', startAt: now - 40 * MIN, endAt: now - 5 * MIN, attendees: ['Ana', 'Cy'] });
  repos.meetings.upsert({ source: 'calendar', externalId: 'ev3', title: 'Later', startAt: now + 3 * HOUR, endAt: now + 4 * HOUR, attendees: ['Ana', 'Ben'] });
  repos.tasks.create({ title: 'File the Acme report', dueAt: now - DAY });
  const doing = repos.tasks.create({ title: 'Migrate billing', status: 'doing' });
  ctx.db.prepare('UPDATE tasks SET updatedAt = ? WHERE id = ?').run(now - 3 * DAY, doing.id);
  const approval = repos.approvals.create({ kind: 'chat', summary: 'Reply to Ana', tool: 'send', input: {} });
  ctx.db.prepare('UPDATE approvals SET createdAt = ? WHERE id = ?').run(now - 45 * MIN, approval.id);

  const nudger = createNudger(ctx);
  nudger.sweep(now);
  nudger.sweep(now + 1000);
  const byKey = new Map(nudges().map((n) => [n.dedupeKey!.split(':').slice(0, 2).join(':'), n]));
  const start = byKey.get('meeting:start')!;
  assert.deepEqual([start.title, start.priority, start.actions.map((a) => a.kind)], ['Acme sync in 2 min', 2, ['open_url', 'open_view']]);
  assert.deepEqual([start.actions[1]!.view, start.actions[1]!.path], ['meetings', `/meetings/${soon.id}`]);
  assert.equal(byKey.get('meeting:end')!.title, 'Follow-ups from Design review?');
  assert.equal(byKey.get('tasks:due')!.title, '1 overdue');
  assert.deepEqual(byKey.get('task:stale')!.actions.map((a) => `${a.kind} ${a.path}`), [`api /tasks/${doing.id}/complete`, `api /tasks/${doing.id}`, `open_view /tasks/${doing.id}`], 'the last one opens the task in Steward');
  assert.ok(byKey.has('approval:stale'));
  assert.equal(nudges().filter((n) => n.dedupeKey !== `approval:${approval.id}`).length, 5, 'a second sweep adds nothing');
  nudger.stop();
});

test('core already reranks a linked task when its session starts waiting', async () => {
  const { repos } = brain.ctx;
  const task = repos.tasks.create({ title: 'ENG-77 invoice export' });
  repos.sessions.upsert({ id: 's1', cwd: '/work/acme-api', state: 'waiting', stateSince: Date.now() - 20 * MIN, taskId: task.id });
  await new Promise((r) => setImmediate(r));
  const after = repos.tasks.must(task.id);
  assert.ok(after.score > task.score);
  assert.ok(after.scoreReasons.some((r) => r.startsWith('session waiting')));
});

test('triage: free rules first, one model call for the rest, signals marked', async () => {
  const { ctx } = brain;
  const { repos } = ctx;
  const now = Date.now();
  const task = repos.tasks.create({ title: 'ENG-77 invoice export' });
  repos.signals.ingest([
    { source: 'browser', kind: 'visit', externalId: 'b1', title: 'Acme proposal', url: 'https://docs.google.com/document/d/abc/edit', occurredAt: now - 6000 },
    { source: 'ticket', kind: 'comment', externalId: 't1', title: 'ENG-77: new comment from Ana', url: 'https://tickets.example.com/ENG-77', occurredAt: now - 5000 },
    { source: 'ticket', kind: 'status', externalId: 't2', title: 'ENG-90 Tidy the importer: Todo → In Review', occurredAt: now - 4500 },
    { source: 'ticket', kind: 'assigned', externalId: 't3', title: 'ENG-91 Fix the importer: assigned to you by Ben', actor: 'Ben', occurredAt: now - 1000 },
    { source: 'git', kind: 'pr.merged', externalId: 'g1', title: 'PR #12 merged: ENG-77: invoice export', url: 'https://github.com/acme/api/pull/12', occurredAt: now - 4000 },
    { source: 'chat', kind: 'dm', externalId: 'c1', title: 'Ana', body: 'Can you send the Acme numbers by Friday?', actor: 'Ana', url: 'https://chat.example.com/c1', occurredAt: now - 3000 },
    { source: 'chat', kind: 'mention', externalId: 'c2', title: '#general', body: 'lunch?', actor: 'Ben', occurredAt: now - 2000 },
    { source: 'chat', kind: 'dm', externalId: 'old', title: 'Ana', body: 'ancient', occurredAt: now - 30 * DAY },
  ]);
  const triageOf = () => Object.fromEntries(repos.signals.list().map((s) => [s.externalId, s.triage]));

  fake.available = false;
  let result = await runTriage(ctx, 'manual', now);
  assert.deepEqual(result, { linked: 2, ignored: 3, suggested: 1, sentToModel: 0 });
  assert.deepEqual(triageOf(), { b1: 'ignored', t1: 'linked', t2: 'ignored', t3: 'new', g1: 'linked', c1: 'new', c2: 'new', old: 'ignored' }, 'a tracker moving on its own is dropped; an assignment waits for the model');
  assert.deepEqual(repos.tasks.must(task.id).links.map((l) => l.kind), ['ticket', 'pr']);
  const complete = repos.suggestions.list('pending');
  assert.deepEqual(complete.map((s) => [s.kind, s.payload.taskId, s.sourceUrl]), [['complete_task', task.id, 'https://github.com/acme/api/pull/12']]);
  assert.equal(fake.quick.length, 0, 'no model without a runtime');

  fake.available = true;
  fake.quickReply = () => JSON.stringify({ items: [
    { signals: [1], action: 'new_task', title: 'Send Ana the Acme numbers', rationale: 'Ana asked in a DM.', confidence: 0.8, priority: 2, dueAt: '2026-01-16', people: ['Ana'] },
    { signals: [1], action: 'new_task', title: 'Duplicate of the same signal', rationale: 'x', confidence: 0.5 },
    { signals: [9], action: 'new_task', title: 'Points at nothing', rationale: 'x', confidence: 0.5 },
    { signals: [2], action: 'update_task', title: 'No task given', rationale: 'x', confidence: 0.5 },
  ] });
  result = await runTriage(ctx, 'manual', now);
  assert.deepEqual(result, { linked: 0, ignored: 2, suggested: 1, sentToModel: 3 });
  assert.equal(fake.quick.length, 1);
  const sent = fake.quick[0]!.prompt;
  assert.ok(sent.includes('T1 [todo] ENG-77 invoice export') && sent.includes('complete_task: Complete: ENG-77 invoice export'), 'open tasks and recent suggestions are in the prompt');
  assert.ok(sent.includes('S1 chat/dm from Ana') && !sent.includes('Acme proposal') && !sent.includes('ancient'), 'only what the rules left over is sent');
  assert.ok(sent.includes('S3 ticket/assigned from Ben') && !sent.includes('ENG-90'), 'people asking come before trackers, and only addressed tracker signals are sent');
  assert.ok(fake.quick[0]!.schema);
  assert.deepEqual(triageOf(), { b1: 'ignored', t1: 'linked', t2: 'ignored', t3: 'ignored', g1: 'linked', c1: 'suggested', c2: 'ignored', old: 'ignored' });
  const created = repos.suggestions.list('pending').find((s) => s.kind === 'new_task')!;
  assert.deepEqual([created.title, created.source, created.sourceRef, created.sourceUrl, created.confidence, created.payload.priority], ['Send Ana the Acme numbers', 'chat', 'c1', 'https://chat.example.com/c1', 0.8, 2]);
  assert.equal(repos.suggestions.accept(created.id).task!.dueAt, Date.parse('2026-01-16'));

  assert.deepEqual(await runTriage(ctx, 'manual', now), { linked: 0, ignored: 0, suggested: 0, sentToModel: 0 }, 'nothing new: no call');
  assert.equal(fake.quick.length, 1);
});

test('triage: a bad reply leaves signals new and backs off scheduled runs', async () => {
  const { ctx } = brain;
  const now = Date.now();
  ctx.repos.signals.ingest([{ source: 'chat', kind: 'dm', externalId: 'c1', title: 'Ana', body: 'Can you review my doc?', occurredAt: now }]);
  fake.quickReply = () => 'not json';
  await assert.rejects(runTriage(ctx, 'schedule', now));
  assert.equal(ctx.repos.signals.list()[0]!.triage, 'new');
  await runTriage(ctx, 'schedule', now + 5 * MIN);
  assert.equal(fake.quick.length, 1, 'inside the backoff window nothing is sent');
  fake.quickReply = () => '{"items":[]}';
  await runTriage(ctx, 'schedule', now + 21 * MIN);
  assert.equal(fake.quick.length, 2);
  assert.equal(ctx.repos.signals.list()[0]!.triage, 'ignored');
});

test('sync: cursor, lean request, backoff, health', async () => {
  const { ctx } = brain;
  const { repos } = ctx;
  const t0 = Date.now();
  const state = () => loadAttempts(ctx, 'sync:chat');
  const health = () => repos.health.snapshot().connectors.chat;

  fake.available = false;
  assert.equal(await runSync(ctx, 'chat', 'schedule', t0), 'skipped');
  assert.equal(fake.runs.length, 0, 'no runtime: skip quietly');
  fake.available = true;

  assert.equal(await runSync(ctx, 'chat', 'schedule', t0), 'ok');
  const req = fake.runs[0]!;
  assert.deepEqual([req.kind, req.model, req.trigger, req.stewardTools, req.builtins], ['sync:chat', 'fast', 'schedule', ['signals_emit', 'person_upsert'], undefined]);
  assert.ok(Array.isArray(req.connectors) && req.connectors.includes('Slack'));
  assert.ok(req.prompt.includes('at most 40 items') && req.prompt.includes('500 characters') && req.prompt.includes('externalId') && req.prompt.includes('NO_TOOLS'));
  assert.ok(req.prompt.includes(`Window: ${new Date(t0 - DAY).toISOString().slice(0, 19)}Z to`), 'the first window reaches back a day');
  assert.deepEqual([state().cursor, state().okAt, state().failures], [t0 - 2 * MIN, t0, 0]);
  assert.equal(health(), 'ok');
  assert.equal(repos.health.snapshot().lastSyncAt.chat, t0);

  const t1 = t0 + 15 * MIN;
  await runSync(ctx, 'chat', 'schedule', t1);
  assert.ok(fake.runs[1]!.prompt.includes(`Window: ${new Date(t0 - 2 * MIN).toISOString().slice(0, 19)}Z to`), 'the next window starts at the cursor');

  fake.runReply = () => ({ ok: false, text: 'connector timed out' });
  const t2 = t1 + 15 * MIN;
  await assert.rejects(runSync(ctx, 'chat', 'schedule', t2), /timed out/);
  assert.deepEqual([state().failures, state().retryAt, state().cursor, health()], [1, t2 + 30 * MIN, t1 - 2 * MIN, 'error']);
  assert.equal(await runSync(ctx, 'chat', 'schedule', t2 + 15 * MIN), 'skipped', 'backing off');
  await assert.rejects(runSync(ctx, 'chat', 'schedule', t2 + 30 * MIN));
  assert.deepEqual([state().failures, state().retryAt], [2, t2 + 30 * MIN + 60 * MIN], 'the wait doubles');
  assert.equal(backoffMs(10, 15), 6 * HOUR, 'and is capped');
  assert.equal(fake.runs.length, 4);

  fake.runReply = () => ({});
  assert.equal(await runSync(ctx, 'chat', 'manual', t2 + 31 * MIN), 'ok', 'a manual run ignores the backoff');
  assert.deepEqual([state().failures, state().retryAt, health()], [0, 0, 'ok']);

  fake.runReply = () => ({ text: 'NO_TOOLS' });
  assert.equal(await runSync(ctx, 'tickets', 'schedule', t0), 'skipped');
  assert.equal(repos.health.snapshot().connectors.tickets, 'off');
  assert.equal(await runSync(ctx, 'docs', 'schedule', t0), 'skipped', 'docs is off by default');
  assert.equal(fake.runs.length, 6);

  fake.runReply = () => { throw Object.assign(new Error('No connected connector'), { code: 'connector_unavailable' }); };
  assert.equal(await runSync(ctx, 'meetings', 'schedule', t0), 'skipped', 'nothing connected is not a failure');
  assert.deepEqual([repos.health.snapshot().connectors.meetings, loadAttempts(ctx, 'sync:meetings').failures], ['off', 0]);
  await runBrief(ctx, 'morning', 'schedule', t0).catch(() => {});
  assert.deepEqual(fake.runs.slice(-2).map((r) => r.connectors === 'none'), [false, true], 'a brief falls back to local context');
});

test('sync: a quiet Dock badge replaces blind polling until it rises', async () => {
  const { ctx } = brain;
  const t0 = Date.now();
  await runSync(ctx, 'chat', 'schedule', t0);
  ctx.repos.health.synced('badges', t0 + 14 * MIN);
  const badge = (increasedAt: number) => ctx.repos.kv.set('badges', { apps: { 'com.tinyspeck.slackmacgap': { label: '', weight: 0, at: t0 } }, increasedAt: { chat: increasedAt } });
  badge(t0 - HOUR);
  assert.equal(await runSync(ctx, 'chat', 'schedule', t0 + 15 * MIN), 'skipped');
  badge(t0 + 10 * MIN);
  assert.equal(await runSync(ctx, 'chat', 'schedule', t0 + 15 * MIN), 'ok');
  badge(t0 - HOUR);
  ctx.repos.health.synced('badges', t0 + 3 * HOUR);
  assert.equal(await runSync(ctx, 'chat', 'schedule', t0 + 3 * HOUR), 'ok', 'after two hours it looks anyway');
});

test('briefs write a note and a nudge that opens it; prep and titles are batched and deduplicated', async () => {
  const { ctx } = brain;
  const { repos } = ctx;
  const now = Date.now();
  repos.tasks.create({ title: 'File the Acme report', priority: 3 });
  repos.sessions.upsert({ id: 's1', cwd: '/work/acme-api', repo: 'acme-api', branch: 'eng-77-add-export', state: 'waiting', stateSince: now - 5 * MIN, title: 'Add a CSV export', lastUserPrompt: 'Now add tests', lastAssistantText: 'Tests added and passing.' });
  fake.runReply = () => ({ text: '## Top tasks\n- File the Acme report' });
  await runBrief(ctx, 'morning', 'schedule', now);
  const req = fake.runs[0]!;
  assert.deepEqual([req.kind, req.model], ['brief:morning', 'main']);
  assert.ok(req.prompt.includes('File the Acme report') && req.prompt.includes('acme-api @ eng-77-add-export'));
  const note = repos.notes.list({ kind: 'brief' })[0]!;
  assert.equal(note.body, '## Top tasks\n- File the Acme report');
  const nudge = nudges().find((n) => n.kind === 'brief')!;
  assert.deepEqual([nudge.actions[0]!.kind, nudge.actions[0]!.view, nudge.actions[0]!.path], ['open_view', 'notes', `/notes/${note.id}`]);
  for (const kind of ['evening', 'weekly'] as const) await runBrief(ctx, kind, 'manual', now);
  assert.equal(repos.notes.list({ kind: 'brief' }).length, 3);

  const meeting = repos.meetings.upsert({ source: 'calendar', externalId: 'ev1', title: 'Acme sync', startAt: now + 10 * MIN, endAt: now + 40 * MIN, attendees: ['Ana', 'Ben'] });
  repos.meetings.upsert({ source: 'calendar', externalId: 'ev2', title: 'Focus block', startAt: now + 10 * MIN, endAt: now + 40 * MIN, attendees: ['Me'] });
  await runMeetingPrep(ctx, now);
  await runMeetingPrep(ctx, now + MIN);
  assert.deepEqual(fake.prepped, [meeting.id], 'once, and only with other people in it');

  repos.kv.set('cc:s:s1', { tail: null, autoTitle: 'Add a CSV export' });
  fake.quickReply = () => JSON.stringify({ titles: [{ n: 1, title: 'Testing the invoice CSV export' }] });
  await runSessionTitles(ctx, now);
  await runSessionTitles(ctx, now + HOUR);
  assert.equal(repos.sessions.must('s1').title, 'Testing the invoice CSV export');
  assert.equal(fake.quick.length, 1, 'the same prompt is not titled twice');

  assert.equal(shiftTime('19:00', -30), '18:30');
  assert.equal(shiftTime('23:50', 15), '23:59');
});

test('accepted seed suggestions create their initiative and project and file their tasks', async () => {
  const { ctx } = brain;
  const { repos } = ctx;
  const mk = (kind: 'insight' | 'new_task', title: string, payload: Record<string, unknown>) => repos.suggestions.create({ kind, title, payload, source: 'agent' });
  const task = mk('new_task', 'Draft the Acme pricing page', { title: 'Draft the Acme pricing page', project: 'Acme launch' });
  const project = mk('insight', 'Project: Acme launch', { entity: 'project', title: 'Acme launch', notes: 'Q1 launch', initiative: 'Grow Acme' });
  const initiative = mk('insight', 'Initiative: Grow Acme', { entity: 'initiative', title: 'Grow Acme' });
  for (const s of [task, initiative, project]) {
    repos.suggestions.accept(s.id);
    await new Promise((r) => setTimeout(r, 2));
    applySeeds(ctx);
  }
  applySeeds(ctx);
  const created = repos.projects.list().filter((p) => p.title === 'Acme launch');
  assert.equal(created.length, 1);
  assert.equal(created[0]!.initiativeId, repos.initiatives.list().find((i) => i.title === 'Grow Acme')!.id);
  assert.equal(repos.tasks.list({ q: 'pricing page' })[0]!.projectId, created[0]!.id, 'a task accepted before its project is filed once the project exists');
});

test('installJobs registers every job; only onboarding is manual', async () => {
  installJobs(brain.ctx);
  const jobs = new Map(brain.ctx.scheduler.list().map((j) => [j.name, j]));
  for (const name of ['nudges', 'triage', 'sync:chat', 'sync:calendar', 'sync:tickets', 'sync:meetings', 'sync:docs', 'brief:morning', 'brief:evening', 'brief:weekly', 'meeting-prep', 'memory-digest', 'session-titles', 'onboarding-scan', 'loose-ends']) {
    assert.ok(jobs.has(name), name);
  }
  assert.equal(jobs.get('onboarding-scan')!.enabled, false);
  assert.deepEqual([jobs.get('brief:morning')!.schedule, jobs.get('brief:evening')!.schedule, jobs.get('brief:weekly')!.schedule], ['09:00 mon,tue,wed,thu,fri', '18:30 mon,tue,wed,thu,fri', '17:30 fri']);
  assert.throws(() => brain.ctx.config.update({ user: { workHours: { start: '8am' } } }), /user\.workHours/, 'a bad time is refused, not stored');
  assert.throws(() => brain.ctx.config.update({ agent: { selfModify: 'never' } }), /selfModify/);
  brain.ctx.config.update({ user: { workHours: { start: '08:00', end: '17:00', days: [1, 2, 3, 4] } } });
  await new Promise((r) => setImmediate(r));
  assert.equal(brain.ctx.scheduler.list().find((j) => j.name === 'brief:weekly')!.schedule, '15:30 thu', 'schedules follow the settings');
});

test('a bad workHours value in config.json falls back to the defaults with a warning; the jobs still register', () => {
  const dir = mkdtempSync(join(tmpdir(), 'steward-config-'));
  try {
    const paths = resolvePaths(dir);
    writeFileSync(paths.configFile, JSON.stringify({ user: { name: 'Sam', workHours: { start: '9', end: 'evening', days: [1, 2, 9] } }, budget: { dailyCapUsd: 7 } }));
    const warnings: string[] = [];
    const log = { warn: (message: string) => warnings.push(message) } as unknown as Log;
    const config = new ConfigStore(paths, new Bus(), log);
    assert.deepEqual(config.get().user.workHours, DEFAULTS.user.workHours);
    assert.deepEqual([config.get().user.name, config.get().budget.dailyCapUsd], ['Sam', 7], 'the rest of the file is kept');
    assert.equal(warnings.length, 1);
    assert.match(warnings[0]!, /user\.workHours ignored, using the defaults: start and end must be HH:MM/);
    assert.equal(isWorkHours(config.get().user.workHours, new Date(2026, 0, 5, 10, 0).getTime()), true);
    assert.equal(JSON.parse(readFileSync(paths.configFile, 'utf8')).user.workHours.start, '9', 'the file itself is left for the user to fix');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
