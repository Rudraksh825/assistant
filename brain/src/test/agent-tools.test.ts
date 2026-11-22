import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, test } from 'node:test';
import { matchServers } from '../agent/engine.js';
import { READ_BUILTINS } from '../agent/index.js';
import { createExecutor } from '../agent/executor.js';
import type { Policy } from '../agent/guard.js';
import { createSelf } from '../agent/self.js';
import { stewardTools, toMs, type ToolEnv } from '../agent/tools.js';
import { Bus } from '../core/bus.js';
import { ConfigStore } from '../core/config.js';
import type { AppContext } from '../core/context.js';
import { createCost } from '../core/cost.js';
import { openDb } from '../core/db.js';
import { createLog } from '../core/log.js';
import { resolvePaths } from '../core/paths.js';
import { Scheduler } from '../core/scheduler.js';
import { createRepos } from '../domain/index.js';

const home = mkdtempSync(join(tmpdir(), 'steward-tools-'));
const paths = resolvePaths(home);
const log = createLog(paths.logsDir, { level: 'silent' });
const bus = new Bus();
const config = new ConfigStore(paths, bus, log);
const db = openDb(paths.dbFile);
const repos = createRepos({ db, bus }, paths);
const cost = createCost(db, bus, config, (n) => repos.nudges.create(n));
const ctx = { config, paths, db, bus, log, cost, repos, scheduler: new Scheduler({ db, bus, log, config, cost }) } as AppContext;

const policy: Policy = { repoRoot: '/work/steward', dataDir: home, home: '/home/u', cwd: '/work/steward', writableRoots: [] };
const scheduled: unknown[] = [];
const self = createSelf({ repoRoot: home, tmpDir: home });
const executor = createExecutor({ ctx, engine: { policy: () => policy } as never, self, fastModel: () => 'fast', serverOf: async () => undefined, during: (_text, fn) => fn() });
const env: ToolEnv = {
  ctx, policy: () => policy,
  self,
  checkApproval: (approval) => executor.check(approval),
  recap: async (id) => `recap of ${id}`,
  schedule: (job) => { scheduled.push(job); return 'scheduled'; },
  bridge: { tools: async (query) => ({ query }), read: async (tool) => `read ${tool}` },
  knownConnectorTool: (name) => name.startsWith('mcp__claude_ai_Chat__'),
};
const tools = new Map(stewardTools(env).map((t) => [t.name, t]));
async function call(name: string, args: Record<string, unknown> = {}, from: Map<string, { handler: (a: any, extra: unknown) => Promise<any> }> = tools): Promise<{ text: string; isError: boolean; json: any }> {
  const out = await from.get(name)!.handler(args, {});
  const text = out.content[0].text as string;
  let json: unknown;
  try { json = JSON.parse(text); } catch { json = undefined; }
  return { text, isError: !!out.isError, json };
}

after(() => {
  db.close();
  rmSync(home, { recursive: true, force: true });
});

test('every SPEC tool exists, with short descriptions', () => {
  const expected = [
    'tasks_search', 'task_create', 'task_update', 'task_complete', 'task_link', 'projects_list', 'project_upsert', 'initiative_upsert', 'suggestion_create',
    'suggestions_create', 'signals_search', 'signals_emit', 'sessions_list', 'session_recap', 'meetings_search', 'meeting_upsert', 'meetings_upsert', 'notes_search', 'note_write',
    'people_search', 'person_update', 'person_upsert', 'memory_read', 'memory_write', 'memory_list', 'nudge', 'ask_user', 'request_approval', 'ui_command',
    'activity_summary', 'schedule_job', 'cost_status', 'loose_ends', 'app_rebuild', 'app_snapshot', 'app_restore', 'connector_tools', 'connector_read',
  ];
  assert.deepEqual([...tools.keys()].sort(), [...expected].sort());
  for (const t of tools.values()) assert.ok(t.description.length <= 220, `${t.name} description is ${t.description.length} chars`);
});

test('tasks: create with a local date, update, link, complete, search', async () => {
  const project = (await call('project_upsert', { title: 'Acme launch' })).json;
  assert.equal((await call('project_upsert', { title: 'acme LAUNCH', status: 'paused' })).json.id, project.id, 'matched by title');
  const created = (await call('task_create', { title: 'Water the plants', priority: 2, due: '2026-01-31', projectId: project.id })).json;
  assert.equal(created.due, '2026-01-31 23:59');
  const stored = repos.tasks.must(created.id);
  assert.deepEqual([stored.status, stored.source, stored.priority, stored.projectId], ['todo', 'agent', 2, project.id]);
  assert.equal(toMs('2026-01-31'), new Date(2026, 0, 31, 23, 59).getTime());
  assert.equal(toMs('2026-01-31', 'start'), new Date(2026, 0, 31).getTime());
  assert.equal(toMs('2026-01-31T15:00', 'start'), new Date(2026, 0, 31, 15).getTime());

  await call('task_update', { id: created.id, due: null, waitingOn: 'Sam', status: 'waiting' });
  assert.deepEqual([repos.tasks.must(created.id).dueAt, repos.tasks.must(created.id).waitingOn], [null, 'Sam']);
  await call('task_link', { id: created.id, kind: 'ticket', title: 'ENG-123', url: 'https://example.com/ENG-123' });
  assert.equal(repos.tasks.must(created.id).links[0]!.title, 'ENG-123');
  assert.equal((await call('tasks_search', { q: 'plants' })).json.length, 1);
  assert.equal((await call('task_complete', { id: created.id })).json.status, 'done');
  assert.equal((await call('tasks_search', { q: 'plants' })).json.length, 0, 'done tasks are not in the default search');
  assert.equal((await call('projects_list')).json.projects[0].title, 'Acme launch');

  const bad = await call('task_create', { title: 'x', due: 'next friday-ish' });
  assert.ok(bad.isError && /not a date/.test(bad.text));
  assert.ok((await call('task_update', { id: 'nope', title: 'x' })).isError);
});

test('signals_emit is idempotent on source and externalId', async () => {
  const items = [
    { source: 'chat', kind: 'mention', externalId: 'm-1', title: 'Sam asked about the launch', occurredAt: '2026-01-30T10:00' },
    { source: 'chat', kind: 'mention', externalId: 'm-2', title: 'Dana shared the deck' },
  ];
  assert.deepEqual((await call('signals_emit', { items })).json, { stored: 2, skipped: 0 });
  assert.deepEqual((await call('signals_emit', { items: [...items, { source: 'ticket', kind: 'assigned', externalId: 'm-1', title: 'ENG-123 assigned' }] })).json, { stored: 1, skipped: 2 });
  assert.equal((await call('signals_search', { q: 'launch' })).json[0].at, '2026-01-30 10:00');
});

test('suggestions, meetings, people, notes and memory round-trip', async () => {
  const batch = await call('suggestions_create', { items: [{ kind: 'new_task', title: 'Reply to Sam', rationale: 'asked twice', payload: { priority: 2 }, source: 'chat', confidence: 0.8 }, { kind: 'insight', title: 'Launch slipped a week' }] });
  assert.equal(batch.json.created.length, 2);
  assert.equal((await call('suggestion_create', { kind: 'question', title: 'Which Sam?' })).json.created.length, 1);
  assert.equal(repos.suggestions.count('pending'), 3);

  const meeting = (await call('meeting_upsert', { source: 'calendar', externalId: 'ev-1', title: 'Launch sync', startAt: '2026-01-30T15:00', endAt: '2026-01-30T15:30', attendees: ['Sam'] })).json;
  assert.equal((await call('meeting_upsert', { source: 'calendar', externalId: 'ev-1', summary: 'Agreed to ship' })).json.id, meeting.id);
  assert.equal((await call('meeting_upsert', { id: meeting.id, prepNote: 'Bring the deck' })).json.prepNote, 'yes');
  assert.ok((await call('meeting_upsert', { title: 'no key' })).isError);
  const upserted = (await call('meetings_upsert', { items: [
    { source: 'calendar', externalId: 'ev-1', location: 'Room 4' },
    { source: 'calendar', externalId: 'ev-2', title: 'Retro', startAt: '2026-01-30T16:00:00+00:00', endAt: '1769792400000' },
    { title: 'no key' },
  ] }));
  assert.deepEqual([upserted.json.saved, upserted.json.failed.length], [2, 1]);
  const retro = repos.meetings.list().find((m) => m.externalId === 'ev-2')!;
  assert.deepEqual([retro.startAt, retro.endAt], [Date.UTC(2026, 0, 30, 16), 1769792400000], 'an offset and an epoch stamp both land on the right instant');
  assert.equal((await call('meetings_search', { q: 'sam', from: '2026-01-30', to: '2026-01-31' })).json.length, 1);

  const sam = (await call('person_upsert', { name: 'Sam', handles: { email: 'sam@example.com' } })).json;
  assert.equal((await call('person_upsert', { name: 'sam', handles: { chat: '@sam' }, notes: 'Runs the launch' })).json.id, sam.id);
  assert.deepEqual(repos.people.must(sam.id).handles, { email: 'sam@example.com', chat: '@sam' });
  await call('person_update', { id: sam.id, lastContactAt: '2026-01-30' });
  assert.equal((await call('people_search', { q: 'sam' })).json[0].notes, 'Runs the launch');

  const note = (await call('note_write', { title: 'Launch', body: 'line one', kind: 'meeting', meetingId: meeting.id })).json;
  await call('note_write', { id: note.id, body: 'line two', append: true });
  assert.equal(repos.notes.must(note.id).body, 'line one\nline two');
  assert.equal((await call('notes_search', { q: 'line two' })).json.length, 1);

  assert.equal((await call('memory_list')).text, '(empty)');
  await call('memory_write', { path: 'people/sam.md', content: '# Sam' });
  await call('memory_write', { path: 'people/sam.md', content: 'Prefers short updates', append: true });
  assert.equal((await call('memory_read', { path: 'people/sam.md' })).text, '# Sam\nPrefers short updates');
  assert.match((await call('memory_list')).text, /^people\/sam\.md/);
  assert.ok((await call('memory_write', { path: '../escape.md', content: 'x' })).isError);
});

test('calendar sync: events that left the window or were declined are cancelled, and come back if listed again', async () => {
  const day = '2026-03-02';
  const hour: Record<string, number> = { a: 10, b: 11, c: 12 };
  const items = (ids: string[]) => ids.map((id) => ({ source: 'calendar', externalId: id, title: `Event ${id}`, startAt: `${day}T${hour[id]}:00`, endAt: `${day}T${hour[id]}:30`, attendees: ['Sam', 'Ana'] }));
  const window = { from: `${day}T00:00`, to: '2026-03-03T23:59' };
  const listed = () => repos.meetings.list(toMs(window.from, 'start')!, toMs(window.to)!).map((m) => m.externalId);
  assert.deepEqual((await call('meetings_upsert', { items: items(['a', 'b', 'c']), window })).json, { saved: 3 });
  assert.deepEqual(listed(), ['a', 'b', 'c']);
  // The next sync no longer sees b (deleted or declined); without a window nothing is inferred.
  assert.deepEqual((await call('meetings_upsert', { items: items(['a', 'c']) })).json, { saved: 2 });
  assert.deepEqual(listed(), ['a', 'b', 'c']);
  assert.deepEqual((await call('meetings_upsert', { items: items(['a', 'c']), window })).json, { saved: 2, cancelled: 1 });
  assert.deepEqual(listed(), ['a', 'c']);
  const b = repos.meetings.must((db.prepare("SELECT id FROM meetings WHERE externalId = 'b'").get() as { id: string }).id);
  assert.ok(b.cancelledAt, 'kept, marked cancelled');
  const at = toMs(`${day}T10:55`, 'start')!;
  assert.equal(repos.meetings.next(at)?.externalId, 'c', 'a cancelled event is never "next"');
  assert.equal(repos.meetings.current(toMs(`${day}T11:10`, 'start')!), null);
  // A recording in the same window is not a calendar event and is left alone; an event outside the window too.
  await call('meeting_upsert', { source: 'meeting', externalId: 'rec-1', title: 'Recorded', startAt: `${day}T09:00:00Z`, endAt: `${day}T09:30:00Z` });
  await call('meeting_upsert', { source: 'calendar', externalId: 'far', title: 'Next week', startAt: '2026-03-09T10:00', endAt: '2026-03-09T10:30' });
  assert.deepEqual((await call('meetings_upsert', { items: items(['a', 'c']), window })).json, { saved: 2 });
  assert.ok(repos.meetings.list(0).some((m) => m.externalId === 'rec-1') && repos.meetings.list(0).some((m) => m.externalId === 'far'));
  // Listed again, it is live again. A sync with a failed item cancels nothing.
  assert.deepEqual((await call('meetings_upsert', { items: items(['a', 'b', 'c']), window })).json, { saved: 3 });
  assert.deepEqual(listed().filter((id) => id !== 'rec-1'), ['a', 'b', 'c']);
  const partial = (await call('meetings_upsert', { items: [...items(['a']), { title: 'no key' }], window })).json;
  assert.deepEqual([partial.saved, partial.failed.length, partial.cancelled], [1, 1, undefined]);
});

test('recordings: a date without a time is stored as "time unknown", never as midnight', async () => {
  const out = (await call('meetings_upsert', { items: [
    { source: 'meeting', externalId: 'rec-date', title: 'Roadmap review', startAt: '2026-02-10' },
    { source: 'meeting', externalId: 'rec-time', title: 'Standup', startAt: '2026-02-10T09:30:00+01:00', endAt: '2026-02-10T09:45:00+01:00' },
  ] })).json;
  assert.deepEqual([out.saved, out.storedWithoutTime], [2, ['rec-date']]);
  assert.match(out.hint, /real start time/);
  const row = (id: string) => repos.meetings.list(0).find((m) => m.externalId === id)!;
  assert.deepEqual([row('rec-date').startKnown, row('rec-time').startKnown], [false, true]);
  assert.equal(row('rec-time').startAt, Date.parse('2026-02-10T09:30:00+01:00'));
  const shown = (await call('meetings_search', { q: 'roadmap', from: '2026-02-09', to: '2026-02-11' })).json[0];
  assert.deepEqual([shown.start, shown.end], ['2026-02-10 (time unknown)', undefined]);
  // The real time arriving later replaces the placeholder.
  await call('meeting_upsert', { source: 'meeting', externalId: 'rec-date', startAt: '2026-02-10T14:00:00Z', endAt: '2026-02-10T15:00:00Z' });
  assert.deepEqual([row('rec-date').startKnown, row('rec-date').startAt], [true, Date.parse('2026-02-10T14:00:00Z')]);
});

test('request_approval queues external writes, waves through local work and refuses the forbidden', async () => {
  const queued = await call('request_approval', { tool: 'Bash', input: { command: 'git push' }, summary: 'Push main' });
  assert.match(queued.text, /^Queued as approval /);
  const approval = repos.approvals.list('pending').find((a) => a.tool === 'Bash');
  assert.deepEqual([approval!.kind, approval!.tool, approval!.input, approval!.note, approval!.threadId], ['bash', 'Bash', { command: 'git push' }, 'git push publishes commits.', null]);
  assert.equal('preview' in approval!, false, 'nothing the agent wrote can stand in for the input');
  assert.ok(repos.nudges.active().some((n) => n.kind === 'approval'));

  const post = await call('request_approval', { tool: 'mcp__claude_ai_Chat__send_message', input: { channel: 'general', text: 'hi' }, summary: 'Post hi in #general', target: '#general' });
  assert.match(post.text, /^Queued/);
  assert.equal(repos.approvals.list('pending').find((a) => a.tool.startsWith('mcp__'))!.kind, 'chat.send_message');

  assert.match((await call('request_approval', { tool: 'Bash', input: { command: 'gh pr list' }, summary: 'x' })).text, /does not need approval/);
  assert.ok((await call('request_approval', { tool: 'Bash', input: { command: 'sudo rm -rf /' }, summary: 'x' })).isError);
  assert.ok((await call('request_approval', { tool: 'Bash', input: { command: 'echo x >> scripts/build.sh' }, summary: 'x' })).isError, 'a protected path cannot be approved');
  assert.ok((await call('request_approval', { tool: 'Bash', input: { command: 'git push', preview: 'echo hi' }, summary: 'x' })).isError, 'no extra fields ride along with a command');
  assert.equal('preview' in (tools.get('request_approval') as unknown as { inputSchema: object }).inputSchema, false, 'the tool takes no preview');
  assert.ok((await call('request_approval', { tool: 'Write', input: { file_path: '/etc/hosts' }, summary: 'x' })).isError);
  assert.ok((await call('request_approval', { tool: 'mcp__steward__task_create', input: {}, summary: 'x' })).isError);
  assert.ok((await call('request_approval', { tool: 'mcp__claude_ai_Other__send', input: {}, summary: 'x' })).isError, 'unknown connector tool');
  assert.equal(repos.approvals.count('pending'), 2);
});

test('ask_user: a question suggestion outside chat, the answer inside it', async () => {
  const outside = await call('ask_user', { question: 'Ship Friday?', options: ['Yes', 'No'] });
  assert.match(outside.text, /Inbox/);
  assert.ok(repos.suggestions.list('pending').some((s) => s.kind === 'question' && s.title === 'Ship Friday?'));

  const asked: unknown[] = [];
  const inChat = new Map(stewardTools({ ...env, threadId: 't1', ask: async (question, options) => { asked.push([question, options]); return 'Yes'; } }).map((t) => [t.name, t]));
  assert.equal((await call('ask_user', { question: 'Ship Friday?', options: ['Yes', 'No'] }, inChat)).text, 'Yes');
  assert.deepEqual(asked, [['Ship Friday?', ['Yes', 'No']]]);
});

test('nudge, ui_command, schedule_job, cost_status, session_recap and the connector relay', async () => {
  const events: unknown[] = [];
  bus.on('ui.command', (e) => events.push(e));
  const nudge = (await call('nudge', { title: 'Stand up', body: 'You have sat for two hours', url: 'https://example.com' })).json;
  assert.deepEqual([repos.nudges.get(nudge.id)!.priority, repos.nudges.get(nudge.id)!.actions[0]!.kind], [1, 'open_url']);
  await call('ui_command', { command: 'open_view', args: { view: 'today' } });
  assert.deepEqual(events, [{ command: 'open_view', args: { view: 'today' } }]);
  await call('schedule_job', { name: 'plants-check', prompt: 'Check the plants', at: '09:00', days: [1, 3] });
  assert.deepEqual(scheduled, [{ name: 'plants-check', prompt: 'Check the plants', connectors: undefined, remove: undefined, schedule: { at: '09:00', days: [1, 3] } }]);
  assert.match((await call('cost_status')).text, /^today \$0\.00 of \$15/);
  assert.equal((await call('session_recap', { id: 's1' })).text, 'recap of s1');
  assert.deepEqual((await call('connector_tools', { query: 'calendar' })).json, { query: 'calendar' });
  assert.equal((await call('connector_read', { tool: 'mcp__x__list', input: {} })).text, 'read mcp__x__list');
  assert.match((await call('app_rebuild')).text, /^Build failed\.\n.*build\.sh not found/);
  assert.equal(typeof (await call('activity_summary')).json.focusMin, 'number');
});

test('connector names resolve by whole words and by kind', () => {
  const servers = ['claude.ai Slack', 'claude.ai Google Calendar', 'claude.ai Zoom for Claude', 'claude.ai ZoomInfo', 'claude.ai Linear', 'claude.ai monday.com', 'claude.ai Meetings', 'claude.ai Fathom'];
  assert.deepEqual(matchServers(['Calendar'], servers), ['claude.ai Google Calendar']);
  assert.deepEqual(matchServers(['claude.ai Slack', 'google calendar'], servers), ['claude.ai Slack', 'claude.ai Google Calendar']);
  assert.deepEqual(matchServers(['mcp__claude_ai_Google_Calendar'], servers), ['claude.ai Google Calendar']);
  assert.deepEqual(matchServers(['Zoom'], servers), ['claude.ai Zoom for Claude']);
  assert.deepEqual(matchServers(['tickets', 'meetings'], servers), ['claude.ai Zoom for Claude', 'claude.ai Linear', 'claude.ai Meetings', 'claude.ai Fathom']);
  assert.deepEqual(matchServers(['monday.com'], servers), ['claude.ai monday.com']);
  assert.deepEqual(matchServers(['Jira', ''], servers), []);
  assert.deepEqual(matchServers(['chat'], servers, { chat: ['Linear'] }), ['claude.ai Linear'], 'a configured kind replaces the built-in list');
});

test('background runs get read-only built-ins: no shell, no file-writing tool, no subagents', () => {
  assert.deepEqual(READ_BUILTINS, ['Read', 'Glob', 'Grep', 'WebSearch', 'WebFetch']);
});
