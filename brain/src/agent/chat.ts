import type { McpSdkServerConfigWithInstance, SDKMessage } from '@anthropic-ai/claude-agent-sdk';
import type { AppContext, ChatQuestion, QuickRequest, UiContext } from '../core/context.js';
import type { Id } from '../core/types.js';
import { newId } from '../core/util.js';
import type { Billing, Engine, EngineRun } from './engine.js';
import { activityPhrase, chatSystem, RESEARCHER, turnContext } from './prompts.js';
import type { Self } from './self.js';

const ASK_TIMEOUT = 3 * 60_000;
const QUIET_TOOLS = new Set(['ToolSearch', 'TodoWrite']);
const EDIT_TOOLS = new Set(['Write', 'Edit', 'MultiEdit', 'NotebookEdit']);
const BUILTINS = ['Read', 'Glob', 'Grep', 'Bash', 'Write', 'Edit', 'WebSearch', 'WebFetch', 'Task'];

export interface ChatDeps {
  billing: () => Billing;
  /** Connector servers a chat run sees in login mode. */
  connectors: () => Promise<string[]>;
  steward: (thread: { threadId: Id; ask: (question: string, options?: string[]) => Promise<string> }, nativeConnectors: boolean) => McpSdkServerConfigWithInstance;
  quick: (req: QuickRequest) => Promise<string>;
  activity: (text: string | null) => void;
  self: Self;
}

const clip = (text: string, max: number) => (text.length > max ? `${text.slice(0, max)}…` : text);

/** Tool input as the UI shows it: same shape, long values cut. */
function compactInput(input: unknown): unknown {
  if (typeof input !== 'object' || input === null) return input;
  const cut = (v: unknown): unknown => {
    if (typeof v === 'string') return clip(v, 300);
    if (typeof v !== 'object' || v === null) return v;
    const json = JSON.stringify(v);
    return json.length <= 300 ? v : clip(json, 300);
  };
  return Object.fromEntries(Object.entries(input).map(([k, v]) => [k, cut(v)]));
}

function resultText(content: unknown): string {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) return content.map((b) => (b && typeof b === 'object' && 'text' in b ? String(b.text) : '')).join('\n');
  return content === undefined || content === null ? '' : JSON.stringify(content);
}

export function createChat(ctx: AppContext, engine: Engine, deps: ChatDeps) {
  const { repos, bus } = ctx;
  const log = ctx.log.child('chat');
  const tails = new Map<Id, Promise<void>>();
  const aborts = new Map<Id, AbortController>();
  const questions = new Map<string, { threadId: Id; question: string; options?: string[]; resolve?: (answer: string) => void }>();

  const asker = (threadId: Id) => (question: string, options?: string[]) =>
    new Promise<string>((resolve) => {
      const questionId = newId();
      const entry: { threadId: Id; question: string; options?: string[]; resolve?: (answer: string) => void } = { threadId, question, ...(options?.length && { options }) };
      const timer = setTimeout(() => {
        // Stop holding the run up; a late answer comes back as a new turn (see `answer`).
        entry.resolve = undefined;
        resolve('No answer yet. Continue with your best assumption, or stop and say what you need.');
      }, ASK_TIMEOUT);
      entry.resolve = (answer) => {
        clearTimeout(timer);
        resolve(answer);
      };
      questions.set(questionId, entry);
      deps.activity('Waiting for your answer');
      bus.emit('chat.question', { threadId, questionId, question, ...(options?.length && { options }) });
    });

  async function title(threadId: Id, asked: string, reply: string): Promise<void> {
    try {
      const text = await deps.quick({
        kind: 'title', trigger: 'user', maxTokens: 300,
        prompt: `Title this conversation in at most six words. Reply with the title only: no quotes, no full stop.\n\nUser: ${clip(asked, 500)}\nAssistant: ${clip(reply, 500)}`,
      });
      const clean = text.trim().split('\n')[0]!.replace(/^["']|["'.]$/g, '').slice(0, 80);
      if (clean) repos.chat.updateThread(threadId, { title: clean });
    } catch (err) {
      log.warn(`title failed: ${(err as Error).message}`);
    }
  }

  async function turn(threadId: Id, runId: Id, text: string, context: UiContext | undefined, billing: Billing, model: string): Promise<void> {
    const abort = new AbortController();
    aborts.set(threadId, abort);
    bus.emit('chat.started', { threadId, runId });
    deps.activity('Thinking');
    const thread = repos.chat.thread(threadId);
    const calls = new Map<string, { messageId: Id; name: string; input: unknown; done: boolean }>();
    const denied = new Set<string>();
    let reply = '';
    let checkpointed = false;

    const say = (delta: string) => {
      reply += delta;
      bus.emit('chat.delta', { threadId, runId, text: delta });
    };
    const finishTool = (callId: string, status: 'ok' | 'error' | 'denied', result: string) => {
      const call = calls.get(callId);
      if (!call || call.done) return;
      call.done = true;
      repos.chat.updateMessage(call.messageId, { tool: { name: call.name, input: call.input, status, result } });
      bus.emit('chat.tool', { threadId, runId, callId, name: call.name, input: call.input, status, result });
    };

    const onMessage = (m: SDKMessage) => {
      if (m.type === 'system' && m.subtype === 'init') {
        if (m.session_id !== thread.agentSessionId) repos.chat.updateThread(threadId, { agentSessionId: m.session_id });
      } else if (m.type === 'stream_event') {
        // A subagent's prose is working material; only the main agent speaks to the user.
        if (m.parent_tool_use_id) return;
        const e = m.event;
        if (e.type === 'content_block_start' && e.content_block.type === 'text' && reply && !reply.endsWith('\n\n')) say('\n\n');
        else if (e.type === 'content_block_delta' && e.delta.type === 'text_delta') say(e.delta.text);
      } else if (m.type === 'assistant') {
        for (const block of m.message.content) {
          if (block.type !== 'tool_use' || QUIET_TOOLS.has(block.name)) continue;
          const input = compactInput(block.input);
          const message = repos.chat.addMessage({ threadId, role: 'tool', text: '', tool: { name: block.name, input, status: 'running' } });
          calls.set(block.id, { messageId: message.id, name: block.name, input, done: false });
          bus.emit('chat.tool', { threadId, runId, callId: block.id, name: block.name, input, status: 'running' });
          deps.activity(activityPhrase(block.name));
        }
      } else if (m.type === 'user' && Array.isArray(m.message.content)) {
        for (const block of m.message.content) {
          if (block.type !== 'tool_result') continue;
          finishTool(block.tool_use_id, denied.has(block.tool_use_id) ? 'denied' : block.is_error ? 'error' : 'ok', clip(resultText(block.content), 800));
        }
        deps.activity('Thinking');
      }
    };

    const fast = ctx.config.get().models.fast;
    const servers = billing === 'login' ? await deps.connectors().catch(() => []) : [];
    // Without connectors of its own (API billing, relay mode, nothing connected) the agent reads them through the relay tools.
    const native = servers.length > 0;
    const base: Omit<EngineRun, 'prompt' | 'system'> = {
      kind: 'chat', trigger: 'user', model, billing,
      connectors: servers,
      steward: deps.steward({ threadId, ask: asker(threadId) }, native),
      builtins: BUILTINS,
      // The researcher keeps bulky connector payloads out of the main model's context, on the cheap model.
      ...(native && { agents: { researcher: { ...RESEARCHER, model: fast, effort: 'low', maxTurns: 15, disallowedTools: ['Bash', 'Write', 'Edit', 'NotebookEdit', 'Task', 'Agent', 'mcp__steward'] } } }),
      additionalDirectories: [ctx.paths.repoRoot, ctx.paths.home],
      maxTurns: 40,
      // Quick surfaces (the floating chat, the notch, voice) want the first words fast more than they want depth.
      effort: context?.source === 'quick' ? 'low' : ctx.config.get().agent.effort,
      persist: true,
      abort,
      onMessage,
      async onDecision(toolUseId, tool, decision, input) {
        if (decision.verdict === 'deny') denied.add(toolUseId);
        const file = (input as { file_path?: unknown } | null)?.file_path;
        if (decision.verdict === 'allow' && !checkpointed && EDIT_TOOLS.has(tool) && typeof file === 'string' && file.startsWith(ctx.paths.repoRoot)) {
          checkpointed = true;
          await deps.self.snapshot('before agent edit').catch((err) => log.warn(`checkpoint failed: ${(err as Error).message}`));
        }
      },
    };
    const prompt = `${turnContext(ctx, context)}${ctx.cost.canSpendBackground() ? '' : '\n(The agent budget is spent. Keep this turn economical and say so if the user asks for something heavy.)'}\n\n${text}`;

    const run = { ...base, system: chatSystem(ctx, native) };
    let res = await engine.run({ ...run, prompt, runId, resume: thread.agentSessionId ?? undefined });
    if (!res.ok && !res.cancelled && thread.agentSessionId && !reply && !calls.size) {
      // The saved session could not be resumed (transcripts age out): start a new one and carry the recent exchange in.
      log.warn(`resume of ${thread.agentSessionId} failed (${res.error}); starting a fresh session`);
      repos.chat.updateThread(threadId, { agentSessionId: null });
      const earlier = repos.chat.messages(threadId).filter((m) => m.role === 'user' || m.role === 'assistant').slice(-13, -1)
        .map((m) => `${m.role === 'user' ? 'User' : 'You'}: ${clip(m.text, 1500)}`).join('\n');
      res = await engine.run({ ...run, prompt: earlier ? `Earlier in this conversation:\n${earlier}\n\n${prompt}` : prompt });
    }

    aborts.delete(threadId);
    for (const [callId, call] of calls) if (!call.done) finishTool(callId, 'error', 'interrupted');
    // A failed run's text is the SDK's error line, not a reply.
    const final = (reply.trim() || (res.ok ? res.text.trim() : '')) + (!res.ok && !res.cancelled && reply.trim() ? `\n\n(Stopped early: ${res.error})` : '');
    if (final) {
      const message = repos.chat.addMessage({ threadId, role: 'assistant', text: final, costUsd: res.costUsd });
      bus.emit('chat.done', { threadId, runId, messageId: message.id, costUsd: res.costUsd });
    } else {
      bus.emit('chat.error', { threadId, runId, message: res.cancelled ? 'Interrupted' : res.text.trim() || res.error || 'The agent returned nothing' });
    }
    deps.activity(null);
    if (res.ok && !thread.agentSessionId) void title(threadId, text, final);
  }

  return {
    async chat(threadId: Id, _messageId: Id, text: string, context?: UiContext): Promise<{ runId: Id }> {
      repos.chat.thread(threadId);
      const billing = deps.billing();
      const model = ctx.config.get().models.main;
      const run = ctx.cost.start({ kind: 'chat', trigger: 'user', model, billing });
      // One run per thread: a second message waits for the first reply instead of racing it on the same session.
      const next = (tails.get(threadId) ?? Promise.resolve())
        .then(() => turn(threadId, run.id, text, context, billing, model))
        .catch((err: Error) => {
          log.error('chat turn failed', err);
          ctx.cost.finish(run.id, { status: 'error', summary: err.message.slice(0, 200) });
          bus.emit('chat.error', { threadId, runId: run.id, message: err.message });
          deps.activity(null);
        })
        .finally(() => {
          if (tails.get(threadId) === next) tails.delete(threadId);
        });
      tails.set(threadId, next);
      return { runId: run.id };
    },

    interrupt(threadId: Id): void {
      aborts.get(threadId)?.abort();
    },

    answer(questionId: string, answer: string): void {
      const q = questions.get(questionId);
      if (!q) return;
      questions.delete(questionId);
      if (q.resolve) return q.resolve(answer);
      const message = repos.chat.addMessage({ threadId: q.threadId, role: 'user', text: `About "${q.question}": ${answer}` });
      void this.chat(q.threadId, message.id, message.text);
    },

    questions: (): ChatQuestion[] => [...questions].map(([questionId, q]) => ({ threadId: q.threadId, questionId, question: q.question, ...(q.options && { options: q.options }) })),

    forget(threadId: Id): void {
      aborts.get(threadId)?.abort();
      for (const [id, q] of questions) {
        if (q.threadId !== threadId) continue;
        questions.delete(id);
        q.resolve?.('The user closed this conversation. Stop here.');
      }
    },

    /** Resolves when every queued turn has finished. */
    idle: () => Promise.allSettled([...tails.values()]).then(() => undefined),
  };
}
