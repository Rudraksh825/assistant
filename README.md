# Steward

A native macOS personal assistant for people who run many things at once. It keeps your tasks, projects
and initiatives ranked, watches your work as it happens, proposes what to do next, and gives you a local
agent that can read everything you can and act only when you say so.

Built for one workflow in particular: several coding-agent terminal sessions open at once, most
communication in chat, most context in meeting recordings.

## What it does

- **Session radar.** Every live Claude Code session on the machine: working, finished and waiting for you,
  or blocked on a question; its repo, branch, ticket and pull request; one click to bring that window forward.
- **Ranked tasks.** Initiatives → projects → tasks, each scored with reasons you can read ("due today",
  "session waiting 12m"). Drag to override.
- **Inbox of suggestions.** Chat messages, tickets, meetings and sessions become proposed tasks, follow-ups
  and updates. You accept, edit or dismiss; nothing lands in your list on its own unless you typed it.
- **Briefs and prep.** Morning, evening and weekly briefs; a prep note before meetings; action items after.
- **An agent with reach.** Chat with it, dictate to it, or let it work in the background. It reads your
  connected tools, keeps a memory about you in plain markdown you can edit, and can rewrite this app.
- **Approvals.** Anything another person could see — a message, a ticket edit, a `git push` — waits for
  your approval. The card shows the literal command or tool input that will run, not the agent's
  description of it.

## Surfaces

| Surface | What it is |
| --- | --- |
| Notch island | Lives in the notch (or a pill at the top of displays without one). Session dots and the next meeting at a glance; opens into Now, Next up, Sessions and a capture field. |
| Toasts | Slide out from under the notch: a session finished, a meeting is starting, the agent has a question. |
| Quick capture | A hotkey panel. Enter saves a thought; ⌘Enter asks the agent and streams the answer in place. |
| Voice | Hold a hotkey and talk. Transcription is on-device. |
| HUD | A floating pill or card on any display: current task, timer, live notes. |
| Menu bar | The same compact panel, for when the notch is hidden. |
| Main window | Today, Inbox, Tasks, Projects, Sessions, Meetings, Notes, People, Agent, Activity, Settings. ⌘K for everything. |

Default hotkeys (change them in Settings): capture `⌃⌥Space`, agent `⌃⌥A`, voice `⌃⌥V`, HUD `⌃⌥H`, notch `⌃⌥N`.

## Requirements

- macOS 26 on Apple Silicon
- Swift 6.2+ (Command Line Tools are enough; Xcode is not needed)
- Node 24+ and pnpm
- [Claude Code](https://claude.com/claude-code), logged in. The agent runs on the Claude Agent SDK and uses
  your own login to reach the connectors you have enabled there (chat, calendar, tickets, meetings, docs).
- Optional: an Anthropic API key, and the GitHub CLI (`gh`) for pull request state.

## Install

```sh
git clone <this repo> && cd <repo>
scripts/make-signing-identity.sh   # optional, once: keeps macOS privacy grants across rebuilds
scripts/build.sh
open build/Steward.app
```

The welcome screen walks through the optional permissions, the API key, and a one-time scan that learns
what you are working on (it tells you the estimated cost before it runs).

## Privacy and data

Everything about you stays on your machine, outside this repository, in
`~/Library/Application Support/Steward/`: settings, the SQLite database, the agent's memory files, logs,
and `secrets.env` for the API key. The app talks to its own daemon over `127.0.0.1` with a token that
changes on every start. Model calls go to Anthropic through your Claude login or your API key.

## What the agent can and cannot do

It can read your connected tools, local files and its own source, and write to its database, its memory
and this app's code. It cannot post, send, edit, comment, push or otherwise change anything outside your
machine without an approval card showing the exact action. That boundary is code, not a prompt:

- **Every tool call passes a guard** that fails closed. Connector tools run only when they are reads; a
  write, or a tool whose name proves nothing (`fetch`, `query`, `run`), needs your approval.
- **The agent's shell runs in the macOS sandbox** (Seatbelt, through Claude Code's own sandbox): no network,
  localhost included, and file writes only inside this repository and the data directory. The only commands
  that leave it are network reads written out literally: `gh` read commands, `git fetch` / `pull` /
  `ls-remote` / `clone`, and `curl` GET. Anything else that needs the network fails there, and the agent has
  to ask you. Background work (syncs, briefs, triage, scheduled jobs) gets no shell at all.
- **Some paths are closed to the agent whatever it runs**: the guard, sandbox and approval code and their
  tests, `scripts/`, built output and dependencies, `.git` internals, `CLAUDE.md` and editor or CI
  settings, `~/.claude`, shell startup files, and Steward's own config, secrets, API token and database.
  The sandbox enforces this in the kernel, and a command you approve still runs under those rules.
- **Approval cards show what runs.** The literal input, every field, with control and invisible characters
  spelled out. The notch and toasts only offer Approve when the whole payload fits in view.
- **Rebuilding itself is gated.** When the agent has changed the app's source and asks for a rebuild, a
  change that starts processes, opens connections or touches the safety code waits for your approval;
  Settings → Agent can make every self-made change wait.

What this is not: a proof. An approved command is as powerful as you are. A GET request can still carry
data out or trigger something on a server that treats GET as an action. The self-rebuild check reads the
diff for known patterns, so with "ask when risky" it can miss code written to hide; "always ask" does not
depend on it. Read `brain/src/agent/guard.ts` and `sandbox.ts` before trusting it with more than you would
trust a careful colleague.

## Cost

Background work (syncs, triage, titles) runs on the fast model and costs fractions of a cent per run;
briefs and chat on the main model cost more. Settings shows spend against a daily and monthly cap;
background jobs stop at the cap. Runs on your Claude login count against that plan's limits.

## Development

See [CLAUDE.md](CLAUDE.md) for commands, architecture and the rules that are easy to break.
