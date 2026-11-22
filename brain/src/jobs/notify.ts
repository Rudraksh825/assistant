import type { AppContext } from '../core/context.js';
import type { Ms, Nudge } from '../core/types.js';
import { MIN } from '../core/util.js';
import { settings } from '../collectors/settings.js';
import type { NudgeInput } from '../domain/nudges.js';

const minutes = (hhmm: string): number => {
  const [h, m] = hhmm.split(':').map(Number);
  return (h ?? 0) * 60 + (m ?? 0);
};

/** Quiet hours may wrap past midnight ("22:00" to "07:00"). */
export function inQuietHours(quiet: { start: string; end: string } | null, now: Ms): boolean {
  if (!quiet) return false;
  const d = new Date(now);
  const at = d.getHours() * 60 + d.getMinutes();
  const start = minutes(quiet.start);
  const end = minutes(quiet.end);
  return start <= end ? at >= start && at < end : at >= start || at < end;
}

/**
 * The one door for collector and job nudges. During quiet hours, or once `nudges.maxPer10Min`
 * interrupting nudges went out in the last ten minutes, the nudge is still recorded but as priority 0
 * (notch only). `urgent` skips the rate limit, for things that cannot wait their turn (a meeting starting).
 */
export function notify(ctx: AppContext, input: NudgeInput & { urgent?: boolean }, now: Ms = Date.now()): Nudge {
  const { urgent, ...nudge } = input;
  const conf = settings(ctx).nudges;
  if ((nudge.priority ?? 0) > 0) {
    const recent = () => (ctx.db.prepare('SELECT COUNT(*) AS n FROM nudges WHERE priority >= 1 AND createdAt > ?').get(now - 10 * MIN) as { n: number }).n;
    if (inQuietHours(conf.quietHours, now) || (!urgent && recent() >= conf.maxPer10Min)) nudge.priority = 0;
  }
  return ctx.repos.nudges.create(nudge);
}
