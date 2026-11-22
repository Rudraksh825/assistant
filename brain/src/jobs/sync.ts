import { badgeQuiet } from '../collectors/badges.js';
import { connector, setHealth, settings } from '../collectors/settings.js';
import type { AppContext } from '../core/context.js';
import type { Ms } from '../core/types.js';
import { DAY, MIN } from '../core/util.js';
import { failed, loadAttempts, MAX_BACKOFF, type Attempts } from './attempts.js';
import { kickTriage } from './triage.js';

interface Family {
  goal: string;
  what: string;
  ids: string;
  tools: string[];
  /** How far back the first sync looks, and the most any sync looks back after a long gap. */
  firstMs: number;
  maxMs: number;
}

export const FAMILIES: Record<string, Family> = {
  chat: {
    goal: 'bring in what the user needs to know from team chat',
    what: 'Direct messages to the user, messages that mention the user, new replies in threads the user took part in, and messages that read as a request to the user or a commitment the user made ("can you", "I will", a deadline). Skip bots, joins, reactions and channel chatter that involves the user in no way. Also the user\'s own messages in the window that promise something to someone ("I\'ll …", "will do", "let me get back to you", "I can take that"): at most ten, each as kind "commitment", with the user\'s exact words as the body and the person or channel it was said to as actor. Leave out a promise the same thread shows was kept.',
    ids: '"<channel id>:<message timestamp>"',
    tools: ['signals_emit', 'person_upsert'],
    firstMs: DAY, maxMs: 3 * DAY,
  },
  calendar: {
    goal: "keep the user's meetings for today and tomorrow current",
    what: 'Every event today and tomorrow (the window below) that the user has not declined: title, start and end, every attendee by name, the video join link (from the conferencing data, location or description) and location. Skip all-day markers such as holidays or working-location entries. Leave out events the user declined and events that are cancelled. When you have listed every remaining event of the window, pass the window itself (its two times, as given below) as `window` in the same meetings_upsert call: events stored earlier that are no longer in your list are then marked cancelled. If you could not read the whole window, leave `window` out.',
    ids: 'the calendar event id (for a recurring event, the id of that occurrence)',
    tools: ['meetings_upsert', 'person_upsert'],
    firstMs: 0, maxMs: 0,
  },
  tickets: {
    goal: "track the user's issues",
    what: 'Issues assigned to the user that were created or changed in the window: status changes, new comments by others, priority or due-date changes, new assignments. One signal per change, with kind "assigned", "comment", "status" or "changed". Title: the issue key, the issue title, then what changed, e.g. "ENG-123 Fix login redirect: In Progress → In Review".',
    ids: '"<issue key>:<change or comment id, or the updated timestamp>"',
    tools: ['signals_emit', 'person_upsert'],
    firstMs: 14 * DAY, maxMs: 14 * DAY,
  },
  meetings: {
    goal: 'bring in what was said and agreed in recorded meetings',
    what: 'Recordings in the window that the user attended: one meetings_upsert call for all of them, each with source "meeting", the title, the real start and end as full date-times taken from the recording (its start or created time; a date alone is not enough and is stored as "time unknown"), attendees, recording url, a summary of at most 500 characters and the action items, each written as "<owner name>: <action>". For every action item owed to the user by someone else, also emit one signal of kind "action_item"; for every action item the user owns, one of kind "commitment" with the item as the body and the meeting title as actor. Give each its own externalId: the recording id, a colon, and the position of the item. When several recordings are of the same meeting (same title and start, different recorders), keep the one with the fullest summary and skip the others.',
    ids: 'the recording id',
    tools: ['meetings_upsert', 'signals_emit', 'person_upsert'],
    firstMs: 14 * DAY, maxMs: 14 * DAY,
  },
  docs: {
    goal: 'notice documents that need the user',
    what: 'Documents where the user was mentioned or assigned a comment in the window, and documents shared with the user. Not documents the user merely edited.',
    ids: '"<document id>:<comment id or the updated timestamp>"',
    tools: ['signals_emit'],
    firstMs: 7 * DAY, maxMs: 7 * DAY,
  },
};

const NO_TOOLS = 'NO_TOOLS';
// With a live Dock badge to watch, a scheduled sync may sit out this many periods before it looks anyway.
const QUIET_PERIODS = 8;
const utc = (ms: Ms): string => new Date(ms).toISOString().slice(0, 19) + 'Z';

export function syncPrompt(ctx: AppContext, name: string, since: Ms, now: Ms): string {
  const f = FAMILIES[name]!;
  const user = settings(ctx).user.name;
  const tomorrowEnd = new Date(now);
  tomorrowEnd.setHours(24 + 24, 0, 0, 0);
  const window = name === 'calendar'
    ? `${utc(new Date(now).setHours(0, 0, 0, 0))} to ${utc(tomorrowEnd.getTime())}, which is today and tomorrow for the user`
    : `${utc(since)} to ${utc(now)} (everything before it was already synced)`;
  return [
    `You are the ${name} sync of a personal assistant. Goal: ${f.goal}.`,
    user ? `The user is ${user}. When the connector has a "who am I" or profile tool, call it once: the account it names is the user's, and "their own messages" means messages sent from it.` : 'Find out who the user is from the connector itself (a "who am I" or profile tool).',
    `Window: ${window}. The user's time zone is ${ctx.config.get().user.timezone || Intl.DateTimeFormat().resolvedOptions().timeZone}.`,
    `Tools: find the read-only ${name} tools yourself among the connected servers; their names likely contain one of: ${connector<{ servers?: string[] }>(ctx, name).servers?.join(', ') || name}. If no such tool is available, reply exactly ${NO_TOOLS} and stop. Never write to any external service.`,
    `Pull: ${f.what}`,
    `Report only through ${f.tools.join(' / ')}; say nothing else about what you found. Give every item a stable externalId: ${f.ids}. Use source "${name === 'tickets' ? 'ticket' : name === 'meetings' ? 'meeting' : name === 'docs' ? 'doc' : name}", times as ISO 8601 exactly as the connector gives them (keep the offset or Z), the item's url, and the other person's name as actor. Call person_upsert only for people not seen before, with their handle.`,
    'Limits: at most 40 items, most recent first; bodies at most 500 characters of plain text. Send everything you found in ONE call of the reporting tool (it takes a list), not one call per item.',
    'End with one line: "<n> items".',
  ].join('\n');
}

/**
 * One connector sync. Skips quietly when the family is off or no agent is installed, and for scheduled
 * runs while backing off after a failure or while the family's Dock badge shows nothing new.
 */
export async function runSync(ctx: AppContext, name: string, trigger: 'schedule' | 'manual', now: Ms = Date.now()): Promise<'ok' | 'skipped'> {
  const conf = connector(ctx, name);
  const family = FAMILIES[name]!;
  const everyMin = conf.everyMin ?? 30;
  if (!conf.enabled) {
    setHealth(ctx, name, 'off');
    return 'skipped';
  }
  if (!ctx.agent.available()) return 'skipped';
  const key = `sync:${name}`;
  const st = loadAttempts(ctx, key);
  if (trigger === 'schedule') {
    if (now < st.retryAt) return 'skipped';
    if (st.okAt && now - st.okAt < QUIET_PERIODS * everyMin * MIN && badgeQuiet(ctx, name, st.okAt, now)) return 'skipped';
  }
  // Nothing connected for this family: not an error, and not worth asking again soon.
  const unconnected = (): 'skipped' => {
    setHealth(ctx, name, 'off');
    ctx.repos.kv.set(key, { ...st, retryAt: now + MAX_BACKOFF, error: 'no connector available' });
    return 'skipped';
  };
  try {
    const res = await ctx.agent.run({
      kind: key, model: 'fast', trigger: trigger === 'manual' ? 'event' : 'schedule', prompt: syncPrompt(ctx, name, Math.max(st.cursor ?? now - family.firstMs, now - family.maxMs), now),
      connectors: connector<{ servers?: string[] }>(ctx, name).servers ?? 'all', stewardTools: family.tools, maxTurns: 12,
    });
    if (!res.ok) throw new Error(res.text.slice(0, 300) || 'run failed');
    if (res.text.includes(NO_TOOLS)) return unconnected();
    // Two minutes of overlap: items are deduplicated by externalId, a gap would lose them.
    ctx.repos.kv.set(key, { cursor: now - 2 * MIN, okAt: now, failures: 0, retryAt: 0, error: null } satisfies Attempts);
    ctx.repos.health.synced(name, now);
  } catch (err) {
    if ((err as { code?: string }).code === 'connector_unavailable') return unconnected();
    failed(ctx, key, st, everyMin, err, now);
    setHealth(ctx, name, 'error');
    throw err;
  }
  // Fresh signals should not wait for triage's own timer.
  kickTriage(ctx);
  return 'ok';
}

export function registerSyncs(ctx: AppContext): void {
  for (const name of Object.keys(FAMILIES)) {
    ctx.scheduler.register({
      name: `sync:${name}`,
      schedule: { everyMin: Math.max(1, connector(ctx, name).everyMin ?? 30) },
      workHoursOnly: true,
      spends: true,
      run: async (trigger) => void (await runSync(ctx, name, trigger)),
    });
  }
}
