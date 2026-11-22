import assert from 'node:assert/strict';
import { appendFileSync, mkdirSync, mkdtempSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, test } from 'node:test';
import { startBrain, type Brain } from '../app.js';
import { matchSession } from '../collectors/activity.js';
import { badgeQuiet, parseBadge } from '../collectors/badges.js';
import { visitSignals } from '../collectors/browser.js';
import { createSessionCollector, findGit, mapState, readBranch } from '../collectors/claude-sessions.js';
import { diffPrs, parsePrs, prFor, type Pr } from '../collectors/git-prs.js';
import { decodeAttributedBody } from '../collectors/messages.js';
import { settings, ticketsIn } from '../collectors/settings.js';
import { emptyDerived, foldLine, readTail, type TailState } from '../collectors/transcript.js';
import { HOUR, MIN } from '../core/util.js';

const home = mkdtempSync(join(tmpdir(), 'steward-collectors-'));
process.env.STEWARD_HOME = join(home, 'data');
process.env.STEWARD_LOG_LEVEL = 'silent';

let brain: Brain;
before(async () => {
  brain = await startBrain({ port: 0 });
});
after(async () => {
  await brain.stop();
  rmSync(home, { recursive: true, force: true });
});

const iso = (offsetMs = 0) => new Date(Date.now() + offsetMs).toISOString();
const line = (row: object) => JSON.stringify(row) + '\n';
const prompt = (text: string, extra: object = {}) => line({ parentUuid: null, type: 'user', origin: { kind: 'human' }, promptSource: 'typed', message: { role: 'user', content: text }, cwd: '/work/acme-api', timestamp: iso(), ...extra });
const reply = (text: string, stop = 'end_turn', extra: object = {}) => line({ parentUuid: 'u1', type: 'assistant', message: { role: 'assistant', stop_reason: stop, content: [{ type: 'thinking', thinking: 'hm' }, { type: 'text', text }] }, cwd: '/work/acme-api', timestamp: iso(), ...extra });
const NOISE = [
  line({ type: 'api-request-blob', body: 'x'.repeat(200) }),
  line({ parentUuid: 'u1', type: 'attachment', attachment: { text: 'pasted' } }),
  line({ parentUuid: 'u1', type: 'user', toolUseResult: { ok: true }, message: { content: [{ type: 'tool_result', content: 'tool output' }] } }),
  line({ parentUuid: 'u1', type: 'user', isMeta: true, message: { content: '<local-command-stdout>ok</local-command-stdout>' } }),
  line({ parentUuid: 'u1', type: 'user', origin: { kind: 'task-notification' }, promptSource: 'system', message: { content: '<task-notification>done</task-notification>' } }),
  line({ parentUuid: 'u1', type: 'assistant', isSidechain: true, message: { content: [{ type: 'text', text: 'subagent chatter' }] } }),
].join('');

test('transcript lines fold into the latest prompt, reply, cwd and title', () => {
  const d = emptyDerived();
  const text = prompt('Add a CSV export to the Acme invoices page') + NOISE + reply('Reading the invoices module.', 'tool_use')
    + reply('Export added.', 'end_turn', { cwd: '/work/acme-api-eng-77' }) + line({ type: 'ai-title', aiTitle: 'Add CSV export' }) + prompt('Now add tests');
  for (const l of text.split('\n')) foldLine(d, l);
  assert.equal(d.firstPrompt, 'Add a CSV export to the Acme invoices page');
  assert.equal(d.lastUserPrompt, 'Now add tests');
  assert.equal(d.lastAssistantText, 'Export added.');
  assert.equal(d.cwd, '/work/acme-api');
  assert.equal(d.aiTitle, 'Add CSV export');
  assert.ok(d.lastAt);

  foldLine(d, line({ type: 'last-prompt', lastPrompt: 'Ship it' }));
  assert.equal(d.lastUserPrompt, 'Ship it');
  foldLine(d, '{"parentUuid":"u1","type":"assistant","message":{"content":[{"type":"te');
  assert.equal(d.lastAssistantText, 'Export added.', 'a torn line changes nothing');
});

test('readTail reads only what was appended and survives torn lines and rotation', () => {
  const file = join(home, 'tail.jsonl');
  const stat = () => statSync(file);
  writeFileSync(file, prompt('First ask') + reply('First answer'));
  let state: TailState = readTail(file, stat(), null);
  assert.equal(state.offset, stat().size);
  assert.equal(state.derived.lastAssistantText, 'First answer');

  const torn = reply('Second answer');
  appendFileSync(file, prompt('Second ask') + torn.slice(0, 40));
  const mid = readTail(file, stat(), state);
  assert.equal(mid.derived.lastUserPrompt, 'Second ask');
  assert.equal(mid.derived.lastAssistantText, 'First answer');
  assert.equal(mid.offset, stat().size - 40, 'the torn line is left for the next read');
  assert.equal(readTail(file, stat(), mid), mid, 'nothing whole appended: same state object');

  appendFileSync(file, torn.slice(40));
  state = readTail(file, stat(), mid);
  assert.equal(state.derived.lastAssistantText, 'Second answer');
  assert.equal(state.derived.firstPrompt, 'First ask');

  writeFileSync(file, prompt('Fresh file'));
  assert.equal(readTail(file, stat(), state).derived.firstPrompt, 'Fresh file', 'a shorter file is read from the start');
});

test('a cold read of a large transcript takes the head prompt and the tail state', () => {
  const file = join(home, 'big.jsonl');
  const filler = line({ type: 'api-request-blob', body: 'x'.repeat(4000) }).repeat(200);
  writeFileSync(file, prompt('Original ask from long ago') + filler + prompt('Latest ask') + reply('Latest answer'));
  const state = readTail(file, statSync(file), null);
  assert.equal(state.derived.firstPrompt, 'Original ask from long ago');
  assert.equal(state.derived.lastUserPrompt, 'Latest ask');
  assert.equal(state.derived.lastAssistantText, 'Latest answer');
});

test('mapState', () => {
  const now = Date.now();
  const base = { status: 'idle', waitingFor: null, job: null, prompted: true, since: now - MIN, idleAfterMs: 12 * HOUR };
  assert.equal(mapState({ ...base, status: 'busy' }, now), 'working');
  assert.equal(mapState(base, now), 'waiting');
  assert.equal(mapState({ ...base, prompted: false }, now), 'idle');
  assert.equal(mapState({ ...base, since: now - 13 * HOUR }, now), 'idle');
  assert.equal(mapState({ ...base, status: 'waiting', waitingFor: 'permission prompt' }, now), 'blocked');
  assert.equal(mapState({ ...base, status: 'waiting', waitingFor: 'input needed' }, now), 'blocked');
  assert.equal(mapState({ ...base, status: 'waiting', waitingFor: 'dialog open' }, now), 'waiting');
  assert.equal(mapState({ ...base, status: null, job: 'blocked' }, now), 'blocked');
  assert.equal(mapState({ ...base, status: null, job: 'working' }, now), 'working');
  assert.equal(mapState({ ...base, status: null, job: 'stopped' }, now), 'ended');
});

test('ticket ids come from the configured pattern, bounded and upper-cased', () => {
  const pattern = settings(brain.ctx).code.ticketPattern;
  assert.deepEqual(ticketsIn(pattern, 'eng-123-fix-login'), ['ENG-123']);
  assert.deepEqual(ticketsIn(pattern, null, 'acme-api-eng-77-export', 'ENG-77 again'), ['ENG-77']);
  assert.deepEqual(ticketsIn(pattern, 'release-2024', 'main', 'feature/login'), []);
  assert.deepEqual(ticketsIn('ACME-\\d+', 'eng-1 ACME-42'), ['ACME-42']);
  assert.deepEqual(ticketsIn('(((', 'eng-1'), [], 'a broken pattern matches nothing');
});

function fakeRepo(): { main: string; worktree: string } {
  const main = join(home, 'work', 'acme-api');
  const worktree = join(home, 'work', 'acme-api-eng-77');
  mkdirSync(join(main, '.git', 'worktrees', 'wt'), { recursive: true });
  mkdirSync(join(worktree, 'src'), { recursive: true });
  writeFileSync(join(main, '.git', 'HEAD'), 'ref: refs/heads/main\n');
  writeFileSync(join(main, '.git', 'worktrees', 'wt', 'HEAD'), 'ref: refs/heads/eng-77-add-export\n');
  writeFileSync(join(main, '.git', 'worktrees', 'wt', 'commondir'), '../..\n');
  writeFileSync(join(worktree, '.git'), `gitdir: ${join(main, '.git', 'worktrees', 'wt')}\n`);
  return { main, worktree };
}

test('git info is read from .git without running git, worktrees included', () => {
  const { main, worktree } = fakeRepo();
  const top = findGit(main)!;
  assert.deepEqual([top.root, top.repo, readBranch(top.gitDir)], [main, 'acme-api', 'main']);
  const wt = findGit(join(worktree, 'src'))!;
  assert.deepEqual([wt.root, wt.repo, readBranch(wt.gitDir)], [worktree, 'acme-api', 'eng-77-add-export']);
  writeFileSync(join(main, '.git', 'HEAD'), '4f2a9c0d\n');
  assert.equal(readBranch(top.gitDir), null, 'detached HEAD has no branch');
  assert.equal(findGit(tmpdir()), null);
});

test('session collector: state, git, ticket, title, task link, one suggestion, ended', () => {
  const { repos } = brain.ctx;
  const { worktree } = fakeRepo();
  const claudeDir = join(home, 'claude');
  const now = Date.now();
  const scratch = join(home, 'work', 'scratch');
  mkdirSync(scratch, { recursive: true });
  const sessionFile = (id: string, pid: number, patch: object = {}) => {
    mkdirSync(join(claudeDir, 'sessions'), { recursive: true });
    writeFileSync(join(claudeDir, 'sessions', `${pid}.json`), JSON.stringify({
      pid, sessionId: id, cwd: worktree, startedAt: now - 20 * MIN, kind: 'interactive', entrypoint: 'cli',
      name: 'acme-api-ab', nameSource: 'derived', status: 'busy', statusUpdatedAt: now - 5000, ...patch,
    }));
  };
  const transcript = (id: string, text: string, cwd = worktree) => {
    const dir = join(claudeDir, 'projects', cwd.replace(/[^A-Za-z0-9]/g, '-'));
    mkdirSync(dir, { recursive: true });
    appendFileSync(join(dir, `${id}.jsonl`), text);
  };
  const events: string[] = [];
  const off = brain.ctx.bus.on('session.updated', (s) => events.push(`${s.id}:${s.state}`));
  // Steward has been running since before these sessions began; the ones older than its first run are covered at the end.
  repos.kv.set('sessions:baseline', now - 30 * MIN);
  const collector = createSessionCollector(brain.ctx, { claudeDir, useCli: false });
  try {
    sessionFile('sess-1', process.pid);
    transcript('sess-1', prompt('Add a CSV export to the Acme invoices page', { cwd: join(worktree, 'src') }) + reply('Working on it.', 'tool_use', { cwd: join(worktree, 'src') }));
    collector.poll();
    let s = repos.sessions.must('sess-1');
    assert.deepEqual([s.state, s.repo, s.branch, s.ticket, s.pid], ['working', 'acme-api', 'eng-77-add-export', 'ENG-77', process.pid]);
    assert.equal(s.cwd, join(worktree, 'src'), 'cwd follows the transcript, not the launch dir');
    assert.equal(s.title, 'Add a CSV export to the Acme invoices page');
    assert.equal(s.startedAt, now - 20 * MIN);
    const own = repos.suggestions.list().filter((x) => x.sourceRef === 'sess-1');
    assert.deepEqual(own.map((x) => [x.kind, x.title]), [['new_task', 'ENG-77: Add a CSV export to the Acme invoices page']], 'no task tracks it yet');

    const before = events.length;
    collector.poll();
    assert.equal(events.length, before, 'an unchanged registry writes and announces nothing');

    sessionFile('sess-1', process.pid, { status: 'idle', statusUpdatedAt: now - 1000 });
    transcript('sess-1', reply('Export added.', 'end_turn', { cwd: join(worktree, 'src') }));
    collector.poll();
    s = repos.sessions.must('sess-1');
    assert.deepEqual([s.state, s.stateSince, s.lastAssistantText], ['waiting', now - 1000, 'Export added.']);

    sessionFile('sess-1', process.pid, { status: 'waiting', waitingFor: 'permission prompt', statusUpdatedAt: now - 500 });
    collector.poll();
    assert.equal(repos.sessions.must('sess-1').state, 'blocked');

    repos.sessions.upsert({ id: 'sess-1', title: 'Renamed by the user' });
    transcript('sess-1', line({ type: 'ai-title', aiTitle: 'CSV export' }));
    collector.poll();
    assert.equal(repos.sessions.must('sess-1').title, 'Renamed by the user', 'a title someone set is not overwritten');

    const task = repos.tasks.create({ title: 'ENG-77 invoice export' });
    collector.sweep();
    assert.equal(repos.sessions.must('sess-1').taskId, task.id, 'linked by ticket id');

    // A second session outside any repo. A dead pid would be skipped, so borrow a live one (the parent's).
    sessionFile('sess-2', process.ppid, { status: 'idle', cwd: scratch });
    transcript('sess-2', prompt('Sketch the onboarding flow', { cwd: scratch }) + reply('Here is a sketch.', 'end_turn', { cwd: scratch }), scratch);
    collector.poll();
    assert.deepEqual([repos.sessions.must('sess-2').repo, repos.sessions.must('sess-2').ticket], [null, null]);
    collector.sweep();
    collector.sweep();
    const suggested = repos.suggestions.list().filter((x) => x.sourceRef === 'sess-2');
    assert.equal(suggested.length, 1, 'one suggestion per session');
    assert.deepEqual([suggested[0]!.kind, suggested[0]!.source, suggested[0]!.title], ['new_task', 'claude', 'Sketch the onboarding flow']);
    const accepted = repos.suggestions.accept(suggested[0]!.id).task!;
    collector.sweep();
    assert.equal(repos.sessions.must('sess-2').taskId, accepted.id, 'the accepted task owns its session');

    // Open since before Steward's first run on this data dir: it shows on the Sessions screen, and the Inbox stays empty.
    sessionFile('sess-0', process.ppid, { status: 'idle', cwd: scratch, startedAt: now - 2 * HOUR });
    transcript('sess-0', prompt('Tidy the release notes', { cwd: scratch }) + reply('Tidied.', 'end_turn', { cwd: scratch }), scratch);
    collector.poll();
    collector.sweep();
    assert.equal(repos.sessions.must('sess-0').title, 'Tidy the release notes');
    assert.deepEqual(repos.suggestions.list().filter((x) => x.sourceRef === 'sess-0'), []);

    sessionFile('sess-3', 999_999_9);
    collector.poll();
    assert.equal(repos.sessions.get('sess-3'), null, 'a file whose pid is not running is stale');

    rmSync(join(claudeDir, 'sessions', `${process.pid}.json`));
    collector.poll();
    assert.equal(repos.sessions.must('sess-1').state, 'ended');
    assert.ok(events.includes('sess-1:ended'));
  } finally {
    off();
    collector.stop();
  }
});

const pr = (patch: Partial<Pr> = {}): Pr => ({ number: 12, title: 'ENG-77: invoice export', url: 'https://github.com/acme/api/pull/12', repo: 'acme/api', branch: 'eng-77-add-export', state: 'OPEN', reviewDecision: null, checks: 'SUCCESS', unresolved: 0, updatedAt: 1000, ...patch });

test('PR diff reports what changed, and a first sighting never toasts', () => {
  assert.deepEqual(diffPrs([], [pr()]), []);
  const first = diffPrs([], [pr({ reviewDecision: 'CHANGES_REQUESTED', checks: 'FAILURE', unresolved: 2 })]);
  assert.deepEqual(first.map((e) => [e.kind, e.nudge]), [['changes_requested', false], ['checks_failed', false], ['threads', false]]);

  const kinds = (next: Partial<Pr>, prev: Partial<Pr> = {}) => diffPrs([pr(prev)], [pr(next)]).map((e) => e.kind);
  assert.deepEqual(kinds({ reviewDecision: 'CHANGES_REQUESTED' }), ['changes_requested']);
  assert.deepEqual(kinds({ reviewDecision: 'CHANGES_REQUESTED' }, { reviewDecision: 'CHANGES_REQUESTED' }), []);
  assert.deepEqual(kinds({ reviewDecision: 'APPROVED' }), ['approved']);
  assert.deepEqual(kinds({ checks: 'FAILURE' }), ['checks_failed']);
  assert.deepEqual(kinds({ checks: 'ERROR' }, { checks: 'FAILURE' }), []);
  assert.deepEqual(kinds({ unresolved: 3 }, { unresolved: 1 }), ['threads']);
  assert.deepEqual(kinds({ unresolved: 1 }, { unresolved: 3 }), []);
  assert.deepEqual(kinds({ state: 'MERGED' }), ['merged']);
  assert.ok(diffPrs([pr()], [pr({ checks: 'FAILURE' })])[0]!.nudge);
});

test('PRs parse from the GraphQL reply and join to sessions by branch', () => {
  const node = (n: number, extra: object = {}) => ({ number: n, title: `PR ${n}`, url: `https://github.com/acme/api/pull/${n}`, state: 'OPEN', headRefName: `eng-${n}-x`, updatedAt: '2026-01-15T10:00:00Z', reviewDecision: '', repository: { nameWithOwner: 'acme/api' }, ...extra });
  const prs = parsePrs(JSON.stringify({ data: { viewer: {
    open: { nodes: [node(1, { reviewDecision: 'APPROVED', commits: { nodes: [{ commit: { statusCheckRollup: { state: 'FAILURE' } } }] }, reviewThreads: { nodes: [{ isResolved: false }, { isResolved: true }] } })] },
    closed: { nodes: [node(2, { state: 'MERGED' })] },
  } } }));
  assert.deepEqual(prs.map((p) => [p.number, p.state, p.reviewDecision, p.checks, p.unresolved]), [[1, 'OPEN', 'APPROVED', 'FAILURE', 1], [2, 'MERGED', null, null, null]]);
  assert.equal(prFor(prs, 'eng-1-x', 'api')?.number, 1);
  assert.equal(prFor(prs, 'eng-2-x', null)?.state, 'MERGED');
  assert.equal(prFor(prs, 'main', 'api'), null);
  assert.equal(prFor(prs, null, 'api'), null);
  assert.throws(() => parsePrs('{"errors":[]}'));
});

test('Dock badges parse, and a quiet badge lets a sync sit out', () => {
  assert.deepEqual(parseBadge('"StatusLabel"={ "label"="5" }\n'), { label: '5', weight: 5 });
  assert.deepEqual(parseBadge('"StatusLabel"={ "label"="•" }'), { label: '•', weight: 0.5 });
  assert.deepEqual(parseBadge('"StatusLabel"={ "label"="" }'), { label: '', weight: 0 });
  assert.deepEqual(parseBadge('"StatusLabel"=[ NULL ]'), { label: '', weight: 0 });
  assert.deepEqual(parseBadge(''), { label: null, weight: 0 });

  const { repos } = brain.ctx;
  const now = Date.now();
  const chatApp = settings(brain.ctx).connectors.badges!.apps as { id: string; family: string }[];
  const id = chatApp.find((a) => a.family === 'chat')!.id;
  assert.equal(badgeQuiet(brain.ctx, 'chat', now - MIN, now), false, 'no badge data: never skip');
  repos.health.synced('badges', now);
  repos.kv.set('badges', { apps: { [id]: { label: '2', weight: 2, at: now - HOUR } }, increasedAt: { chat: now - HOUR } });
  assert.equal(badgeQuiet(brain.ctx, 'chat', now - MIN, now), true);
  assert.equal(badgeQuiet(brain.ctx, 'chat', now - 2 * HOUR, now), false, 'the badge rose after the last sync');
  assert.equal(badgeQuiet(brain.ctx, 'tickets', now - MIN, now), false, 'no running app for that family');
  repos.kv.delete('badges');
});

test('browser visits become signals only for work-ish URLs, once per URL and day', () => {
  const at = new Date(2026, 0, 15, 10).getTime();
  const signals = visitSignals([
    { url: 'https://github.com/acme/api/pull/12', title: 'ENG-77: invoice export', at },
    { url: 'https://github.com/acme/api/pull/12?diff=split#discussion', title: 'ENG-77: invoice export', at: at + MIN },
    { url: 'https://news.example.com/story', title: 'News', at },
    { url: 'https://docs.google.com/document/d/abc123/edit', title: 'Acme proposal', at },
  ], settings(brain.ctx).connectors.browser!.patterns as string[]);
  assert.deepEqual(signals.map((s) => s.externalId), ['2026-01-15|https://github.com/acme/api/pull/12', '2026-01-15|https://docs.google.com/document/d/abc123/edit']);
  assert.equal(visitSignals([{ url: 'https://github.com/acme/api/pull/12', title: '', at }], ['((']).length, 0);
});

test('iMessage attributedBody decodes short and long strings', () => {
  const archive = (text: string) => {
    const bytes = Buffer.from(text, 'utf8');
    const length = bytes.length < 0x80 ? Buffer.from([bytes.length]) : Buffer.from([0x81, bytes.length & 0xff, bytes.length >> 8]);
    return Buffer.concat([Buffer.from('\x04\x0bstreamtyped\x81\xe8\x03\x84\x01@\x84\x84\x84\x12NSAttributedString\x00\x84\x84\x08NSObject\x00\x85\x92\x84\x84\x84\x08NSString\x01\x94\x84\x01+', 'latin1'), length, bytes, Buffer.from('\x86\x84\x02iI\x01', 'latin1')]);
  };
  assert.equal(decodeAttributedBody(archive('Lunch at one? 🍜')), 'Lunch at one? 🍜');
  const long = 'Acme contract notes. '.repeat(20);
  assert.equal(decodeAttributedBody(archive(long)), long);
  assert.equal(decodeAttributedBody(Buffer.from('not an archive + at all')), null);
  assert.equal(decodeAttributedBody(null), null);
});

test('activity spans map to sessions through editor and terminal window titles', () => {
  const sessions = [
    { id: 'a', name: 'acme-api-ab', cwd: '/work/acme-api-eng-77/src', repo: 'acme-api' },
    { id: 'b', name: 'billing-3f', cwd: '/work/billing', repo: null },
  ];
  const editors = settings(brain.ctx).code.editorApps;
  assert.equal(matchSession({ app: 'Code', bundleId: 'com.microsoft.VSCode', title: 'export.ts — acme-api' }, sessions, editors), 'a');
  assert.equal(matchSession({ app: 'Terminal', bundleId: null, title: 'billing — zsh' }, sessions, editors), 'b');
  assert.equal(matchSession({ app: 'Safari', bundleId: null, title: 'acme-api pull request' }, sessions, editors), null, 'not an editor');
  assert.equal(matchSession({ app: 'Code', bundleId: null, title: 'notes.md — journal' }, sessions, editors), null);
});
