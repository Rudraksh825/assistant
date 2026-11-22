import type { Repos } from '../domain/index.js';
import type { Bus } from './bus.js';
import type { ConfigStore } from './config.js';
import type { Cost } from './cost.js';
import type { Db } from './db.js';
import type { Log } from './log.js';
import type { Paths } from './paths.js';
import type { Scheduler } from './scheduler.js';
import type { Approval, Id } from './types.js';

/** Everything a plug-in (agent, collectors, jobs) gets. Built once in app.ts. */
export interface AppContext {
  config: ConfigStore;
  paths: Paths;
  db: Db;
  bus: Bus;
  log: Log;
  cost: Cost;
  scheduler: Scheduler;
  repos: Repos;
  agent: AgentRuntime;
}

/** What the user was looking at when they captured or asked. `source` is the surface: hotkey, voice, notch, hud. */
export interface UiContext {
  app?: string;
  title?: string;
  url?: string;
  sessionId?: Id;
  source?: string;
  [key: string]: unknown;
}

export interface ChatQuestion { threadId: Id; questionId: string; question: string; options?: string[] }

export interface QuickRequest {
  /** Ledger kind, e.g. "triage", "recap", "title". */
  kind: string;
  prompt: string;
  system?: string;
  maxTokens?: number;
  trigger?: 'user' | 'schedule' | 'event';
  /** When set, the reply must be JSON matching this JSON Schema; `quick` returns the JSON text. */
  schema?: Record<string, unknown>;
}

/** A full agent run that jobs and collectors can shape: they own the prompt, the runtime owns the machinery and the guard. */
export interface RunRequest {
  /** Ledger kind, e.g. "sync:chat", "brief:morning", "triage". */
  kind: string;
  prompt: string;
  system?: string;
  model?: 'fast' | 'main';
  trigger?: 'user' | 'schedule' | 'event';
  /** Remote connector servers the run may read: names as the login exposes them, 'all', or 'none' (default). */
  connectors?: string[] | 'all' | 'none';
  /** Steward tools the run may call (names without prefix), or 'all'. Default: none. */
  stewardTools?: string[] | 'all';
  /** Built-in read-only tools: Read, Glob, Grep, WebSearch, WebFetch. Default false. These runs never get a shell or a file-writing tool. */
  builtins?: boolean;
  /**
   * Leave the connectors' write tools in the model's view, so the run can name one (with its input) in `request_approval`.
   * Seeing is all it gets: the guard still refuses to run them. Default false.
   */
  writesVisible?: boolean;
  maxTurns?: number;
}

export interface RunResult {
  runId: Id;
  ok: boolean;
  /** Final assistant text. */
  text: string;
  costUsd: number;
}

/**
 * The seam between the core and the agent. The core persists first (user message, capture note,
 * approval decision) and then calls in; the runtime owns every LLM call and writes each one to `ctx.cost`.
 */
export interface AgentRuntime {
  /**
   * Start a reply to user message `messageId` (already stored). Resolve with the run id as soon as the run
   * is started; stream via `chat.started|delta|tool|question` on the bus, store the assistant message
   * with `repos.chat.addMessage`, then emit `chat.done` or `chat.error`.
   */
  chat(threadId: Id, messageId: Id, text: string, context?: UiContext): Promise<{ runId: Id }>;
  interrupt(threadId: Id): void;
  /** The user's reply to a `chat.question`. */
  answer(questionId: string, answer: string): void;
  /** Questions asked and not answered yet, for a client that connects after the `chat.question` event. */
  questions(): ChatQuestion[];
  /** The thread is being deleted: stop its run and drop its questions. */
  forget(threadId: Id): void;
  /** Turn a brain dump (stored as note `noteId`) into tasks / suggestions and a nudge. Called fire-and-forget. */
  capture(noteId: Id, text: string, context?: UiContext): Promise<void>;
  /**
   * Run exactly `approval.tool` with `approval.input`, once. Only called for an approval the user just approved.
   * The core stores the outcome (executed | failed) and posts `result` into `approval.threadId`.
   */
  executeApproval(approval: Approval): Promise<{ ok: boolean; result: string }>;
  /**
   * Why this payload can never run, or null. Asked before an approval is accepted; `edited` is true when the
   * input is the user's edited version rather than the one the agent queued.
   */
  checkApproval(approval: Pick<Approval, 'tool' | 'input'>, edited?: boolean): string | null;
  /** Recap text for a code session. The core caches it per session until the session changes. */
  recapSession(sessionId: Id): Promise<string>;
  /** Start a prep run; write the outcome with `repos.meetings.update(id, { prepNote })`, and its progress to `prepStatus` / `prepError`. */
  prepMeeting(meetingId: Id, trigger?: 'user' | 'schedule'): Promise<{ runId: Id }>;
  /** Build and relaunch the app without edits. Emit `app.relaunch` on success. */
  rebuildApp(): Promise<{ ok: boolean; log: string; approvalId?: string }>;
  /** One cheap fast-model completion, no tools. Throws when no runtime is installed. */
  quick(req: QuickRequest): Promise<string>;
  /** A tool-using run to completion (sync, triage, briefs). Throws when no runtime is installed or the background budget is spent. */
  run(req: RunRequest): Promise<RunResult>;
  /** False for the placeholder runtime, so jobs can skip quietly. */
  available(): boolean;
  status(): { busy: boolean; activity: string | null };
}
