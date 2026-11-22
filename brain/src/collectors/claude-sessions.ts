import { existsSync, readdirSync, readFileSync, statSync, watch, type FSWatcher } from 'node:fs';
import { basename, dirname, join, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import type { AppContext } from '../core/context.js';
import type { CodeSession, Id, Ms, Task } from '../core/types.js';
import { DAY, HOUR, isPlainObject, MIN } from '../core/util.js';
import { clip, expandHome, resolveBin, run, settings, ticketsIn } from './settings.js';
import { readTail, type Derived, type TailState } from './transcript.js';

/** Why a session is `blocked` (a permission kind, or the question a background job asks). Nudges read it. */
export const blockedReasons = new Map<Id, string>();

export interface GitInfo { root: string; gitDir: string; repo: string }

/** The work tree `cwd` is in, found by walking up to `.git`. `repo` is the main checkout's name, shared by its worktrees. */
export function findGit(cwd: string): GitInfo | null {
  for (let dir = resolve(cwd); ; dir = dirname(dir)) {
    const dot = join(dir, '.git');
    const st = statSync(dot, { throwIfNoEntry: false });
    if (st?.isDirectory()) return { root: dir, gitDir: dot, repo: basename(dir) };
    if (st?.isFile()) {
      const m = /^gitdir:\s*(.+)$/m.exec(readFileSync(dot, 'utf8'));
      if (!m) return null;
      const gitDir = resolve(dir, m[1]!.trim());
      const pointer = join(gitDir, 'commondir');
      const common = existsSync(pointer) ? resolve(gitDir, readFileSync(pointer, 'utf8').trim()) : gitDir;
      return { root: dir, gitDir, repo: basename(common) === '.git' ? basename(dirname(common)) : basename(dir) };
    }
    if (dirname(dir) === dir) return null;
  }
}

/** The checked-out branch, or null when HEAD is detached. */
export function readBranch(gitDir: string): string | null {
  try {
    return /^ref: refs\/heads\/(.+)$/m.exec(readFileSync(join(gitDir, 'HEAD'), 'utf8'))?.[1]?.trim() ?? null;
  } catch {
    return null;
  }
}

export interface StateInput {
  /** From the session file: busy | idle | waiting. */
  status: string | null;
  waitingFor: string | null;
  /** Background job state, when the session is one: working | blocked | anything terminal. */
  job: string | null;
  /** A person has prompted it at least once. */
  prompted: boolean;
  since: Ms;
  idleAfterMs: number;
}

export function mapState(s: StateInput, now: Ms): CodeSession['state'] {
  if (s.job) return s.job === 'working' ? 'working' : s.job === 'blocked' ? 'blocked' : 'ended';
  if (s.status === 'busy') return 'working';
  // "dialog open" is the user's own slash-command UI, not the session asking for something.
  if (s.status === 'waiting' && s.waitingFor !== 'dialog open') return 'blocked';
  if (!s.prompted) return 'idle';
  // A turn that ended long ago is no longer "in flight": stop counting it as waiting on the user.
  return now - s.since > s.idleAfterMs ? 'idle' : 'waiting';
}

/** One session as the registry describes it, before transcript and git are folded in. */
interface Source {
  id: Id;
  /** Null for a background job, which has no terminal process of its own. */
  pid: number | null;
  name: string | null;
  /** The user named it, so the name is a better title than anything derived. */
  named: boolean;
  cwd: string;
  startedAt: Ms;
  status: string | null;
  waitingFor: string | null;
  job: string | null;
  question: string | null;
  since: Ms;
}

interface Track {
  transcript: string | null;
  searchedAt: Ms;
  tail: TailState | null;
  tailSig: string;
  gitCwd: string | null;
  git: GitInfo | null;
  headSig: string;
  branch: string | null;
  autoTitle: string | null;
  suggested: boolean;
  print: string;
  dirty: boolean;
}

interface Background { short: string; cwd: string; name: string | null; startedAt: Ms; state: string; question: string | null; at: Ms; sig: string }

const OPEN = ['inbox', 'todo', 'doing', 'waiting'];
const RECONCILE_EVERY = 5 * MIN;
const BASELINE = 'sessions:baseline';
const SWEEP_EVERY = 30_000;
const num = (v: unknown, fallback: number): number => (typeof v === 'number' && Number.isFinite(v) ? v : fallback);
const str = (v: unknown): string | null => (typeof v === 'string' && v ? v : null);
const squash = (s: string): string => s.trim().replace(/\s+/g, ' ');

function readJson(path: string): Record<string, unknown> | null {
  try {
    const data: unknown = JSON.parse(readFileSync(path, 'utf8'));
    return isPlainObject(data) ? data : null;
  } catch {
    return null;
  }
}

function pidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return (err as NodeJS.ErrnoException).code === 'EPERM';
  }
}

export interface SessionCollector {
  /** One pass over the registry; cheap when nothing changed. */
  poll(now?: Ms): void;
  /** Refresh the background-job list from the CLI. */
  reconcile(): Promise<void>;
  /** Link unlinked sessions to tasks, or suggest a task for them. */
  sweep(now?: Ms): void;
  stop(): void;
}

/**
 * Watches the Claude Code sessions on this machine: `<claudeDir>/sessions/<pid>.json` for liveness and
 * status, each session's transcript for prompts and cwd, `.git/HEAD` for the branch, and
 * `claude agents --json --all` for background jobs. Everything is stat-gated, so an idle pass is a few
 * dozen syscalls.
 */
export function createSessionCollector(ctx: AppContext, opts: { claudeDir?: string; useCli?: boolean } = {}): SessionCollector {
  const { repos } = ctx;
  const log = ctx.log.child('sessions');
  const claudeDir = () => opts.claudeDir ?? expandHome(settings(ctx).code.claudeDir);
  const tracks = new Map<Id, Track>();
  const files = new Map<string, { sig: string; data: Record<string, unknown> }>();
  const background = new Map<Id, Background>();
  // pid -> the process's real start time, to tell a reused pid from the session that wrote the file.
  const procStarts = new Map<number, string>();
  let psRunning = false;
  let reconciling = false;
  let reconciledAt = 0;
  let fileSet = '';
  let first = true;
  let watcher: FSWatcher | null = null;
  let debounce: NodeJS.Timeout | null = null;
  let warned = false;
  // Sessions already open when Steward first ran on this data dir are the Sessions screen's to link, not the Inbox's to fill.
  const baseline = repos.kv.get<Ms>(BASELINE) ?? Date.now();
  if (repos.kv.get(BASELINE) === null) repos.kv.set(BASELINE, baseline);

  function verifyPids(pids: number[]): void {
    if (psRunning || !pids.length) return;
    psRunning = true;
    void run('/bin/ps', ['-o', 'pid=,lstart=', '-p', pids.join(',')], { timeoutMs: 5000, env: { ...process.env, TZ: 'UTC', LC_ALL: 'C' } }).then((res) => {
      psRunning = false;
      // A failed spawn says nothing about the pids; an answer that omits one says it is gone.
      if (res.code === -1) return;
      for (const pid of pids) procStarts.set(pid, '');
      for (const line of res.stdout.split('\n')) {
        const m = /^\s*(\d+)\s+(.+)$/.exec(line);
        if (m) procStarts.set(+m[1]!, squash(m[2]!));
      }
      poll();
    });
  }

  function fromFiles(sources: Map<Id, Source>): void {
    const dir = join(claudeDir(), 'sessions');
    let names: string[];
    try {
      names = readdirSync(dir).filter((n) => /^\d+\.json$/.test(n));
    } catch {
      names = [];
    }
    const unverified: number[] = [];
    for (const name of names) {
      const path = join(dir, name);
      const st = statSync(path, { throwIfNoEntry: false });
      if (!st) continue;
      const sig = `${st.mtimeMs}:${st.size}`;
      let entry = files.get(name);
      if (entry?.sig !== sig) {
        // A file caught mid-write does not parse; keep the last good copy and try again next pass.
        const data = readJson(path);
        if (data) files.set(name, (entry = { sig, data }));
      }
      const f = entry?.data;
      const id = str(f?.sessionId);
      const pid = num(f?.pid, 0);
      const cwd = str(f?.cwd);
      if (!f || !id || !pid || !cwd) continue;
      const kind = str(f.kind) ?? 'interactive';
      // Daemon workers and SDK-driven runs (Steward's own agent among them) are not sessions the user is steering.
      if ((kind !== 'interactive' && kind !== 'bg') || str(f.entrypoint)?.startsWith('sdk') || (cwd + sep).startsWith(ctx.paths.home + sep)) continue;
      if (!pidAlive(pid)) {
        procStarts.delete(pid);
        continue;
      }
      const wrote = str(f.procStart);
      const actual = procStarts.get(pid);
      if (wrote && actual === undefined) unverified.push(pid);
      else if (wrote && actual !== squash(wrote)) continue;
      const startedAt = num(f.startedAt, Math.round(st.birthtimeMs));
      sources.set(id, {
        id, pid, cwd, startedAt,
        name: str(f.name), named: !!f.name && f.nameSource !== 'derived' && f.nameSource !== 'auto',
        status: str(f.status), waitingFor: str(f.waitingFor), job: null, question: null,
        since: num(f.statusUpdatedAt, num(f.updatedAt, startedAt)),
      });
    }
    for (const name of files.keys()) if (!names.includes(name)) files.delete(name);
    verifyPids(unverified);
    const set = names.join(',');
    if (set !== fileSet) {
      fileSet = set;
      reconciledAt = 0;
    }
  }

  function fromBackground(sources: Map<Id, Source>): void {
    for (const [id, bg] of background) {
      const path = join(claudeDir(), 'jobs', bg.short, 'state.json');
      const st = statSync(path, { throwIfNoEntry: false });
      const sig = st ? `${st.mtimeMs}:${st.size}` : '';
      if (sig !== bg.sig) {
        const job = st ? readJson(path) : null;
        bg.sig = sig;
        if (job) {
          bg.state = str(job.state) ?? bg.state;
          bg.question = str(isPlainObject(job.needsAsk) ? job.needsAsk.text : null) ?? str(job.needs);
          bg.at = Date.parse(String(job.updatedAt)) || bg.at;
        }
      }
      const live = sources.get(id);
      if (live) Object.assign(live, { job: bg.state, question: bg.question });
      else if (bg.state === 'working' || bg.state === 'blocked') {
        sources.set(id, { id, pid: null, name: bg.name, named: false, cwd: bg.cwd, startedAt: bg.startedAt, status: null, waitingFor: null, job: bg.state, question: bg.question, since: bg.at });
      }
    }
  }

  async function reconcile(): Promise<void> {
    if (reconciling) return;
    reconciling = true;
    reconciledAt = Date.now();
    try {
      const bin = await resolveBin('claude', settings(ctx).code.claudeBin);
      if (!bin) {
        if (!warned) log.warn('claude CLI not found; background jobs are not tracked (set code.claudeBin)');
        warned = true;
        return;
      }
      const res = await run(bin, ['agents', '--json', '--all'], { timeoutMs: 15_000 });
      const json = res.stdout.slice(res.stdout.indexOf('['), res.stdout.lastIndexOf(']') + 1);
      if (res.code !== 0 || !json) {
        log.debug('claude agents failed', res.stderr.slice(0, 200));
        return;
      }
      const seen = new Set<Id>();
      for (const a of JSON.parse(json) as unknown[]) {
        if (!isPlainObject(a) || a.kind !== 'background') continue;
        const id = str(a.sessionId);
        const short = str(a.id);
        const cwd = str(a.cwd);
        if (!id || !short || !cwd) continue;
        seen.add(id);
        const known = background.get(id);
        const startedAt = num(a.startedAt, Date.now());
        background.set(id, { short, cwd, name: str(a.name), startedAt, state: str(a.state) ?? 'working', question: known?.question ?? null, at: known?.at ?? startedAt, sig: known?.sig ?? '-' });
      }
      for (const id of background.keys()) if (!seen.has(id)) background.delete(id);
      repos.health.synced('sessions');
    } catch (err) {
      log.warn('reconcile failed', err);
    } finally {
      reconciling = false;
    }
  }

  function locate(src: Source, t: Track, now: Ms): string | null {
    const projects = join(claudeDir(), 'projects');
    const direct = join(projects, src.cwd.replace(/[^A-Za-z0-9]/g, '-'), `${src.id}.jsonl`);
    if (existsSync(direct)) return direct;
    // A resumed session can live under another launch dir's slug; looking is a readdir, so do it rarely.
    if (now - t.searchedAt < MIN) return null;
    t.searchedAt = now;
    try {
      for (const slug of readdirSync(projects)) {
        const path = join(projects, slug, `${src.id}.jsonl`);
        if (existsSync(path)) return path;
      }
    } catch { /* no projects dir yet */ }
    return null;
  }

  function titleOf(src: Source, d: Derived | undefined): string | null {
    const raw = (src.named && src.name) || d?.aiTitle || d?.firstPrompt || d?.lastUserPrompt || null;
    return raw ? clip(squash(raw.split('\n').find((l) => l.trim()) ?? raw), 80) : null;
  }

  function update(src: Source, now: Ms): void {
    let t = tracks.get(src.id);
    if (!t) {
      const saved = repos.kv.get<{ tail: TailState | null; autoTitle: string | null }>(`cc:s:${src.id}`);
      t = { transcript: null, searchedAt: 0, tail: saved?.tail ?? null, tailSig: '', gitCwd: null, git: null, headSig: '', branch: null, autoTitle: saved?.autoTitle ?? null, suggested: false, print: '', dirty: false };
      tracks.set(src.id, t);
    }

    t.transcript ??= locate(src, t, now);
    const st = t.transcript ? statSync(t.transcript, { throwIfNoEntry: false }) : undefined;
    if (st && `${st.ino}:${st.size}` !== t.tailSig) {
      t.tailSig = `${st.ino}:${st.size}`;
      try {
        const next = readTail(t.transcript!, st, t.tail);
        t.dirty ||= next !== t.tail;
        t.tail = next;
      } catch (err) {
        log.debug(`transcript read failed for ${src.id}`, err);
      }
    }
    const d = t.tail?.derived;

    const cwd = d?.cwd ?? src.cwd;
    if (cwd !== t.gitCwd) {
      t.gitCwd = cwd;
      t.git = findGit(cwd);
      t.headSig = '';
    }
    if (t.git) {
      const head = statSync(join(t.git.gitDir, 'HEAD'), { throwIfNoEntry: false });
      const sig = head ? String(head.mtimeMs) : 'gone';
      if (sig !== t.headSig) {
        t.headSig = sig;
        t.branch = readBranch(t.git.gitDir);
      }
    }

    const cfg = settings(ctx).code;
    const state = mapState({ status: src.status, waitingFor: src.waitingFor, job: src.job, prompted: !!(d?.firstPrompt || d?.lastUserPrompt), since: src.since, idleAfterMs: cfg.idleAfterHours * HOUR }, now);
    const auto = titleOf(src, d);
    const patch = {
      id: src.id, pid: src.pid, name: src.name, cwd,
      repo: t.git?.repo ?? null,
      branch: t.git ? t.branch : null,
      ticket: ticketsIn(cfg.ticketPattern, t.git && t.branch, t.git && basename(t.git.root), basename(cwd))[0] ?? null,
      state, stateSince: src.since, startedAt: src.startedAt,
      lastUserPrompt: d?.lastUserPrompt ?? null,
      lastAssistantText: (state === 'blocked' && src.question) || d?.lastAssistantText || null,
    };
    const print = JSON.stringify([patch, auto]);
    if (print === t.print) return;
    t.print = print;

    if (state === 'blocked') blockedReasons.set(src.id, src.question ?? src.waitingFor ?? 'needs input');
    else blockedReasons.delete(src.id);

    // The title stays ours to refresh only until the user or a recap replaces it.
    const current = repos.sessions.get(src.id);
    const ours = !current || current.title === null || current.title === t.autoTitle;
    t.dirty ||= auto !== t.autoTitle;
    t.autoTitle = auto;
    const saved = repos.sessions.upsert(ours ? { ...patch, title: auto } : patch);
    if (!current || current.ticket !== saved.ticket) link([saved], now);
  }

  function end(id: Id): void {
    tracks.delete(id);
    blockedReasons.delete(id);
    repos.kv.delete(`cc:s:${id}`);
    repos.kv.delete(`title:${id}`);
    repos.sessions.upsert({ id, state: 'ended', pid: null });
  }

  function poll(now: Ms = Date.now()): void {
    try {
      const sources = new Map<Id, Source>();
      fromFiles(sources);
      fromBackground(sources);
      for (const src of sources.values()) update(src, now);
      for (const id of [...tracks.keys()]) if (!sources.has(id)) end(id);
      if (first) {
        first = false;
        for (const s of repos.sessions.list()) if (!sources.has(s.id)) end(s.id);
        repos.health.set('sessions', existsSync(join(claudeDir(), 'sessions')) ? 'ok' : 'off');
      }
      if (opts.useCli !== false && !reconciling && Date.now() - reconciledAt > RECONCILE_EVERY) void reconcile().then(() => poll());
    } catch (err) {
      log.error('poll failed', err);
    }
  }

  const tracksTask = (task: Task, s: CodeSession, pattern: string): boolean =>
    (task.source === 'claude' && task.sourceRef === s.id)
    || task.links.some((l) => l.kind === 'session' && l.ref === s.id)
    || (s.ticket !== null && ticketsIn(pattern, task.title, task.sourceRef, ...task.links.flatMap((l) => [l.ref, l.url, l.title])).includes(s.ticket));

  function link(sessions: CodeSession[], now: Ms): void {
    const unlinked = sessions.filter((s) => !s.taskId && tracks.has(s.id));
    if (!unlinked.length) return;
    const tasks = repos.tasks.list({ status: OPEN, limit: 500 });
    const pattern = settings(ctx).code.ticketPattern;
    for (const s of unlinked) {
      const task = tasks.find((t) => tracksTask(t, s, pattern));
      if (task) repos.sessions.upsert({ id: s.id, taskId: task.id });
      else suggest(s, tracks.get(s.id)!, now);
    }
  }

  /** One low-confidence `new_task` per session, and only for sessions that look like real work: started since Steward's first run, prompted, older than ten minutes, recently active. */
  function suggest(s: CodeSession, t: Track, now: Ms): void {
    if (t.suggested || s.pid === null || !s.title || s.startedAt <= baseline || now - s.startedAt < 10 * MIN || now - (t.tail?.derived.lastAt ?? 0) > 3 * DAY) return;
    t.suggested = true;
    if (ctx.db.prepare("SELECT 1 FROM suggestions WHERE source = 'claude' AND sourceRef = ? LIMIT 1").get(s.id)) return;
    const title = s.ticket && !s.title.toUpperCase().includes(s.ticket) ? `${s.ticket}: ${s.title}` : s.title;
    repos.suggestions.create({
      kind: 'new_task', title,
      rationale: `A Claude Code session${s.repo ? ` in ${s.repo}` : ''}${s.branch ? ` on ${s.branch}` : ''} is working on this and no task tracks it.`,
      payload: { title, links: [{ kind: 'session', title: s.name ?? 'Claude Code session', url: pathToFileURL(s.cwd).href, ref: s.id }] },
      source: 'claude', sourceRef: s.id, confidence: s.ticket ? 0.6 : 0.4,
    });
  }

  function sweep(now: Ms = Date.now()): void {
    try {
      link(repos.sessions.list(), now);
      flush();
      if (!watcher) startWatch();
    } catch (err) {
      log.error('sweep failed', err);
    }
  }

  // Offsets are saved on the sweep, not on every append: a crash costs re-reading half a minute of transcript.
  function flush(): void {
    for (const [id, t] of tracks) {
      if (!t.dirty) continue;
      t.dirty = false;
      repos.kv.set(`cc:s:${id}`, { tail: t.tail, autoTitle: t.autoTitle });
    }
  }

  function startWatch(): void {
    try {
      watcher = watch(join(claudeDir(), 'sessions'), { persistent: false }, () => {
        debounce ??= setTimeout(() => {
          debounce = null;
          poll();
        }, 150);
      });
      watcher.on('error', () => {
        watcher?.close();
        watcher = null;
      });
    } catch { /* no sessions dir yet: the sweep tries again */ }
  }

  // An accepted suggestion creates the task that should now own its session.
  const off = ctx.bus.on('state.changed', ({ entities }) => {
    if (entities.includes('suggestions')) setTimeout(sweep, 500).unref();
  });
  const pollTimer = setInterval(poll, Math.max(1, settings(ctx).code.pollSec) * 1000);
  const sweepTimer = setInterval(sweep, SWEEP_EVERY);
  pollTimer.unref();
  sweepTimer.unref();
  startWatch();

  return {
    poll,
    reconcile,
    sweep,
    stop() {
      clearInterval(pollTimer);
      clearInterval(sweepTimer);
      if (debounce) clearTimeout(debounce);
      watcher?.close();
      off();
      flush();
    },
  };
}
