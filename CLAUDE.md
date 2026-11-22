# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Steward is a native macOS personal assistant: it keeps one person's tasks, projects and initiatives
ranked, watches their work (coding-agent sessions, chat, meetings, tickets, calendar), proposes what to do
next, and runs a local agent. Two processes: a Swift app (`app/`) and a Node daemon, "the brain" (`brain/`).

## Commands

There is no Xcode project. Everything builds with Command Line Tools (`swift build`) and pnpm.

```sh
scripts/build.sh                 # brain (pnpm install + tsc) + app (release) + bundle + codesign -> build/Steward.app
scripts/build.sh --debug         # debug Swift build;  --skip-brain to leave brain/dist alone
scripts/run.sh                   # build if needed, then open the bundle
scripts/dev.sh                   # brain in watch mode + `swift run` (no bundle: no permissions, notifications or relaunch)
scripts/make-signing-identity.sh # once: a local signing identity so macOS keeps privacy grants across rebuilds

cd brain && pnpm build           # tsc -> brain/dist
cd brain && pnpm test            # tsc + node:test over dist/test/*.test.js (temp data dir, agent disabled)
cd brain && pnpm build && node --test dist/test/guard.test.js               # one test file
cd brain && pnpm build && node --test --test-name-pattern "ranking" dist/test/*.test.js

scripts/test.sh                  # Swift tests (plain `swift test` cannot find Swift Testing without Xcode)
scripts/test.sh --filter AmbientTests

brain/bin/steward state          # poke a running brain: state | tasks | add "<title>" | done <id> | events | raw <METHOD> <path> [json]
```

Offscreen UI snapshots (screen capture is not needed):
`STEWARD_SNAPSHOT_SAMPLE=1 STEWARD_SNAPSHOT_DIR=<dir> app/.build/debug/Steward` renders every main-window
screen against an in-process sample brain and exits; add `STEWARD_SNAPSHOT_AMBIENT=1` for the notch, toasts,
capture, voice and HUD states. Look at the PNGs after any UI change.

Environment overrides: `STEWARD_HOME` (data dir; always set a temp one when testing), `STEWARD_REPO`,
`STEWARD_NODE`, `STEWARD_NO_BRAIN=1`, `STEWARD_AGENT=off`, `STEWARD_LOG_LEVEL`.

## Rules that are easy to break

- **Nothing personal in the repo.** The repo is meant to be public. All user data lives in
  `~/Library/Application Support/Steward/` (config, secrets, SQLite, agent memory, logs). Tracked files must
  not name the owner, an employer, products, colleagues, repos or channels; fixtures use invented data
  ("Acme", "ENG-123"). Ticket patterns, repo roots, work hours and app lists are config, never constants.
- **No external writes without approval.** The agent may read anything, but anything another person or
  service can see (chat, tickets, docs, mail, calendar, `git push`, `gh` writes, non-GET HTTP off-host) goes
  through the approval queue and runs only after the user approves that exact payload. This is enforced in
  code, not in prompts, in `brain/src/agent/`:
  - `guard.ts` gives every tool call one of three verdicts. `allow`: for Bash this means "outside the
    sandbox", and only an allowlist of literal network reads gets it (`gh` reads, `git fetch/pull/ls-remote/
    clone`, `curl`/`wget` GET, optionally piped through a few text filters). `deny`: a recognised external
    write (approvable) or something never allowed. `sandbox`: every other shell command. The deny rules are
    there for clear messages; what keeps an unrecognised command harmless is the sandbox, so never "fix" a
    false sandbox verdict by widening `allow` without thinking about what the binary can be made to run.
  - `sandbox.ts` configures Claude Code's Seatbelt sandbox for the agent's Bash (no network including
    loopback, writes only in the repo and data dir, protected paths denied, secrets unreadable) and the
    profile approved commands run under (network allowed, protected paths and secrets still denied).
  - `engine.ts` installs the PreToolUse hook on every run including subagents and bridge runs, sets the
    sandbox flag on each Bash call from the guard's verdict (never from the model's), and answers Claude
    Code's own permission requests through `canUseTool`, which refuses by default.
  - `boundary.ts` is the list of protected paths; `executor.ts` runs approved actions and re-validates
    edited ones; `self.ts` + `selfgate.ts` gate self-rebuilds on the diff since `refs/steward/built`
    (written by `scripts/build.sh`; `config.agent.selfModify: "ask"` gates every change).
  Those files, their tests, `brain/src/domain/approvals.ts`, `brain/src/approvals-api.ts`, `brain/dist/`,
  `brain/node_modules/`, `brain/bin/`, `scripts/`, `build/`, `.git/` and this file are protected from the
  app's own agent: change them by hand, build with `scripts/build.sh` (which records the new baseline), and
  extend `brain/src/test/guard.test.ts` in the same change. Background runs (`AgentRuntime.run`) get
  read-only built-ins and no shell. Approval surfaces render `ApprovalPayload` (the literal input) and
  nothing agent-written in its place.
- **Never steal keyboard focus** except from the user's own hotkey or click. Ambient panels are
  non-activating; `showMainWindow` is only called from a user action.
- **Token thrift.** Collectors are local and deterministic; LLM calls happen on deltas, in batches, on the
  fast model, and every call is written to the cost ledger (`ctx.cost`). Background jobs stop at the budget cap.
- AppKit refuses ⌘Q while a SwiftUI `.sheet` is up: use in-window overlays or inspectors, not sheets.

## Architecture

```
Steward.app (Swift)  ── spawns ──>  brain (node brain/dist/main.js)
   AppStore  <── REST + SSE on 127.0.0.1, bearer token from the data dir ──  api.ts
```

**The brain owns all state.** It is the only process that opens the SQLite database. The app holds no
durable state beyond window positions; it renders a `StateSnapshot` (`GET /state`) plus slices, and refetches
when an SSE `state.changed { entities }` arrives. `brain/src/core/types.ts` is the source of truth for the
data model; `app/Sources/StewardKit/Models/` mirrors it (Swift names `TaskItem` and `TaskLink` avoid
collisions; timestamps are epoch milliseconds on the wire, `Date` in Swift; decoding is lenient so one bad
element never drops a list). A change to a type or route touches: `types.ts`, a migration, the domain
repo, `api.ts`, the Swift model, `BrainClient`, and `AppStore`.

**Brain layers** (`brain/src`):
- `core/` — paths, config (defaults deep-merged with `config.json`), db + numbered migrations, typed bus,
  router, SSE bridge, cost ledger, scheduler, and `context.ts`, which defines `AppContext` and the
  `AgentRuntime` seam that everything else plugs into.
- `domain/` — repositories; every mutation emits `state.changed`. `ranking.ts` computes each task's 0..100
  score with human-readable reasons (priority, due, project/initiative weight, a linked session waiting, a
  meeting starting soon). `state.ts` builds the snapshot.
- `agent/` — the only place that calls a model. `engine.ts` wraps the Claude Agent SDK `query()` with a lean
  configuration; `quick.ts` is the cheap one-shot path; `tools.ts` is the in-process MCP server (`steward`)
  that exposes the app to the agent; `chat.ts` handles threads, resume and streaming; `self.ts` snapshots,
  rebuilds and restores the app when the agent edits its own source. `guard.ts`, `boundary.ts`, `sandbox.ts`,
  `executor.ts` and `selfgate.ts` are the safety boundary (see the rule above).
- `collectors/` — local, free, no LLM: coding-agent sessions (session files + transcript tails), PR state via
  `gh`, Dock badges (a badge rise triggers an early sync instead of blind polling), browser history,
  messages, activity enrichment.
- `jobs/` — scheduled work: connector syncs (agent runs that emit `Signal` rows), triage (signals →
  `Suggestion`s the user accepts or dismisses), nudges, briefs, meeting prep, memory digest, onboarding scan.

**Two credentials that cannot mix in one run.** The machine's Claude Code login reaches the remote
connectors (chat, meetings, tickets, docs, calendar); an optional `ANTHROPIC_API_KEY` in `secrets.env` does
not. `engine.ts` picks per run; with `agent.billing: "api"` the chat agent reaches connectors through a
bridge that performs single reads on the login. Keep `"ToolSearch"` in the SDK `tools` list — dropping it
loads every connector schema up front.

**App layers** (`app/Sources`):
- `StewardKit/` — models, `BrainClient` (REST + SSE with reconnect), `AppStore` (the one `@Observable` store
  the UI reads; intents live here), pure logic (`Logic/`), and the design system (`Design/`: tokens, named
  springs, haptics, elevation, materials, shared components). Feel constants for the ambient surfaces are in
  `Design/AmbientFeel.swift`.
- `Steward/` — `BrainSupervisor` (spawn, health, restart, relaunch after a self-rebuild), `Surfaces/` (one
  folder per ambient surface behind the `Surface` protocol, registered in `SurfaceRegistry.swift`: notch
  island, toasts, quick capture, voice, HUD), `MainWindow/` (routes in `Routes.swift`, one self-contained
  file group per screen under `Screens/`), `Hotkeys/` (Carbon, no Accessibility needed), `Sensors/`,
  `Permissions/`.

Adding a surface: implement `Surface` in its folder and list it in `SurfaceRegistry.all`. Adding a screen:
a case in `Routes.swift` plus a file under `MainWindow/Screens/`. Adding an agent tool: `tools.ts`, then
decide in `guard.ts` terms whether it can cause an external effect.
