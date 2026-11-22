// The data model. This file is the source of truth; the Swift models mirror it.

export type Id = string;
export type Ms = number;

export type TaskStatus = 'inbox' | 'todo' | 'doing' | 'waiting' | 'done' | 'dropped';
export interface Task {
  id: Id; title: string; notes: string;
  status: TaskStatus;
  priority: 0 | 1 | 2 | 3;            // 0 none, 1 low, 2 high, 3 urgent
  projectId: Id | null; parentId: Id | null;
  dueAt: Ms | null; scheduledFor: Ms | null; snoozedUntil: Ms | null;
  estimateMin: number | null;
  pinned: boolean;                     // user says "this is the one"
  manualRank: number | null;           // user drag order inside a list; null = by score
  score: number;                       // computed 0..100
  scoreReasons: string[];              // short human strings: "due today", "session waiting 12m"
  waitingOn: string | null;            // person or thing
  people: string[]; tags: string[];
  links: Link[];                       // tickets, PRs, threads, docs, meetings, sessions
  source: SourceKind; sourceRef: string | null;   // where it came from
  createdAt: Ms; updatedAt: Ms; completedAt: Ms | null;
  startedAt: Ms | null;                // when it last became `doing`; null while it is anything else
}
export interface Link { kind: 'ticket'|'pr'|'thread'|'doc'|'meeting'|'session'|'url'|'file'; title: string; url: string; ref?: string }
export type SourceKind = 'manual'|'capture'|'agent'|'claude'|'chat'|'meeting'|'ticket'|'doc'|'calendar'|'message'|'browser'|'git';

export interface Project    { id: Id; initiativeId: Id | null; title: string; notes: string; status: 'active'|'paused'|'done'|'dropped'; color: string | null; weight: number /*0..3*/; createdAt: Ms; updatedAt: Ms }
export interface Initiative { id: Id; title: string; notes: string; status: 'active'|'paused'|'done'|'dropped'; weight: number /*0..3*/; horizon: string | null; createdAt: Ms; updatedAt: Ms }

// What the agent/collectors propose; the user accepts or dismisses in the Inbox.
export interface Suggestion {
  id: Id;
  kind: 'new_task'|'update_task'|'complete_task'|'followup'|'link'|'insight'|'question';
  title: string; rationale: string;
  payload: Record<string, unknown>;     // e.g. Partial<Task> for new_task; {taskId, patch} for update_task; {question, options} for question; a followup the user promised carries commitment {quote, to, madeAt}
  source: SourceKind; sourceRef: string | null; sourceUrl: string | null;
  confidence: number;                   // 0..1
  status: 'pending'|'accepted'|'dismissed';
  createdAt: Ms; decidedAt: Ms | null;
}

// Raw normalized events from collectors. UNIQUE(source, externalId).
export interface Signal { id: Id; source: SourceKind; kind: string; externalId: string; title: string; body: string; url: string | null; actor: string | null; occurredAt: Ms; payload: Record<string, unknown>; triage: 'new'|'ignored'|'suggested'|'linked'; processedAt: Ms | null }

// One Claude Code session (interactive terminal agent) on this machine.
export interface CodeSession {
  id: Id;                               // the session id
  pid: number | null; name: string | null;
  cwd: string; repo: string | null; branch: string | null; ticket: string | null;
  state: 'working'|'waiting'|'blocked'|'idle'|'ended';   // waiting = finished, needs next prompt; blocked = permission/question
  stateSince: Ms;
  title: string | null;                 // short summary of what it is doing
  lastUserPrompt: string | null; lastAssistantText: string | null;
  pr: { number: number; url: string; state: string; reviewDecision: string | null; checks: string | null; unresolved: number | null } | null;
  taskId: Id | null;
  notes: string;                        // the owner's own notes on the session; never written by a collector
  startedAt: Ms; updatedAt: Ms;
}

// One entry of a session's conversation tail. `tools` is a burst of tool calls folded into one line ("Read ×3 · Bash").
export interface SessionTurn { role: 'user'|'assistant'|'tools'; at: Ms | null; text: string }
export interface SessionTurns { items: SessionTurn[]; from: 'transcript'|'summary'|'none'; truncated: boolean }
export interface SessionPlace { session: CodeSession; task: Task | null; ticketUrl: string | null; recap: { text: string; at: Ms } | null }

// Where a task or suggestion came from, as stored locally: the signal, session, meeting or capture behind it.
export interface Origin {
  source: SourceKind; kind: string;
  title: string; body: string;
  actor: string | null; at: Ms | null;
  url: string | null;
  signalId: Id | null; sessionId: Id | null; meetingId: Id | null; noteId: Id | null;
}

// What "See more" fetched around an item's source, and the reply drafted for it. One row per subject, kept until refreshed.
export interface ItemContext {
  id: Id;
  subject: string;                      // "src:<source>:<sourceRef>" when a signal is behind the item (a suggestion and its task then share it), else "task:<id>" / "suggestion:<id>"
  status: 'running'|'ok'|'failed'|null; // the context fetch; null = never asked
  body: string;                         // compact markdown: asked, by whom, said or decided, still open, links
  error: string | null; fetchedAt: Ms | null; costUsd: number;
  draftStatus: 'running'|'ok'|'failed'|null;
  draft: string | null;                 // the reply text, also when no approval could be filed
  draftApprovalId: Id | null;           // the pending Approval holding the exact tool and input
  draftNote: string | null;             // the brain's words on what happened to the draft
  draftAt: Ms | null;
  createdAt: Ms; updatedAt: Ms;
}

export interface RelatedItems {
  tasks: { task: Task; why: string }[];
  suggestions: { suggestion: Suggestion; why: string }[];
  sessions: { session: CodeSession; why: string }[];
  meetings: { meeting: Meeting; why: string }[];
}

export interface TaskPlace {
  task: Task; origins: Origin[]; context: ItemContext | null; related: RelatedItems;
  sessions: CodeSession[];              // linked, ended ones included
  seeMoreVia: string | null;            // connector family "See more" would read; null = nothing to fetch for this source
  replyVia: string | null;              // connector family a reply would go through; null = no thread to reply to
}
export interface SuggestionPlace { suggestion: Suggestion; origins: Origin[]; context: ItemContext | null; seeMoreVia: string | null }

// Something promised or started and then left. Computed on request, no model.
export interface LooseEnd {
  id: string;                           // stable: "<kind>:<ref>"
  kind: 'commitment'|'session'|'waiting'|'pr'|'page';
  title: string; reason: string; since: Ms;
  place: { view: string; path: string } | null;   // where it opens inside Steward
  url: string | null;                   // only for an explicit "Open in …"
}
export interface LooseEnds { groups: { kind: LooseEnd['kind']; title: string; items: LooseEnd[] }[]; count: number; at: Ms }

export interface Meeting { id: Id; source: 'calendar'|'meeting'; externalId: string; title: string; startAt: Ms; endAt: Ms; attendees: string[]; joinUrl: string | null; location: string | null; summary: string | null; actionItems: string[]; recordingUrl: string | null; prepNote: string | null;
  prepStatus: 'running' | 'failed' | null; prepError: string | null;   // the prep run for this meeting, while it runs or after it failed
  startKnown: boolean;                 // false: the source gave a day but no time; startAt is that day's 00:00 and must not be shown as a time
  cancelledAt: Ms | null;              // calendar events that left the synced window or were declined; hidden from lists, next and current
  updatedAt: Ms }
export interface Person  { id: Id; name: string; handles: Record<string,string>; notes: string; lastContactAt: Ms | null }
export interface Note    { id: Id; kind: 'live'|'dump'|'meeting'|'journal'|'brief'; title: string; body: string; taskId: Id | null; meetingId: Id | null; pinned: boolean; createdAt: Ms; updatedAt: Ms }

// An action the agent may not take on its own. Executes only after approve. `summary` and `target` are the agent's words;
// `input` is the literal payload that runs; `note` is the brain's own reason for asking (never agent text).
export interface Approval { id: Id; kind: string; summary: string; tool: string; input: Record<string, unknown>; note: string; target: string | null; status: 'pending'|'approved'|'denied'|'executed'|'failed'|'expired'; result: string | null; threadId: Id | null; createdAt: Ms; decidedAt: Ms | null }

// What the notch / notifications show.
export interface Nudge { id: Id; kind: 'session'|'meeting'|'task'|'brief'|'approval'|'question'|'insight'|'budget'|'system'; title: string; body: string; priority: 0|1|2;  // 0 passive (notch only), 1 toast, 2 toast + system notification
  actions: NudgeAction[]; dedupeKey: string | null; createdAt: Ms; expiresAt: Ms | null; dismissedAt: Ms | null }
export interface NudgeAction { id: string; label: string; kind: 'open_url'|'focus_session'|'open_view'|'api'|'dismiss'; url?: string; sessionId?: Id; view?: string; method?: string; path?: string; body?: unknown }

export interface ChatThread  { id: Id; title: string; createdAt: Ms; updatedAt: Ms; agentSessionId: string | null }
export interface ChatMessage { id: Id; threadId: Id; role: 'user'|'assistant'|'tool'|'system'; text: string; tool: { name: string; input: unknown; result?: string; status: 'running'|'ok'|'error'|'denied' } | null;
  costUsd: number | null;              // assistant replies: what the turn cost
  createdAt: Ms }

export interface AgentRun { id: Id; kind: string; trigger: 'user'|'schedule'|'event'; model: string; status: 'running'|'ok'|'error'|'cancelled'; inputTokens: number; outputTokens: number; costUsd: number; billing: 'api'|'login'; summary: string | null; startedAt: Ms; endedAt: Ms | null }
export interface ActivitySpan { id: Id; app: string; bundleId: string | null; title: string | null; startAt: Ms; endAt: Ms; idle: boolean; sessionId: Id | null; taskId: Id | null }

// One cheap call the surfaces poll/refresh from.
export interface StateSnapshot {
  now: Task | null;                     // the task in 'doing' the user is on (most recent / pinned)
  top: Task[];                          // ranked, max 12, excludes done/dropped/snoozed
  sessions: CodeSession[];              // not ended
  nextMeeting: Meeting | null; currentMeeting: Meeting | null;
  counts: { inbox: number; suggestions: number; approvals: number; waiting: number; dueToday: number; overdue: number };
  nudges: Nudge[];                      // active
  liveNote: Note | null;
  budget: { todayUsd: number; dailyCapUsd: number; monthUsd: number; billing: 'api'|'login'|'mixed' };
  agent: { busy: boolean; activity: string | null; available: boolean };   // available false = no agent runtime in this brain
  health: { connectors: Record<string, 'ok'|'error'|'off'|'unknown'>; lastSyncAt: Record<string, Ms> };
  serverTime: Ms;
}
