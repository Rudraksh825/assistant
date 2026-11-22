import type { AppContext } from '../core/context.js';
import type { Id, Ms, NudgeAction } from '../core/types.js';
import { isPlainObject, MIN } from '../core/util.js';
import type { SignalInput } from '../domain/records.js';
import { notify } from '../jobs/notify.js';
import { connector, resolveBin, run, settings } from './settings.js';

export interface Pr {
  number: number; title: string; url: string; repo: string; branch: string;
  /** OPEN | MERGED | CLOSED */
  state: string;
  reviewDecision: string | null;
  /** Roll-up of the head commit's checks: SUCCESS | FAILURE | ERROR | PENDING | EXPECTED. */
  checks: string | null;
  unresolved: number | null;
  updatedAt: Ms;
}

export interface PrEvent { kind: 'changes_requested' | 'approved' | 'checks_failed' | 'threads' | 'merged' | 'closed'; pr: Pr; title: string; nudge: boolean }

/** kv `prs`: the last fetch, also read by briefs and the onboarding scan. */
export interface PrSnapshot { at: Ms; items: Pr[] }

const FIELDS = 'number title url state headRefName updatedAt reviewDecision repository { nameWithOwner }';
const QUERY = `query { viewer {
  open: pullRequests(states: OPEN, first: 50, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { ${FIELDS}
    commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
    reviewThreads(first: 100) { nodes { isResolved } } } }
  closed: pullRequests(states: [MERGED, CLOSED], first: 15, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { ${FIELDS} } }
} }`;

const DEFAULT_BRANCHES = new Set(['main', 'master', 'develop', 'trunk', 'HEAD']);
const failed = (checks: string | null) => checks === 'FAILURE' || checks === 'ERROR';

export function parsePrs(json: string): Pr[] {
  const viewer = (JSON.parse(json) as { data?: { viewer?: Record<string, { nodes?: unknown[] }> } }).data?.viewer;
  if (!viewer) throw new Error('unexpected GraphQL reply');
  const out: Pr[] = [];
  for (const node of [...(viewer.open?.nodes ?? []), ...(viewer.closed?.nodes ?? [])]) {
    if (!isPlainObject(node)) continue;
    const n = node as any;
    const threads: { isResolved: boolean }[] | undefined = n.reviewThreads?.nodes;
    out.push({
      number: n.number, title: n.title, url: n.url, state: n.state, branch: n.headRefName,
      repo: n.repository?.nameWithOwner ?? '',
      reviewDecision: n.reviewDecision || null,
      checks: n.commits?.nodes?.[0]?.commit?.statusCheckRollup?.state ?? null,
      unresolved: threads ? threads.filter((t) => !t.isResolved).length : null,
      updatedAt: Date.parse(n.updatedAt) || 0,
    });
  }
  return out;
}

/**
 * What changed between two fetches that the user would want to hear about. A PR seen for the first
 * time reports its standing problems as signals only (`nudge: false`), so a first run or a restart
 * does not open with a burst of toasts.
 */
export function diffPrs(prev: Pr[], next: Pr[]): PrEvent[] {
  const before = new Map(prev.map((p) => [p.url, p]));
  const events: PrEvent[] = [];
  for (const pr of next) {
    const old = before.get(pr.url);
    const nudge = !!old;
    const add = (kind: PrEvent['kind'], title: string, toast = nudge) => events.push({ kind, pr, title, nudge: toast });
    const label = `PR #${pr.number}`;
    if (pr.state !== 'OPEN') {
      if (old?.state === 'OPEN') add(pr.state === 'MERGED' ? 'merged' : 'closed', `${label} ${pr.state.toLowerCase()}`, pr.state === 'MERGED');
      continue;
    }
    if (pr.reviewDecision === 'CHANGES_REQUESTED' && old?.reviewDecision !== 'CHANGES_REQUESTED') add('changes_requested', `Changes requested on ${label}`);
    if (pr.reviewDecision === 'APPROVED' && old && old.reviewDecision !== 'APPROVED') add('approved', `${label} approved`);
    if (failed(pr.checks) && !failed(old?.checks ?? null)) add('checks_failed', `Checks failed on ${label}`);
    const fresh = (pr.unresolved ?? 0) - (old?.unresolved ?? 0);
    if (fresh > 0) add('threads', `${fresh} unresolved review thread${fresh === 1 ? '' : 's'} on ${label}`);
  }
  return events;
}

/** The PR for a session's branch: open ones first, and the same repository name when several share a branch. */
export function prFor(prs: Pr[], branch: string | null, repo: string | null): Pr | null {
  if (!branch || DEFAULT_BRANCHES.has(branch)) return null;
  const hits = prs.filter((p) => p.branch === branch).sort((a, b) => Number(b.state === 'OPEN') - Number(a.state === 'OPEN'));
  return hits.find((p) => repo && p.repo.split('/').pop() === repo) ?? hits[0] ?? null;
}

export function createPrCollector(ctx: AppContext) {
  const { repos } = ctx;
  const log = ctx.log.child('prs');
  const branches = new Map<Id, string | null>();
  let snapshot = repos.kv.get<PrSnapshot>('prs') ?? { at: 0, items: [] };
  let retryAt = 0;
  let fetching = false;
  let soon: NodeJS.Timeout | null = null;

  function attach(): void {
    for (const s of repos.sessions.list()) {
      const pr = prFor(snapshot.items, s.branch, s.repo);
      repos.sessions.upsert({ id: s.id, pr: pr && { number: pr.number, url: pr.url, state: pr.state, reviewDecision: pr.reviewDecision, checks: pr.checks, unresolved: pr.unresolved } });
    }
  }

  function report(events: PrEvent[]): void {
    const signals: SignalInput[] = events.map(({ kind, pr, title }) => ({
      source: 'git', kind: `pr.${kind}`, externalId: `${pr.url}#${kind}:${pr.updatedAt}`, title: `${title}: ${pr.title}`,
      body: `${pr.repo} ${pr.branch}`, url: pr.url, occurredAt: pr.updatedAt || Date.now(),
      payload: { number: pr.number, repo: pr.repo, branch: pr.branch, reviewDecision: pr.reviewDecision, checks: pr.checks, unresolved: pr.unresolved },
    }));
    const fresh = new Set(repos.signals.ingest(signals).map((s) => s.externalId));
    const sessions = repos.sessions.list();
    for (const { kind, pr, title, nudge } of events) {
      if (!nudge || !fresh.has(`${pr.url}#${kind}:${pr.updatedAt}`)) continue;
      const session = sessions.find((s) => s.branch === pr.branch);
      const actions: NudgeAction[] = [{ id: 'open', label: 'Open PR', kind: 'open_url', url: pr.url }];
      if (session) actions.push({ id: 'focus', label: 'Go to session', kind: 'focus_session', sessionId: session.id });
      notify(ctx, { kind: 'insight', title, body: pr.title, priority: kind === 'merged' ? 0 : 1, actions, dedupeKey: `pr:${pr.url}:${kind}:${pr.updatedAt}` });
    }
  }

  async function refresh(): Promise<void> {
    const conf = connector(ctx, 'github');
    if (fetching || !conf.enabled || Date.now() < retryAt) return;
    fetching = true;
    try {
      const gh = await resolveBin('gh', settings(ctx).code.ghBin);
      const res = gh ? await run(gh, ['api', 'graphql', '-f', `query=${QUERY}`], { timeoutMs: 30_000 }) : null;
      if (!res || res.code !== 0) {
        // No gh, or not logged in: say so through health and stay out of the way for a while.
        const loggedOut = !res || /auth login|not logged in|authentication/i.test(res.stderr);
        repos.health.set('github', loggedOut ? 'off' : 'error');
        retryAt = Date.now() + (loggedOut ? 30 : 5) * MIN;
        log.debug('gh unavailable', res?.stderr.slice(0, 200) ?? 'gh not found');
        return;
      }
      const items = parsePrs(res.stdout);
      report(diffPrs(snapshot.items, items));
      snapshot = { at: Date.now(), items };
      repos.kv.set('prs', snapshot);
      repos.health.synced('github');
      attach();
    } catch (err) {
      repos.health.set('github', 'error');
      log.warn('refresh failed', err);
    } finally {
      fetching = false;
    }
  }

  // PRs only move while work is happening: skip the network when it is not work time and no session is live.
  const tick = (): void => {
    if (ctx.scheduler.isWorkHours() || repos.sessions.list().some((s) => s.state !== 'idle')) void refresh();
  };

  const off = ctx.bus.on('session.updated', (s) => {
    if (branches.get(s.id) === s.branch) return;
    branches.set(s.id, s.branch);
    if (s.state === 'ended') {
      branches.delete(s.id);
      return;
    }
    const pr = prFor(snapshot.items, s.branch, s.repo);
    // Deferred: writing the session again from inside its own update event would nest the two writes.
    if (pr || s.pr) setImmediate(attach);
    // A branch we know no PR for may have just been pushed; look once the burst of updates settles.
    if (!pr && s.branch && Date.now() - snapshot.at > MIN) soon ??= setTimeout(() => { soon = null; void refresh(); }, 20_000).unref();
  });
  const timer = setInterval(tick, Math.max(1, connector(ctx, 'github').everyMin ?? 5) * MIN);
  timer.unref();

  return {
    refresh,
    stop() {
      clearInterval(timer);
      if (soon) clearTimeout(soon);
      off();
    },
  };
}
