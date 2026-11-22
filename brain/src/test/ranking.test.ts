import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { CodeSession, Meeting, Project, Task } from '../core/types.js';
import { DAY, HOUR, MIN } from '../core/util.js';
import { rankInputs, scoreTask, type RankInput } from '../domain/ranking.js';

// Local noon keeps "today" stable in every timezone.
const NOW = new Date(2026, 0, 15, 12, 0, 0).getTime();
const NONE: RankInput = { project: null, initiative: null, sessions: [], meetings: [] };

const task = (over: Partial<Task> = {}): Task => ({
  id: 't1', title: 'Task', notes: '', status: 'todo', priority: 0, projectId: null, parentId: null, dueAt: null,
  scheduledFor: null, snoozedUntil: null, estimateMin: null, pinned: false, manualRank: null, score: 0, scoreReasons: [],
  waitingOn: null, people: [], tags: [], links: [], source: 'manual', sourceRef: null, createdAt: NOW, updatedAt: NOW,
  completedAt: null, startedAt: null, ...over,
});
const session = (over: Partial<CodeSession> = {}): CodeSession => ({
  id: 's1', pid: 1, name: null, cwd: '/tmp/acme', repo: 'acme', branch: 'main', ticket: null, state: 'waiting',
  stateSince: NOW - 12 * MIN, title: null, lastUserPrompt: null, lastAssistantText: null, pr: null, taskId: 't1', notes: '',
  startedAt: NOW - HOUR, updatedAt: NOW, ...over,
});
const meeting = (over: Partial<Meeting> = {}): Meeting => ({
  id: 'm1', source: 'calendar', externalId: 'ext-1', title: 'Sync', startAt: NOW + 10 * MIN, endAt: NOW + 40 * MIN,
  attendees: [], joinUrl: null, location: null, summary: null, actionItems: [], recordingUrl: null, prepNote: null, prepStatus: null, prepError: null,
  startKnown: true, cancelledAt: null, updatedAt: NOW, ...over,
});
const project = (weight: number, over: Partial<Project> = {}): Project => ({
  id: 'p1', initiativeId: null, title: 'Acme launch', notes: '', status: 'active', color: null, weight, createdAt: NOW, updatedAt: NOW, ...over,
});
const score = (over: Partial<Task> = {}, x: RankInput = NONE) => scoreTask(task(over), x, NOW);

test('scores stay within 0..100 and are deterministic', () => {
  const loaded = score(
    { status: 'doing', priority: 3, pinned: true, dueAt: NOW - 3 * DAY, scheduledFor: NOW, createdAt: NOW - 70 * DAY },
    { project: project(3), initiative: { ...project(3), horizon: null }, sessions: [session({ state: 'blocked' })], meetings: [meeting()] },
  );
  assert.ok(loaded.score <= 100 && loaded.score > 90, `got ${loaded.score}`);
  assert.equal(score().score, score().score);
  assert.ok(score().score > 0);
});

test('status order: doing > todo > waiting > inbox', () => {
  const by = (status: Task['status']) => score({ status }).score;
  assert.ok(by('doing') > by('todo'));
  assert.ok(by('todo') > by('waiting'));
  assert.ok(by('waiting') > by('inbox'));
  assert.deepEqual(score({ status: 'done' }), { score: 0, reasons: [] });
  assert.deepEqual(score({ status: 'dropped' }), { score: 0, reasons: [] });
});

test('priority and pinned raise the score and explain themselves', () => {
  assert.ok(score({ priority: 3 }).score > score({ priority: 2 }).score);
  assert.ok(score({ priority: 2 }).score > score({ priority: 1 }).score);
  assert.ok(score({ priority: 1 }).score > score().score);
  assert.deepEqual(score({ priority: 3 }).reasons, ['urgent']);
  const pinned = score({ pinned: true });
  assert.ok(pinned.score > score({ priority: 3 }).score);
  assert.deepEqual(pinned.reasons, ['pinned']);
});

test('due proximity: overdue > due today > tomorrow > this week > none', () => {
  const overdue = score({ dueAt: NOW - 2 * DAY });
  const soon = score({ dueAt: NOW + 2 * HOUR });
  const today = score({ dueAt: NOW + 8 * HOUR });
  const tomorrow = score({ dueAt: NOW + DAY });
  const week = score({ dueAt: NOW + 6 * DAY });
  assert.deepEqual(overdue.reasons, ['overdue 2d']);
  assert.deepEqual(soon.reasons, ['due in 2h']);
  assert.deepEqual(today.reasons, ['due today']);
  assert.deepEqual(tomorrow.reasons, ['due tomorrow']);
  assert.deepEqual(week.reasons, ['due this week']);
  const order = [overdue, soon, today, tomorrow, week, score()].map((r) => r.score);
  assert.deepEqual(order, [...order].sort((a, b) => b - a));
  assert.equal(new Set(order).size, order.length);
  assert.deepEqual(score({ dueAt: NOW + 30 * DAY }), score());
});

test('scheduled for today counts; scheduled for later does not', () => {
  assert.deepEqual(score({ scheduledFor: NOW + HOUR }).reasons, ['scheduled today']);
  assert.deepEqual(score({ scheduledFor: NOW - 2 * DAY }).reasons, ['scheduled earlier']);
  assert.deepEqual(score({ scheduledFor: NOW + 2 * DAY }), score());
});

test('project and initiative weight boost only while active', () => {
  const heavy = score({}, { ...NONE, project: project(3) });
  const light = score({}, { ...NONE, project: project(1) });
  assert.ok(heavy.score > light.score && light.score > score().score);
  assert.deepEqual(heavy.reasons, ['project: Acme launch']);
  assert.deepEqual(light.reasons, []);
  assert.deepEqual(score({}, { ...NONE, project: project(3, { status: 'paused' }) }), score());
  const both = score({}, { ...NONE, project: project(3), initiative: { ...project(3), title: 'Grow', horizon: null } });
  assert.ok(both.score > heavy.score);
  assert.ok(both.reasons.includes('initiative: Grow'));
});

test('a linked session that needs the user boosts the task', () => {
  const waiting = score({}, { ...NONE, sessions: [session()] });
  assert.deepEqual(waiting.reasons, ['session waiting 12m']);
  assert.ok(waiting.score > score({ priority: 2 }).score);
  const blocked = score({}, { ...NONE, sessions: [session({ state: 'blocked', stateSince: NOW - 3 * MIN })] });
  assert.deepEqual(blocked.reasons, ['session blocked 3m']);
  assert.ok(score({}, { ...NONE, sessions: [session({ stateSince: NOW - 40 * MIN })] }).score > waiting.score);
  assert.deepEqual(score({}, { ...NONE, sessions: [session({ state: 'working' })] }), score());
});

test('a linked meeting starting soon boosts the task', () => {
  const soon = score({}, { ...NONE, meetings: [meeting()] });
  assert.deepEqual(soon.reasons, ['meeting in 10m']);
  const later = score({}, { ...NONE, meetings: [meeting({ startAt: NOW + 5 * HOUR, endAt: NOW + 6 * HOUR })] });
  assert.deepEqual(later.reasons, ['meeting in 5h']);
  assert.ok(soon.score > later.score && later.score > score().score);
  assert.deepEqual(score({}, { ...NONE, meetings: [meeting({ startAt: NOW - 2 * HOUR, endAt: NOW - HOUR })] }), score());
});

test('stale doing tasks lose their head start; old tasks get a small boost', () => {
  const fresh = score({ status: 'doing' });
  const stale = score({ status: 'doing', updatedAt: NOW - 4 * DAY });
  assert.ok(stale.score < fresh.score);
  assert.deepEqual(stale.reasons, ['in progress', 'stale 4d']);
  const old = score({ createdAt: NOW - 21 * DAY });
  assert.ok(old.score > score().score && old.score < score({ priority: 2 }).score);
  assert.deepEqual(old.reasons, ['open 3w']);
});

test('snoozed tasks score zero until the snooze ends', () => {
  assert.deepEqual(score({ priority: 3, pinned: true, snoozedUntil: NOW + HOUR }), { score: 0, reasons: ['snoozed'] });
  assert.ok(score({ priority: 3, snoozedUntil: NOW - HOUR }).score > 0);
});

test('rankInputs links sessions and meetings to tasks', () => {
  const p = project(2, { initiativeId: 'i1' });
  const initiative = { ...project(3), id: 'i1', title: 'Grow', horizon: null };
  const inputs = rankInputs({
    projects: [p], initiatives: [initiative],
    sessions: [session(), session({ id: 's2', taskId: null }), session({ id: 's3', taskId: 'other' })],
    meetings: [meeting(), meeting({ id: 'm2', externalId: 'ext-2' })],
  });
  const x = inputs(task({ projectId: 'p1', sourceRef: 'ext-2', links: [{ kind: 'session', title: 's', url: 'x', ref: 's2' }, { kind: 'meeting', title: 'm', url: 'y', ref: 'm1' }] }));
  assert.equal(x.project, p);
  assert.equal(x.initiative, initiative);
  assert.deepEqual(x.sessions.map((s) => s.id), ['s1', 's2']);
  assert.deepEqual(x.meetings.map((m) => m.id), ['m1', 'm2']);
  assert.deepEqual(inputs(task({ id: 'lonely' })), NONE);
});
