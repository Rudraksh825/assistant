# Steward brain

The daemon behind the Steward app: it owns the SQLite database, serves the HTTP + SSE API on
`127.0.0.1`, ranks tasks, and hosts the agent, collectors and scheduled jobs.

## Run

Needs Node 24+ and pnpm. No native dependencies (`node:sqlite`, `node:http`, `node:test`).

```sh
pnpm install
pnpm build          # tsc → dist/
pnpm test           # node:test against a temp data dir
pnpm dev            # rebuild + restart on change, standalone
node dist/main.js --standalone
```

The app normally spawns `node dist/main.js` and the brain exits when that parent goes away.
`--standalone` keeps it running on its own.

Poke a running brain with the CLI (it reads the token and port from the data dir):

```sh
bin/steward add "Draft the Acme proposal"
bin/steward tasks
bin/steward done <id>
bin/steward state
bin/steward events                                   # tail the SSE stream
bin/steward raw PATCH /tasks/<id> '{"priority":3}'
```

## Data

Everything personal lives outside the repo, in `~/Library/Application Support/Steward/`
(set `STEWARD_HOME` to use another directory). The directory is created `0700`.

| Path | What |
| --- | --- |
| `config.json` | settings, written with defaults on first run |
| `secrets.env` | `NAME=value` lines, `0600`, never returned by the API |
| `brain.token`, `brain.port` | bearer token (new on every start) and the bound port |
| `steward.db` | SQLite, WAL |
| `memory/` | markdown the agent keeps |
| `logs/brain.log` | rotated at 5 MB to `brain.log.1`; `STEWARD_LOG_LEVEL=debug\|info\|warn\|error\|silent` |
| `agent/`, `checkpoints/` | agent working dir, and scratch space for self-modify snapshots (the snapshots themselves are git refs under `refs/steward/checkpoints/`) |

Every request needs `Authorization: Bearer <brain.token>` except `GET /health`; `/events` also
accepts `?token=`. Errors are `{ "error": { "code", "message" } }`.

## Layout

```
src/core/      paths, config, db + migrations, bus, http, sse, log, cost ledger, scheduler, context (the seams)
src/domain/    repositories, ranking, state snapshot
src/api.ts     every route
src/app.ts     wiring (startBrain), used by main.ts and the tests
src/agent/ src/collectors/ src/jobs/    plug-ins, see below
```

Schema changes go in a new file under `src/core/migrations/`, appended to `migrations/index.ts`.
Column names equal the TypeScript field names; arrays and objects are JSON text.

## Seams

Plug-ins get one object, `AppContext` (`src/core/context.ts`):

```ts
interface AppContext {
  config: ConfigStore;   // get(), update(patch), secret(name)
  paths: Paths;
  db: Db;
  bus: Bus;              // on(type, fn), emit(type, data), changed(...entities)
  log: Log;              // child(scope)
  cost: Cost;            // start / finish / record, totals(), canSpendBackground()
  scheduler: Scheduler;  // register(job), runNow(name), isWorkHours()
  repos: Repos;          // tasks, projects, initiatives, suggestions, signals, sessions, meetings,
                         // people, notes, approvals, nudges, activity, chat, memory, kv, health
  agent: AgentRuntime;
}
```

Three plug-ins hang off it, each behind one entry point:

| Entry point | What it does |
| --- | --- |
| `createAgentRuntime(ctx)` in `src/agent/` | The agent: chat, capture parsing, session recaps, meeting prep, approvals, self-modify. Runs on the Claude Agent SDK (`engine.ts`), exposes the app to the model as the in-process `steward` tool server (`tools.ts`), and passes every tool call through `guard.ts` (reads are free, external writes need an approval) and `boundary.ts` (the agent cannot edit the guard itself). |
| `startCollectors(ctx)` in `src/collectors/` | Local, deterministic watchers with no model calls: Claude Code sessions, open pull requests through `gh`, Dock badges, browser history, iMessage (off by default), and activity-span attribution. |
| `registerJobs(ctx)` in `src/jobs/` | Scheduled work: connector syncs (`sync:chat\|calendar\|tickets\|meetings\|docs`), `triage` (signals to suggestions), briefs, `meeting-prep`, `session-titles`, `memory-digest`, deterministic `nudges`, and the manual `onboarding-scan`. |

Switches for tests and debugging: `STEWARD_AGENT=off` (placeholder runtime, nothing is spent),
`STEWARD_COLLECTORS=off` (no collectors), `STEWARD_HOME=<dir>` (another data dir).
Under `node --test` the agent, the collectors and the jobs all stay off unless a test builds them itself.

Rules of the road:

- **Repos emit for you.** Every repo mutation queues `state.changed` for its entity; bursts collapse
  into one event. Emit other events (`chat.delta`, `agent.activity`, `ui.command`, ...) yourself with `ctx.bus.emit`.
- **The core persists first.** By the time `agent.chat` or `agent.capture` is called, the user message or
  capture note is stored. The runtime adds what it produces (`repos.chat.addMessage`, `repos.tasks.create`,
  `repos.suggestions.create`).
- **Approvals.** `repos.approvals.create(...)` queues the action, emits `approval.requested` and a priority-2
  nudge. On approve the core calls `agent.executeApproval(approval)`, stores executed/failed and posts the
  result to the originating thread.
- **Collectors** call `repos.signals.ingest([...])` (deduped by source + externalId; returns only new ones),
  `repos.sessions.upsert({ id, ... })` (no-op when unchanged), `repos.meetings.upsert(...)`, and report
  reachability with `repos.health.synced('calendar')` / `repos.health.set('chat', 'error')`.
- **Jobs** register with the scheduler; one job never overlaps itself:

  ```ts
  ctx.scheduler.register({
    name: 'triage',
    schedule: { everyMin: 15 },            // or { at: '09:00', days: [1, 2, 3, 4, 5] }
    workHoursOnly: true,
    spends: true,                           // skipped once the budget is spent
    async run() { /* ... */ },
  });
  ```
- **LLM calls go in the ledger.** `const run = ctx.cost.start({ kind, trigger, model, billing })`, then
  `ctx.cost.finish(run.id, { status: 'ok', inputTokens, outputTokens, costUsd })`. Background work checks
  `ctx.cost.canSpendBackground()` first.
- **Nudges.** `repos.nudges.create({ kind, title, body, priority, actions, dedupeKey })`. One nudge per
  `dedupeKey`, ever: include a time bucket in the key (`session:<id>:<stateSince>`) for nudges that may recur.
- **Ranking** is `scoreTask` in `src/domain/ranking.ts`: a pure function of the task, its project and initiative,
  linked sessions and meetings, and the clock. Scores refresh on task writes, when a ranking input changes, and
  every five minutes.
