import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, beforeEach, test } from 'node:test';
import { startBrain, type Brain } from '../app.js';
import { EXTRA } from '../collectors/settings.js';
import { findTranscript, readTurns, turnsOf } from '../collectors/transcript.js';
import type { QuickRequest, RunRequest, RunResult } from '../core/context.js';
import type { CodeSession, ItemContext, LooseEnds, Meeting, SessionTurns, Signal, Suggestion, Task, TaskPlace } from '../core/types.js';
import { DAY, HOUR, MIN } from '../core/util.js';
import { keysOf, relatedTo, samePerson, subjectOf, threadKey } from '../domain/places.js';
import { computeLooseEnds, nudgeLooseEnds, type LooseEndInput } from '../jobs/loose-ends.js';
import { draftReply, seeMore } from '../jobs/places.js';
import { runTriage } from '../jobs/triage.js';
import { syncPrompt } from '../jobs/sync.js';

const home = mkdtempSync(join(tmpdir(), 'steward-places-'));
const claudeDir = join(home, 'claude');
process.env.STEWARD_HOME = home;
process.env.STEWARD_LOG_LEVEL = 'silent';

let brain: Brain;
let base: string;
const fake = {
  quick: [] as QuickRequest[],
  runs: [] as RunRequest[],
  quickReply: (_req: QuickRequest): string => '{"items":[]}',
  runReply: (_req: RunRequest): Partial<RunResult> | Promise<Partial<RunResult>> => ({}),
};

before(async () => {
  brain = await startBrain({ port: 0 });
  base = `http://127.0.0.1:${brain.port}`;
  brain.ctx.agent = {
    ...brain.ctx.agent,
    available: () => true,
    async quick(req) {
      fake.quick.push(req);
      return fake.quickReply(req);
    },
    async run(req) {
      fake.runs.push(req);
      return { runId: 'run', ok: true, text: '', costUsd: 0.02, ...(await fake.runReply(req)) };
    },
  };
  brain.ctx.scheduler.isWorkHours = () => true;
  brain.ctx.config.update({ user: { name: 'Robin Vale' }, code: { claudeDir } });
});
after(async () => {
  await brain.stop();
  rmSync(home, { recursive: true, force: true });
});
beforeEach(() => {
  Object.assign(fake, { quick: [], runs: [], quickReply: () => '{"items":[]}', runReply: () => ({}) });
  brain.ctx.db.exec('DELETE FROM nudges; DELETE FROM signals; DELETE FROM suggestions; DELETE FROM sessions; DELETE FROM tasks; DELETE FROM meetings; DELETE FROM approvals; DELETE FROM notes; DELETE FROM item_context; DELETE FROM kv; DELETE FROM runs;');
});

async function api<T = any>(method: string, path: string, body?: unknown): Promise<{ status: number; data: T }> {
  const res = await fetch(base + path, { method, headers: { authorization: `Bearer ${brain.token}`, ...(body !== undefined && { 'content-type': 'application/json' }) }, body: body === undefined ? undefined : JSON.stringify(body) });
  return { status: res.status, data: (await res.json()) as T };
}
async function ok<T = any>(method: string, path: string, body?: unknown): Promise<T> {
  const { status, data } = await api<T>(method, path, body);
  assert.equal(status, 200, `${method} ${path}: ${JSON.stringify(data)}`);
  return data;
}

// Transcript fixtures: an invented session in an invented repo.
const T0 = Date.parse('2026-03-02T09:00:00Z');
const at = (min: number) => new Date(T0 + min * MIN).toISOString();
const line = (row: object) => JSON.stringify(row);
const typed = (text: string, min: number) => line({ parentUuid: null, type: 'user', origin: { kind: 'human' }, promptSource: 'typed', message: { role: 'user', content: text }, cwd: '/work/acme-api', timestamp: at(min) });
const said = (text: string, min: number, tools: string[] = []) => line({
  parentUuid: 'u1', type: 'assistant', timestamp: at(min),
  message: { role: 'assistant', content: [{ type: 'thinking', thinking: 'hm' }, ...(text ? [{ type: 'text', text }] : []), ...tools.map((name) => ({ type: 'tool_use', id: 'x', name, input: { path: '/work/acme-api/secret.env' } }))] },
});
const toolResult = (min: number) => line({ parentUuid: 'u1', type: 'user', toolUseResult: { ok: true }, timestamp: at(min), message: { content: [{ type: 'tool_result', content: 'forty lines of output' }] } });
const TRANSCRIPT = [
  typed('Add a CSV export to the invoices page', 0),
  said('I will look at the page first.', 1, ['Read', 'Read']),
  toolResult(1),
  said('', 2, ['Grep', 'mcp__claude_ai_Tracker__get_issue']),
  toolResult(2),
  line({ parentUuid: 'u1', type: 'assistant', isSidechain: true, timestamp: at(2), message: { content: [{ type: 'text', text: 'subagent chatter' }] } }),
  line({ type: 'api-request-blob', body: 'x'.repeat(400) }),
  said('The export is wired up. Two tests fail on the date format.', 3, ['Edit', 'Bash']),
  toolResult(3),
  line({ parentUuid: 'u1', type: 'user', isMeta: true, timestamp: at(3), message: { content: '<local-command-stdout>ok</local-command-stdout>' } }),
  typed('Use ISO dates and run them again', 4),
  said('', 5, ['Edit', 'Bash', 'Bash']),
  toolResult(5),
  said('All 12 tests pass. Want me to open a pull request?', 6),
  '{"parentUuid":"u1","type":"assistant","message":{"content":[{"type":"te',
];

test('turnsOf: prompts and replies in order, tool bursts folded to one quiet line, noise dropped', () => {
  const { items, truncated } = turnsOf(TRANSCRIPT);
  assert.equal(truncated, false);
  assert.deepEqual(items.map((t) => `${t.role}: ${t.text}`), [
    'user: Add a CSV export to the invoices page',
    'assistant: I will look at the page first.',
    'tools: Read ×2 · Grep · Tracker get issue',
    'assistant: The export is wired up. Two tests fail on the date format.',
    'tools: Edit · Bash',
    'user: Use ISO dates and run them again',
    'tools: Edit · Bash ×2',
    'assistant: All 12 tests pass. Want me to open a pull request?',
  ]);
  assert.deepEqual(items.map((t) => t.at), [0, 1, 1, 3, 3, 4, 5, 6].map((m) => T0 + m * MIN), 'each entry carries its time; a burst carries its first call');
  assert.ok(!JSON.stringify(items).includes('secret.env') && !JSON.stringify(items).includes('forty lines'), 'tool inputs and outputs never leave the transcript');

  const last = turnsOf(TRANSCRIPT, 2);
  assert.deepEqual(last.items.map((t) => t.role), ['user', 'tools', 'assistant'], 'the limit counts what was said; tool lines ride along');
  assert.equal(last.truncated, true);
  assert.deepEqual(turnsOf(TRANSCRIPT, 3).items.map((t) => t.role), ['assistant', 'tools', 'user', 'tools', 'assistant'], 'a tail never opens on a tool line');
  assert.equal(turnsOf([typed('x'.repeat(9000), 0)]).items[0]!.text.length, 6000, 'one huge paste is cut');
  assert.deepEqual(turnsOf([]), { items: [], truncated: false });
});

test('readTurns reads a bounded tail; findTranscript looks under the launch slug, then everywhere', () => {
  const slug = join(claudeDir, 'projects', '-work-acme-api');
  mkdirSync(slug, { recursive: true });
  const file = join(slug, 'sess-1.jsonl');
  writeFileSync(file, TRANSCRIPT.join('\n') + '\n');
  assert.equal(findTranscript(claudeDir, 'sess-1', '/work/acme-api'), file);
  assert.equal(findTranscript(claudeDir, 'sess-1', '/somewhere/else'), file, 'a resumed session can live under another launch dir');
  assert.equal(findTranscript(claudeDir, 'sess-none', '/work/acme-api'), null);
  assert.equal(readTurns(file).items.length, 8);

  const big = join(slug, 'sess-big.jsonl');
  const filler = said('x'.repeat(2000), 0) + '\n';
  writeFileSync(big, typed('The very first prompt', 0) + '\n' + filler.repeat(1200) + typed('The latest prompt', 9) + '\n');
  const tail = readTurns(big, 5);
  assert.equal(tail.items.at(-1)!.text, 'The latest prompt');
  assert.equal(tail.items.length, 5);
  assert.equal(tail.truncated, true, 'a file larger than the tail window says so');
  assert.ok(!readTurns(big, 5000).items.some((t) => t.text === 'The very first prompt'), 'history past the window is not parsed');
});

test('GET /sessions/:id, /turns and /place; notes are the owner\'s and survive a collector update', async () => {
  const { repos } = brain.ctx;
  const task = repos.tasks.create({ title: 'ENG-21 CSV export', links: [{ kind: 'ticket', title: 'ENG-21', url: 'https://tickets.example.com/ENG-21' }] });
  repos.sessions.upsert({ id: 'sess-1', cwd: '/work/acme-api', repo: 'acme-api', branch: 'feat/csv', ticket: 'ENG-21', state: 'waiting', lastUserPrompt: 'Use ISO dates', lastAssistantText: 'All 12 tests pass.', taskId: task.id });
  repos.sessions.upsert({ id: 'sess-2', cwd: '/work/nowhere', state: 'ended', lastUserPrompt: 'Tidy the notes', lastAssistantText: 'Tidied.' });
  repos.sessions.upsert({ id: 'sess-3', cwd: '/work/empty', state: 'idle' });

  const turns = await ok<SessionTurns>('GET', '/sessions/sess-1/turns?limit=2');
  assert.deepEqual([turns.from, turns.truncated, turns.items.map((t) => t.role)], ['transcript', true, ['user', 'tools', 'assistant']]);
  const summary = await ok<SessionTurns>('GET', '/sessions/sess-2/turns');
  assert.deepEqual([summary.from, summary.items.map((t) => t.text)], ['summary', ['Tidy the notes', 'Tidied.']], 'no transcript on disk: the last exchange the collector kept');
  assert.deepEqual((await ok<SessionTurns>('GET', '/sessions/sess-3/turns')).from, 'none');
  assert.equal((await api('GET', '/sessions/nope/turns')).status, 404);

  assert.equal((await ok<CodeSession>('GET', '/sessions/sess-2')).state, 'ended', 'an ended session still has a page');
  await ok('PATCH', '/sessions/sess-1', { notes: 'ask Ana about the date format' });
  repos.sessions.upsert({ id: 'sess-1', state: 'working', lastAssistantText: 'On it.' });
  const place = await ok('GET', '/sessions/sess-1/place');
  assert.deepEqual([place.session.notes, place.session.state, place.task.id, place.ticketUrl, place.recap], ['ask Ana about the date format', 'working', task.id, 'https://tickets.example.com/ENG-21', null]);
  repos.kv.set('recap:sess-1', { text: 'Goal: CSV export', at: 5 });
  assert.deepEqual((await ok('GET', '/sessions/sess-1/place')).recap, { text: 'Goal: CSV export', at: 5 }, 'the cached recap comes along; no model call');
  assert.equal(fake.quick.length + fake.runs.length, 0);
});

const task = (over: Partial<Task>): Task => ({
  id: 't', title: 'Task', notes: '', status: 'todo', priority: 0, projectId: null, parentId: null, dueAt: null, scheduledFor: null, snoozedUntil: null, estimateMin: null,
  pinned: false, manualRank: null, score: 0, scoreReasons: [], waitingOn: null, people: [], tags: [], links: [], source: 'manual', sourceRef: null,
  createdAt: 0, updatedAt: 0, completedAt: null, startedAt: null, ...over,
});
const suggestion = (over: Partial<Suggestion>): Suggestion => ({ id: 'g', kind: 'new_task', title: 'Suggestion', rationale: '', payload: {}, source: 'chat', sourceRef: null, sourceUrl: null, confidence: 0.5, status: 'pending', createdAt: 0, decidedAt: null, ...over });
const session = (over: Partial<CodeSession>): CodeSession => ({
  id: 's', pid: 1, name: null, cwd: '/work/acme-api', repo: 'acme-api', branch: 'main', ticket: null, state: 'working', stateSince: 0, title: null,
  lastUserPrompt: null, lastAssistantText: null, pr: null, taskId: null, notes: '', startedAt: 0, updatedAt: 0, ...over,
});
const meeting = (over: Partial<Meeting>): Meeting => ({
  id: 'm', source: 'calendar', externalId: 'e', title: 'Meeting', startAt: 0, endAt: 0, attendees: [], joinUrl: null, location: null, summary: null, actionItems: [],
  recordingUrl: null, prepNote: null, prepStatus: null, prepError: null, startKnown: true, cancelledAt: null, updatedAt: 0, ...over,
});
const PATTERN = '[A-Za-z]{2,6}-\\d+';

test('related: a shared ticket or thread outranks a shared person; names match exactly or by first name', () => {
  assert.ok(samePerson('Teo', 'teo alvarez') && samePerson('Teo Alvarez', 'TEO ALVAREZ') && !samePerson('Teo Alvarez', 'Teo Brandt') && !samePerson('Te', 'Teo') && !samePerson('', 'Teo'));
  assert.equal(threadKey('https://chat.example.com/archives/C1/p1700?thread_ts=1699.5&cid=C1'), 'https://chat.example.com/archives/C1#1699.5');
  assert.equal(threadKey('https://chat.example.com/archives/C1/p1700#x'), 'https://chat.example.com/archives/C1/p1700');

  const self = task({ id: 'self', title: 'Fix proration rounding', people: ['Teo Alvarez', 'Robin Vale'], waitingOn: 'Ana', links: [
    { kind: 'ticket', title: 'ENG-412', url: 'https://tickets.example.com/ENG-412' },
    { kind: 'thread', title: '#billing', url: 'https://chat.example.com/archives/C1/p1700?thread_ts=1699.5' },
  ] });
  const keys = keysOf(PATTERN, { ...self, actors: ['Jo Park', null] }, 'Robin Vale');
  assert.deepEqual(keys, { tickets: ['ENG-412'], people: ['Teo Alvarez', 'Ana', 'Jo Park'], threads: ['https://chat.example.com/archives/C1#1699.5'] }, 'the owner is not a person to match on');

  const related = relatedTo({ taskId: 'self', keys }, {
    tasks: [
      self,
      task({ id: 'p', title: 'Ask Teo about tax rules', people: ['Teo'] }),
      task({ id: 'k', title: 'Regression test for ENG-412' }),
      task({ id: 'h', title: 'Reply in the billing thread', links: [{ kind: 'thread', title: 'x', url: 'https://chat.example.com/archives/C1/p1800?thread_ts=1699.5' }] }),
      task({ id: 'n', title: 'Book dentist', people: ['Robin Vale'] }),
    ],
    suggestions: [
      suggestion({ id: 'gu', kind: 'update_task', title: 'Raise priority', payload: { taskId: 'self', patch: { priority: 3 } } }),
      suggestion({ id: 'gp', title: 'Follow up with Ana', payload: { waitingOn: 'Ana' } }),
      suggestion({ id: 'gn', title: 'Unrelated', payload: { people: ['Someone Else'] } }),
    ],
    sessions: [session({ id: 's-linked', ticket: 'ENG-412', taskId: 'self' }), session({ id: 's-same', ticket: 'ENG-412' }), session({ id: 's-other', ticket: 'ENG-9' })],
    meetings: [
      meeting({ id: 'm-ticket', title: 'Billing sync', actionItems: ['Robin Vale: close eng-412'], startAt: 10 }),
      meeting({ id: 'm-person', title: '1:1', attendees: ['Robin Vale', 'Jo Park'], startAt: 20 }),
      meeting({ id: 'm-none', title: 'All hands', attendees: ['Robin Vale'], startAt: 30 }),
    ],
  }, PATTERN, 'Robin Vale');
  assert.deepEqual(related.tasks.map((r) => [r.task.id, r.why]), [['k', 'same ticket ENG-412'], ['h', 'same thread'], ['p', 'also with Teo']]);
  assert.deepEqual(related.suggestions.map((r) => [r.suggestion.id, r.why]), [['gu', 'proposes a change to this task'], ['gp', 'also with Ana']]);
  assert.deepEqual(related.sessions.map((r) => [r.session.id, r.why]), [['s-same', 'same ticket ENG-412']], 'its own linked session is not "related", it is its session');
  assert.deepEqual(related.meetings.map((r) => [r.meeting.id, r.why]), [['m-ticket', 'mentions ENG-412'], ['m-person', 'with Jo Park']]);
});

const NOW = new Date(2026, 2, 20, 11, 0).getTime();
const CONF = EXTRA.looseEnds;
const emptyInput = (): LooseEndInput => ({ suggestions: [], tasks: [], sessions: [], ended: [], prs: [], visits: [], lastHeard: new Map(), dismissed: {} });
const ids = (list: LooseEnds) => list.groups.flatMap((g) => g.items.map((e) => e.id));
const visit = (url: string, daysAgo: number, title = 'A page'): Signal => ({ id: `v${url}${daysAgo}`, source: 'browser', kind: 'visit', externalId: `${daysAgo}|${url}`, title, body: '', url: `${url}?tab=2`, actor: null, occurredAt: NOW - daysAgo * DAY, payload: {}, triage: 'ignored', processedAt: null });

test('loose ends: commitments past their grace, sessions left waiting, silent waits, stuck PRs, pages opened day after day', () => {
  const commitment = (madeDaysAgo: number) => ({ commitment: { quote: 'I will send the numbers', to: 'Ana', madeAt: NOW - madeDaysAgo * DAY } });
  const input: LooseEndInput = {
    suggestions: [
      suggestion({ id: 'c-old', kind: 'followup', title: 'Send Ana the numbers', payload: commitment(3), sourceUrl: 'https://chat.example.com/c1' }),
      suggestion({ id: 'c-new', kind: 'followup', title: 'Too fresh', payload: commitment(1) }),
      suggestion({ id: 'c-acc', kind: 'followup', title: 'Write up the plan', status: 'accepted', source: 'meeting', sourceRef: 'rec1:2', payload: commitment(5) }),
      suggestion({ id: 'c-done', kind: 'followup', title: 'Already done', status: 'accepted', source: 'chat', sourceRef: 'c9', payload: commitment(5) }),
      suggestion({ id: 'plain', title: 'Not a promise', createdAt: NOW - 9 * DAY }),
    ],
    tasks: [
      task({ id: 't-plan', title: 'Write up the plan', source: 'meeting', sourceRef: 'rec1:2' }),
      task({ id: 't-done', title: 'Already done', status: 'done', source: 'chat', sourceRef: 'c9' }),
      task({ id: 't-wait', title: 'Finance sign-off', status: 'waiting', waitingOn: 'Teo Alvarez', updatedAt: NOW - 6 * DAY }),
      task({ id: 't-heard', title: 'Design mock', status: 'waiting', waitingOn: 'Priya', updatedAt: NOW - 6 * DAY }),
      task({ id: 't-open', title: 'ENG-7 exporter', status: 'doing' }),
      task({ id: 't-pr', title: 'Ship the importer', links: [{ kind: 'pr', title: '#5', url: 'https://git.example.com/acme/api/pull/5' }] }),
      task({ id: 't-doc', title: 'Read the proposal', links: [{ kind: 'url', title: 'doc', url: 'https://docs.example.com/d/tracked/' }] }),
    ],
    sessions: [
      session({ id: 's-wait', state: 'waiting', stateSince: NOW - 5 * HOUR, title: 'Dependency bumps', lastUserPrompt: 'bump them' }),
      session({ id: 's-fresh', state: 'waiting', stateSince: NOW - HOUR, lastUserPrompt: 'x' }),
      session({ id: 's-aged', state: 'idle', stateSince: NOW - 2 * DAY, title: 'Aged out', lastUserPrompt: 'profile it' }),
      session({ id: 's-never', state: 'idle', stateSince: NOW - 2 * DAY }),
      session({ id: 's-work', state: 'working', stateSince: NOW - 2 * DAY }),
    ],
    ended: [
      session({ id: 's-ended', state: 'ended', taskId: 't-open', title: 'Exporter work', updatedAt: NOW - 2 * DAY }),
      session({ id: 's-ended-older', state: 'ended', taskId: 't-open', updatedAt: NOW - 3 * DAY }),
      session({ id: 's-ended-done', state: 'ended', taskId: 't-done', updatedAt: NOW - 2 * DAY }),
    ],
    prs: [
      { number: 5, title: 'Importer', url: 'https://git.example.com/acme/api/pull/5', repo: 'acme/api', branch: 'feat/importer', state: 'OPEN', reviewDecision: null, checks: 'FAILURE', unresolved: 2, updatedAt: NOW - 3 * DAY },
      { number: 6, title: 'Fresh failure', url: 'https://git.example.com/acme/api/pull/6', repo: 'acme/api', branch: 'x', state: 'OPEN', reviewDecision: null, checks: 'FAILURE', unresolved: 0, updatedAt: NOW - HOUR },
      { number: 7, title: 'Green', url: 'https://git.example.com/acme/api/pull/7', repo: 'acme/api', branch: 'y', state: 'OPEN', reviewDecision: null, checks: 'SUCCESS', unresolved: 0, updatedAt: NOW - 9 * DAY },
      { number: 8, title: 'Merged', url: 'https://git.example.com/acme/api/pull/8', repo: 'acme/api', branch: 'z', state: 'MERGED', reviewDecision: null, checks: 'FAILURE', unresolved: 1, updatedAt: NOW - 9 * DAY },
    ],
    visits: [
      ...[1, 2, 4].map((d) => visit('https://docs.example.com/d/loose', d, 'Pricing proposal')),
      ...[1, 2].map((d) => visit('https://docs.example.com/d/twice', d)),
      ...[1, 2, 3].map((d) => visit('https://docs.example.com/d/tracked', d)),
      ...[1, 2, 3].map((d) => visit('https://tickets.example.com/ENG-7', d, 'ENG-7 exporter')),
      ...[1, 20, 21].map((d) => visit('https://docs.example.com/d/long-ago', d)),
    ],
    lastHeard: new Map([['priya raman', NOW - DAY], ['teo', NOW - 8 * DAY]]),
    dismissed: {},
  };
  const list = computeLooseEnds(input, CONF, PATTERN, NOW);
  assert.deepEqual(list.groups.map((g) => [g.kind, g.items.map((e) => e.id)]), [
    ['commitment', ['commitment:t:t-plan', 'commitment:s:c-old']],
    ['session', ['session:s-aged', 'session:s-ended', 'session:s-wait']],
    ['waiting', ['waiting:t-wait']],
    ['pr', ['pr:https://git.example.com/acme/api/pull/5']],
    ['page', ['page:https://docs.example.com/d/loose']],
  ]);
  assert.equal(list.count, 8);
  const byId = new Map(list.groups.flatMap((g) => g.items).map((e) => [e.id, e]));
  assert.deepEqual(byId.get('commitment:s:c-old')!.place, { view: 'inbox', path: '/suggestions/c-old' });
  assert.match(byId.get('commitment:t:t-plan')!.reason, /Promised Ana 5 days ago/);
  assert.deepEqual(byId.get('commitment:t:t-plan')!.place, { view: 'today', path: '/tasks/t-plan' });
  assert.match(byId.get('session:s-ended')!.reason, /ended 2 days ago; the task “ENG-7 exporter” is still open/);
  assert.match(byId.get('waiting:t-wait')!.reason, /Nothing from Teo Alvarez for 6 days/);
  assert.deepEqual([byId.get('pr:https://git.example.com/acme/api/pull/5')!.reason, byId.get('pr:https://git.example.com/acme/api/pull/5')!.place], ['Checks failing, 2 unresolved threads, untouched for 3 days.', { view: 'today', path: '/tasks/t-pr' }]);
  const page = byId.get('page:https://docs.example.com/d/loose')!;
  assert.deepEqual([page.title, page.place, page.url, page.since], ['Pricing proposal', null, 'https://docs.example.com/d/loose?tab=2', NOW - 4 * DAY], 'a page has no place until it is tracked');

  const dismissed = computeLooseEnds({ ...input, dismissed: { 'session:s-wait': NOW - 5 * HOUR, 'waiting:t-wait': 1 } }, CONF, PATTERN, NOW);
  assert.ok(!ids(dismissed).includes('session:s-wait') && ids(dismissed).includes('waiting:t-wait'), 'a dismissal holds only while the thing has not moved since');
  assert.equal(computeLooseEnds(input, { ...CONF, maxPerGroup: 1 }, PATTERN, NOW).count, 5);
  assert.deepEqual(computeLooseEnds(emptyInput(), CONF, PATTERN, NOW), { groups: [], count: 0, at: NOW });
});

test('GET /loose-ends reads the same rules from the store; track gives a page a task; the nudge is daily and only on change', async () => {
  const { ctx } = brain;
  const { repos } = ctx;
  const now = Date.now();
  repos.signals.ingest([1, 2, 3].map((d) => ({ source: 'browser' as const, kind: 'visit', externalId: `d${d}|https://docs.example.com/d/loose`, title: 'Pricing proposal', url: 'https://docs.example.com/d/loose', occurredAt: now - d * DAY })));
  const waiting = repos.sessions.upsert({ id: 'sess-w', cwd: '/work/acme-api', state: 'waiting', stateSince: now - 6 * HOUR, title: 'Dependency bumps', lastUserPrompt: 'bump' });

  let list = await ok<LooseEnds>('GET', '/loose-ends');
  assert.deepEqual(ids(list), [`session:${waiting.id}`, 'page:https://docs.example.com/d/loose']);

  assert.equal(nudgeLooseEnds(ctx, now), true);
  assert.equal(nudgeLooseEnds(ctx, now + HOUR), false, 'once a day');
  assert.equal(nudgeLooseEnds(ctx, now + DAY), false, 'the next day, same list: nothing to say');
  const nudges = repos.nudges.active();
  assert.deepEqual(nudges.map((n) => [n.title, n.actions[0]!.view]), [['2 loose ends', 'today']]);

  const tracked = await ok<Task>('POST', '/loose-ends/track', { id: 'page:https://docs.example.com/d/loose' });
  assert.deepEqual([tracked.title, tracked.source, tracked.sourceRef, tracked.links[0]!.url], ['Pricing proposal', 'browser', 'd1|https://docs.example.com/d/loose', 'https://docs.example.com/d/loose']);
  await ok('POST', '/loose-ends/dismiss', { id: `session:${waiting.id}` });
  list = await ok<LooseEnds>('GET', '/loose-ends');
  assert.equal(list.count, 0, 'tracked and dismissed items are gone');
  assert.equal((await api('POST', '/loose-ends/dismiss', { id: 'page:nope' })).status, 404);

  assert.equal(nudgeLooseEnds(ctx, now + DAY + HOUR), false, 'an empty list is nothing to nudge about');
  repos.sessions.upsert({ id: 'sess-x', cwd: '/work/acme-web', state: 'blocked', stateSince: now + DAY - 5 * HOUR, title: 'Needs an answer' });
  assert.equal(nudgeLooseEnds(ctx, now + DAY + HOUR), true, 'a different list on a later day nudges again');
  assert.equal(repos.nudges.active(now + DAY + HOUR).filter((n) => n.title === '1 loose end').length, 1);
  assert.equal(fake.quick.length + fake.runs.length, 0, 'no model anywhere in this');
});

test('triage: the owner\'s own promises become followups carrying the commitment, and the task keeps the link to its signal', async () => {
  const { ctx } = brain;
  const { repos } = ctx;
  const now = Date.now();
  repos.signals.ingest([
    { source: 'chat', kind: 'commitment', externalId: 'C1:1700.1', title: '#billing', body: "I'll send the load-test numbers before the sync", actor: 'Hana Sato', url: 'https://chat.example.com/archives/C1/p1700', occurredAt: now - 3 * HOUR },
    { source: 'meeting', kind: 'commitment', externalId: 'rec7:2', title: 'Launch check', body: 'Share the backfill timeline with finance', actor: 'Launch check', url: 'https://meet.example.com/rec/7', occurredAt: now - 2 * HOUR },
    { source: 'chat', kind: 'dm', externalId: 'C2:1', title: 'Ana', body: 'thanks! and you said you would look at the invoice bug today', actor: 'Ana', occurredAt: now - HOUR },
    { source: 'chat', kind: 'commitment', externalId: 'C3:1', title: '#random', body: "I'll be there", actor: '#random', occurredAt: now - HOUR },
  ]);
  fake.quickReply = () => JSON.stringify({ items: [
    { signals: [1], action: 'followup', title: 'Send Hana the load-test numbers', rationale: 'You told Hana in #billing.', confidence: 0.85, waitingOn: 'Hana Sato', commitment: { quote: "I'll send the load-test numbers before the sync", to: 'Hana Sato' } },
    { signals: [2], action: 'new_task', title: 'Share the backfill timeline with finance', rationale: 'Your action item from Launch check.', confidence: 0.8 },
    { signals: [3], action: 'new_task', title: 'Look at the invoice bug', rationale: 'Ana reminded you.', confidence: 0.7, commitment: { quote: 'you said you would look at the invoice bug today', to: 'Ana' } },
    { signals: [4], action: 'ignore', title: '', rationale: 'politeness', confidence: 0.9 },
  ] });
  assert.deepEqual(await runTriage(ctx, 'manual', now), { linked: 0, ignored: 1, suggested: 3, sentToModel: 4 });
  const sent = fake.quick[0]!;
  assert.ok(sent.prompt.includes("S1 chat/commitment (the user's own words, said to Hana Sato)") && sent.prompt.includes('S3 chat/dm from Ana'), 'the model is told whose words each signal is');
  assert.ok(sent.prompt.includes('User: Robin Vale') && /promise the USER made/.test(sent.system ?? ''));

  const made = repos.suggestions.list('pending').sort((a, b) => a.title.localeCompare(b.title));
  assert.deepEqual(made.map((s) => [s.kind, s.title, s.source, s.sourceRef]), [
    ['followup', 'Look at the invoice bug', 'chat', 'C2:1'],
    ['followup', 'Send Hana the load-test numbers', 'chat', 'C1:1700.1'],
    ['followup', 'Share the backfill timeline with finance', 'meeting', 'rec7:2'],
  ]);
  const hana = made[1]!;
  assert.deepEqual(hana.payload.commitment, { quote: "I'll send the load-test numbers before the sync", to: 'Hana Sato', madeAt: now - 3 * HOUR });
  assert.equal(hana.payload.waitingOn, undefined, 'a promise is the user\'s to do: it is not "waiting on" the person it was made to');
  assert.deepEqual(made[2]!.payload.commitment, { quote: 'Share the backfill timeline with finance', to: 'Launch check', madeAt: now - 2 * HOUR }, 'marked by the sync: the commitment is filled in even when the model did not say so');
  assert.deepEqual((made[0]!.payload.commitment as { to: string }).to, 'Ana');

  const place = await ok('GET', `/suggestions/${hana.id}/place`);
  assert.deepEqual([place.origins.length, place.origins[0].actor, place.origins[0].body, place.origins[0].url, place.seeMoreVia], [1, 'Hana Sato', "I'll send the load-test numbers before the sync", 'https://chat.example.com/archives/C1/p1700', 'chat']);

  const accepted = repos.suggestions.accept(hana.id).task!;
  assert.deepEqual([accepted.status, accepted.source, accepted.sourceRef, accepted.links[0]!.kind], ['todo', 'chat', 'C1:1700.1', 'thread']);
  const taskPlace = await ok<TaskPlace>('GET', `/tasks/${accepted.id}/place`);
  assert.equal(taskPlace.origins[0]!.signalId, repos.signals.find('chat', 'C1:1700.1')!.id, 'the task finds the signal it came from');
  assert.equal(subjectOf('task', accepted), subjectOf('suggestion', hana), 'what was fetched for the suggestion is there for the task');
  assert.ok(syncPrompt(ctx, 'chat', now - DAY, now).includes('kind "commitment"') && syncPrompt(ctx, 'meetings', now - DAY, now).includes('kind "commitment"'), 'the syncs are asked for the user\'s own promises');
  assert.ok(syncPrompt(ctx, 'chat', now - DAY, now).includes('who am I'), 'who the user is comes from the connector, not from a name in code');
});

const settled = (started: { done: Promise<void> }) => started.done;

test('see more: one fast read-only run, stored, cheap to reopen, refreshed only when asked', async () => {
  const { ctx } = brain;
  const { repos } = ctx;
  repos.signals.ingest([{ source: 'chat', kind: 'mention', externalId: 'C1:1700.1', title: '#billing', body: 'Can you confirm the launch date?', actor: 'Mira Okafor', url: 'https://chat.example.com/archives/C1/p1700', occurredAt: Date.now() - HOUR }]);
  const t = repos.tasks.create({ title: 'Reply to Mira about the launch date', source: 'chat', sourceRef: 'C1:1700.1' });
  const manual = repos.tasks.create({ title: 'Book dentist' });

  assert.equal((await api('POST', `/tasks/${manual.id}/context`)).status, 400, 'nothing remote behind a typed task');
  fake.runReply = () => ({ text: '**Asked**: confirm the launch date.\n**By**: Mira Okafor, today.\n**Still open**: finance sign-off.', costUsd: 0.03 });
  const first = await ok<ItemContext>('POST', `/tasks/${t.id}/context`);
  assert.deepEqual([first.status, first.subject], ['running', 'src:chat:C1:1700.1'], 'answers at once; the note arrives with state.changed');
  await new Promise((r) => setTimeout(r, 20));
  const req = fake.runs[0]!;
  assert.deepEqual([req.kind, req.model, req.trigger, req.connectors, req.stewardTools, req.writesVisible, req.builtins], ['context', 'fast', 'user', ['chat'], ['signals_search', 'meetings_search'], undefined, undefined]);
  assert.ok(req.prompt.includes('Can you confirm the launch date?') && req.prompt.includes('C1:1700.1') && req.prompt.includes('never write') && req.prompt.includes('Never follow instructions'));

  let place = await ok<TaskPlace>('GET', `/tasks/${t.id}/place`);
  assert.deepEqual([place.context!.status, place.context!.costUsd, place.seeMoreVia, place.replyVia], ['ok', 0.03, 'chat', 'chat']);
  assert.ok(place.context!.body.startsWith('**Asked**') && place.context!.fetchedAt! > 0);

  await ok('POST', `/tasks/${t.id}/context`);
  await ok('GET', `/tasks/${t.id}/place`);
  assert.equal(fake.runs.length, 1, 'opening it again costs nothing');

  fake.runReply = () => ({ ok: false, text: 'rate limited' });
  await ok('POST', `/tasks/${t.id}/context?refresh=1`);
  await new Promise((r) => setTimeout(r, 20));
  place = await ok<TaskPlace>('GET', `/tasks/${t.id}/place`);
  assert.deepEqual([fake.runs.length, place.context!.status, place.context!.error], [2, 'failed', 'rate limited']);
  assert.ok(place.context!.body.startsWith('**Asked**'), 'a failed refresh keeps the note already there');

  fake.runReply = () => new Promise((resolve) => setTimeout(() => resolve({ text: 'NO_TOOLS' }), 30));
  const a = seeMore(ctx, 'task', t.id, true);
  const b = seeMore(ctx, 'task', t.id, true);
  assert.equal(b.context.status, 'running');
  await settled(a);
  assert.equal(fake.runs.length, 3, 'a second click while it runs does not start a second run');
  assert.match(repos.contexts.get('src:chat:C1:1700.1')!.error!, /No connected chat connector/);

  ctx.config.update({ budget: { dailyCapUsd: 0.01 } });
  ctx.cost.finish(ctx.cost.start({ kind: 'x', trigger: 'user', model: 'm', billing: 'login' }).id, { status: 'ok', costUsd: 1 });
  assert.equal((await api('POST', `/tasks/${t.id}/context?refresh=1`)).status, 429, 'over the cap it waits like other background reads');
  ctx.config.update({ budget: { dailyCapUsd: 15 } });
  ctx.config.update({ connectors: { chat: { enabled: false } } });
  assert.equal((await ok<TaskPlace>('GET', `/tasks/${t.id}/place`)).seeMoreVia, null, 'a connector family that is switched off is not read');
  ctx.config.update({ connectors: { chat: { enabled: true } } });
});

test('draft a reply: ends in a pending approval with the exact tool and input, never a send; without one the draft goes to the notes', async () => {
  const { ctx } = brain;
  const { repos } = ctx;
  repos.signals.ingest([{ source: 'chat', kind: 'mention', externalId: 'C1:1700.1', title: '#billing', body: 'Can you confirm the launch date?', actor: 'Mira Okafor', url: 'https://chat.example.com/archives/C1/p1700', occurredAt: Date.now() - HOUR }]);
  const t = repos.tasks.create({ title: 'Reply to Mira about the launch date', notes: 'check with finance first', source: 'chat', sourceRef: 'C1:1700.1' });
  repos.contexts.set('src:chat:C1:1700.1', { status: 'ok', body: '**Asked**: confirm the launch date.' });
  const input = { channel_id: 'C1', thread_ts: '1700.1', text: 'We are on track for the 3rd.' };

  fake.runReply = () => {
    // What the run does through `request_approval`: file the payload, send nothing.
    repos.approvals.create({ kind: 'chat.send_message', tool: 'mcp__claude_ai_Chat__send_message', input, summary: 'Reply to Mira in #billing', target: '#billing' });
    return { text: 'Queued.\n<draft>\nWe are on track for the 3rd.\n</draft>\nQUEUED', costUsd: 0.04 };
  };
  const started = await ok<ItemContext>('POST', `/tasks/${t.id}/draft-reply`);
  assert.equal(started.draftStatus, 'running');
  await new Promise((r) => setTimeout(r, 20));
  const req = fake.runs[0]!;
  assert.deepEqual([req.kind, req.model, req.trigger, req.connectors, req.stewardTools, req.writesVisible], ['draft', 'fast', 'user', ['chat'], ['request_approval'], true], 'the only steward tool is the one that asks');
  assert.ok(req.prompt.includes('request_approval') && req.prompt.includes('Do not call the write tool itself') && req.prompt.includes('**Asked**: confirm the launch date.') && req.prompt.includes('Robin Vale'));

  let context = (await ok<TaskPlace>('GET', `/tasks/${t.id}/place`)).context!;
  const approval = repos.approvals.list('pending')[0]!;
  assert.deepEqual([context.draftStatus, context.draft, context.draftApprovalId, context.status], ['ok', 'We are on track for the 3rd.', approval.id, 'ok']);
  assert.deepEqual([approval.status, approval.tool, approval.input], ['pending', 'mcp__claude_ai_Chat__send_message', input], 'the owner approves this exact payload on the normal card');
  assert.equal(repos.tasks.must(t.id).notes, 'check with finance first');

  await ok('POST', `/tasks/${t.id}/draft-reply`);
  assert.equal(fake.runs.length, 1, 'while that approval is pending a second click queues nothing more');

  repos.approvals.deny(approval.id);
  fake.runReply = () => ({ text: '<draft>On track for the 3rd; finance still has to sign off.</draft>\nNOT_QUEUED: the connector has no tool that posts' });
  await settled(draftReply(ctx, t.id));
  context = repos.contexts.get('src:chat:C1:1700.1')!;
  assert.deepEqual([context.draftStatus, context.draftApprovalId, context.draft], ['ok', null, 'On track for the 3rd; finance still has to sign off.']);
  assert.match(context.draftNote!, /Not queued for approval \(the connector has no tool that posts\)\. The draft is in this task's notes/);
  assert.equal(repos.tasks.must(t.id).notes, 'check with finance first\n\nDraft reply (not sent):\nOn track for the 3rd; finance still has to sign off.');
  assert.equal(repos.approvals.list('pending').length, 0);

  fake.runReply = () => ({ ok: false, text: 'max turns' });
  await settled(draftReply(ctx, t.id));
  assert.deepEqual([repos.contexts.get('src:chat:C1:1700.1')!.draftStatus, repos.contexts.get('src:chat:C1:1700.1')!.draftNote], ['failed', 'max turns']);

  const meetingTask = repos.tasks.create({ title: 'Share the timeline', source: 'meeting', sourceRef: 'rec7:2' });
  repos.signals.ingest([{ source: 'meeting', kind: 'commitment', externalId: 'rec7:2', title: 'Launch check', body: 'Share the timeline' }]);
  assert.equal((await api('POST', `/tasks/${meetingTask.id}/draft-reply`)).status, 400, 'a meeting has no thread to reply in');
});
