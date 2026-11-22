import { basename } from 'node:path';
import type { AppContext } from '../core/context.js';
import type { CodeSession, Id } from '../core/types.js';
import { HOUR } from '../core/util.js';
import { settings } from './settings.js';

type Span = { id: Id; app: string; bundleId: string | null; title: string | null; startAt: number };
type SessionRef = Pick<CodeSession, 'id' | 'name' | 'cwd' | 'repo'>;

/**
 * The session a window belongs to, when the frontmost app is an editor or terminal and its title names a
 * folder a session lives in (editor titles end in the workspace folder; terminals show the cwd or the
 * session name). The longest matching name wins; sessions are expected most recent first.
 */
export function matchSession(span: Pick<Span, 'app' | 'bundleId' | 'title'>, sessions: SessionRef[], editors: string[]): Id | null {
  const title = span.title?.toLowerCase();
  if (!title) return null;
  const app = `${span.app} ${span.bundleId ?? ''}`.toLowerCase();
  if (!editors.some((e) => app.includes(e.toLowerCase()))) return null;
  let best: { id: Id; length: number } | null = null;
  for (const s of sessions) {
    // A derived session name is "<launch dir>-<2 hex>": the launch dir is what an editor window shows.
    for (const name of [basename(s.cwd), s.repo, s.name, s.name?.replace(/-[0-9a-f]{2}$/, '')]) {
      if (name && name.length >= 3 && name.length > (best?.length ?? 0) && title.includes(name.toLowerCase())) best = { id: s.id, length: name.length };
    }
  }
  return best?.id ?? null;
}

/** Attributes sensor spans to sessions (and to the session's task, which is more exact than "whatever is in doing"). */
export function createActivityEnricher(ctx: AppContext) {
  let cursor = Date.now() - HOUR;

  function pass(): void {
    const spans = ctx.db.prepare('SELECT id, app, bundleId, title, startAt FROM activity WHERE startAt > ? AND sessionId IS NULL AND idle = 0 ORDER BY startAt').all(cursor) as unknown as Span[];
    if (!spans.length) return;
    cursor = spans.at(-1)!.startAt;
    const sessions = ctx.repos.sessions.list();
    const editors = settings(ctx).code.editorApps;
    const update = ctx.db.prepare('UPDATE activity SET sessionId = ?, taskId = COALESCE(?, taskId) WHERE id = ?');
    for (const span of spans) {
      const id = matchSession(span, sessions, editors);
      if (id) update.run(id, sessions.find((s) => s.id === id)!.taskId, span.id);
    }
  }

  const timer = setInterval(() => {
    try {
      pass();
    } catch (err) {
      ctx.log.child('activity').warn('enrichment failed', err);
    }
  }, 30_000);
  timer.unref();
  return { pass, stop: () => clearInterval(timer) };
}
