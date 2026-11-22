import type { Entity } from '../core/bus.js';
import type { Paths } from '../core/paths.js';
import { DAY } from '../core/util.js';
import { createActivity } from './activity.js';
import { createApprovals } from './approvals.js';
import { createChat } from './chat.js';
import type { Deps } from './crud.js';
import { createMeetings } from './meetings.js';
import { createMemory } from './memory.js';
import { createNudges } from './nudges.js';
import { createProjects } from './projects.js';
import { rankInputs } from './ranking.js';
import { createContexts, createHealth, createKv, createNotes, createPeople, createSignals } from './records.js';
import { createSessions } from './sessions.js';
import { createSuggestions } from './suggestions.js';
import { createTasks } from './tasks.js';

// A task's score reads these, so a change to any of them can move the ranking.
const RANK_INPUTS: ReadonlySet<Entity> = new Set(['projects', 'initiatives', 'sessions', 'meetings']);

export function createRepos(deps: Deps, paths: Paths) {
  const { projects, initiatives } = createProjects(deps);
  const sessions = createSessions(deps);
  const meetings = createMeetings(deps);
  const tasks = createTasks(deps, (now) =>
    rankInputs({ projects: projects.list(), initiatives: initiatives.list(), sessions: sessions.list(), meetings: meetings.list(now, now + DAY) }));
  const nudges = createNudges(deps);
  const chat = createChat(deps);
  const kv = createKv(deps);

  deps.bus.on('state.changed', ({ entities }) => {
    if (entities.some((e) => RANK_INPUTS.has(e))) tasks.rerank();
  });

  return {
    tasks, projects, initiatives, sessions, meetings, nudges, chat, kv,
    suggestions: createSuggestions(deps, tasks),
    approvals: createApprovals(deps, nudges, chat),
    notes: createNotes(deps),
    people: createPeople(deps),
    signals: createSignals(deps),
    contexts: createContexts(deps),
    activity: createActivity(deps, tasks),
    memory: createMemory(paths.memoryDir),
    health: createHealth(kv),
  };
}

export type Repos = ReturnType<typeof createRepos>;
