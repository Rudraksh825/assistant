import { closeSync, existsSync, openSync, readdirSync, readSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import type { AgentRuntime, AppContext, RunRequest, RunResult, UiContext } from '../core/context.js';
import type { Schedule } from '../core/scheduler.js';
import type { Id } from '../core/types.js';
import { HttpError, newId } from '../core/util.js';
import { createChat } from './chat.js';
import { createEngine, toolPrefix, type Billing } from './engine.js';
import { createExecutor, REBUILD_TOOL } from './executor.js';
import { decide } from './guard.js';
import { budgetSpent, createQuick } from './quick.js';
import { createSelf, type Self } from './self.js';
import { BRIDGE_TOOLS, stamp, stewardServer, toMs, type ToolEnv } from './tools.js';

const OFF = 'Agent runtime not installed in this process (test run or STEWARD_AGENT=off)';
/** Background runs read. A shell is for the chat the user is watching, and for what they approved. */
export const READ_BUILTINS = ['Read', 'Glob', 'Grep', 'WebSearch', 'WebFetch'];
const CHAT_CONNECTORS = ['chat', 'mail', 'calendar', 'tickets', 'docs', 'meetings'];
const TRANSCRIPT_TAIL_BYTES = 2_000_000;
const RECAP_CHARS = 30_000;
const BRIDGE_RESULT_CHARS = 60_000;
const JOBS_KEY = 'agent:jobs';

const clip = (text: string, max: number) => (text.length > max ? `${text.slice(0, max)}…` : text);
const asText = (v: unknown) => (typeof v === 'string' ? v : JSON.stringify(v));

/** Stands in when the agent is switched off (tests, or STEWARD_AGENT=off): the app stays usable and says why nothing happened. */
function placeholder(ctx: AppContext): AgentRuntime {
  const unavailable = () => new HttpError(503, 'agent_unavailable', OFF);
  return {
    async chat(threadId) {
      const runId = newId();
      setImmediate(() => ctx.bus.emit('chat.error', { threadId, runId, message: OFF }));
      return { runId };
    },
    interrupt() {},
    answer() {},
    questions: () => [],
    forget() {},
    async capture() {
      ctx.repos.nudges.create({ kind: 'system', title: OFF, body: 'Your capture is saved as a note. It will not be turned into tasks while the agent is off.', priority: 1, dedupeKey: 'agent-off' });
    },
    executeApproval: async () => ({ ok: false, result: OFF }),
    checkApproval: () => null,
    async recapSession() { throw unavailable(); },
    async prepMeeting() { throw unavailable(); },
    rebuildApp: async () => ({ ok: false, log: OFF }),
    async quick() { throw unavailable(); },
    async run() { throw unavailable(); },
    available: () => false,
    status: () => ({ busy: false, activity: null }),
  };
}

const CAPTURE_ITEM = {
  type: 'object', additionalProperties: false, required: ['title', 'notes', 'priority', 'due', 'project', 'people', 'waitingOn', 'why'],
  properties: {
    title: { type: 'string' }, notes: { type: 'string' }, priority: { type: 'integer', enum: [0, 1, 2, 3] },
    due: { type: 'string', description: 'local ISO date or datetime, "" when none' },
    project: { type: 'string', description: 'exact title from the project list, "" when none fits' },
    people: { type: 'array', items: { type: 'string' } }, waitingOn: { type: 'string', description: 'who or what it waits on, "" when nothing' },
    why: { type: 'string', description: 'suggestions only: one line on why you inferred it; "" for tasks' },
  },
};
const CAPTURE_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['tasks', 'suggestions', 'question'],
  properties: { tasks: { type: 'array', items: CAPTURE_ITEM }, suggestions: { type: 'array', items: CAPTURE_ITEM }, question: { type: 'string' } },
};
interface CaptureItem { title: string; notes: string; priority: 0 | 1 | 2 | 3; due: string; project: string; people: string[]; waitingOn: string; why: string }

export function createAgentRuntime(ctx: AppContext): AgentRuntime {
  // Under `node --test` the runtime stays off unless a test opts in: a test run must never spend the user's plan.
  if (process.env.STEWARD_AGENT === 'off' || (process.env.NODE_TEST_CONTEXT && process.env.STEWARD_AGENT !== 'on')) return placeholder(ctx);

  const { repos } = ctx;
  const log = ctx.log.child('agent');
  let self: Self | undefined;
  const engine = createEngine(ctx, () => self?.building() ?? false);
  const quick = createQuick(ctx, engine);
  const models = () => ctx.config.get().models;
  const hasKey = () => !!ctx.config.secret('ANTHROPIC_API_KEY');

  let activity: string | null = null;
  const setActivity = (text: string | null) => {
    if (text === activity) return;
    activity = text;
    ctx.bus.emit('agent.activity', { busy: text !== null, activity: text });
  };
  const during = async <T>(text: string, fn: () => Promise<T>): Promise<T> => {
    setActivity(text);
    try {
      return await fn();
    } finally {
      setActivity(null);
    }
  };

  const built = createSelf({
    repoRoot: ctx.paths.repoRoot,
    tmpDir: ctx.paths.checkpointsDir,
    onLog: (line) => setActivity(`Building: ${line}`),
    onBuilt: () => ctx.bus.emit('app.relaunch', { reason: 'rebuilt' }),
    // Anything but a plain "auto" asks.
    mode: () => (ctx.config.get().agent.selfModify === 'auto' ? 'auto' : 'ask'),
    requestApproval(input, threadId) {
      const waiting = repos.approvals.list('pending').find((a) => a.tool === REBUILD_TOOL && a.input.tree === input.tree);
      return (waiting ?? repos.approvals.create({
        kind: 'self_modify', tool: REBUILD_TOOL, target: 'this app', note: input.why, threadId: threadId ?? null,
        summary: `Rebuild Steward with changes to ${input.files.length} file${input.files.length === 1 ? '' : 's'}`,
        input: { ...input },
      })).id;
    },
  });
  self = built;

  /** `api` is honoured only while a key exists; otherwise chat runs on the login and the user is told once. */
  const chatBilling = (): Billing => {
    if (ctx.config.get().agent.billing !== 'api') return 'login';
    if (hasKey()) return 'api';
    repos.nudges.create({ kind: 'system', title: 'No API key yet', body: 'Agent billing is set to "api" but no ANTHROPIC_API_KEY is saved, so chat is running on your Claude login. Add a key in Settings.', priority: 1, dedupeKey: 'agent-billing-fallback' });
    return 'login';
  };

  /**
   * `config.agent.connectors: "bridge"` keeps connectors out of the main chat agent even on the login and reads them through
   * the relay instead: every chat call then carries about half the tokens, and each connector read costs one fast-model run.
   */
  const relayed = () => (ctx.config.get().agent as { connectors?: string }).connectors === 'bridge';

  const serverOf = (tool: string) => engine.connectors.catalog().then((c) => c.servers.find((s) => s.status === 'connected' && tool.startsWith(toolPrefix(s.name)))?.name);
  const executor = createExecutor({ ctx, engine, self: built, fastModel: () => models().fast, serverOf, during });


  const bridge: ToolEnv['bridge'] = {
    async tools(query) {
      const words = query.toLowerCase().split(/[^a-z0-9]+/).filter(Boolean);
      const catalog = await engine.connectors.catalog();
      const reads = catalog.servers.filter((s) => s.status === 'connected').flatMap((s) => s.tools.filter((t) => t.readOnly && decide(t.name, {}, engine.policy()).verdict === 'allow'));
      const score = (name: string) => words.filter((w) => name.toLowerCase().includes(w)).length;
      const hits = reads.map((t) => ({ t, n: score(`${t.name} ${t.description}`) })).filter((h) => h.n > 0).sort((a, b) => b.n - a.n).slice(0, 6).map((h) => h.t);
      if (!hits.length) return { tools: [], servers: catalog.servers.filter((s) => s.status === 'connected').map((s) => s.name.replace(/^claude\.ai /, '')) };

      const schemaKey = (tool: string) => `agent:schema:${tool}`;
      const missing = hits.filter((t) => repos.kv.get(schemaKey(t.name)) === null);
      if (missing.length) {
        // The SDK does not expose connector input schemas; the model that can see them copies them out once, and they are cached.
        const names = missing.map((t) => t.name);
        const res = await engine.run({
          kind: 'bridge:schema', trigger: 'user', model: models().fast, billing: 'login', effort: 'low', maxTurns: 4,
          connectors: [...new Set(missing.map((t) => t.server))], hideWrites: true, policy: { onlyTool: 'ToolSearch' },
          system: 'You copy tool schemas. Output JSON only.',
          prompt: `Load these tools with ToolSearch (query "select:${names.join(',')}"). Then reply with one JSON object mapping each tool name to its input JSON schema, copied exactly. No prose, no code fence.`,
        });
        try {
          const parsed = JSON.parse(res.text.slice(res.text.indexOf('{'), res.text.lastIndexOf('}') + 1)) as Record<string, unknown>;
          for (const name of names) if (parsed[name]) repos.kv.set(schemaKey(name), parsed[name]);
        } catch {
          log.warn('bridge could not read tool schemas');
        }
      }
      return { tools: hits.map((t) => ({ tool: t.name, ...(t.description && { description: clip(t.description, 200) }), inputSchema: repos.kv.get(schemaKey(t.name)) ?? 'unknown: try the obvious fields, the error will name what is missing' })) };
    },

    async read(tool, input) {
      const verdict = decide(tool, input, engine.policy());
      if (verdict.verdict !== 'allow') return `Error: ${verdict.verdict === 'deny' ? verdict.reason : 'not a connector read'}`;
      const server = await serverOf(tool);
      if (!server) return `Error: ${tool} is not a tool of a connected server. Find the exact name with connector_tools.`;
      let captured: unknown;
      const res = await engine.run({
        kind: 'bridge', trigger: 'user', model: models().fast, billing: 'login', effort: 'low', maxTurns: 5,
        connectors: [server], hideWrites: true, policy: { exact: { tool, input, approved: false } },
        system: 'You relay exactly one tool call and nothing else.',
        prompt: `Call ${tool} once with exactly this JSON input: the same keys and values, no optional parameters added (load it with ToolSearch "select:${tool}" if needed):\n${JSON.stringify(input)}\nThen reply "ok".`,
        // The payload goes back to the caller as is; the relay model only needs to know the call landed.
        onToolResult(name, response) {
          if (name !== tool) return undefined;
          captured = response;
          return 'captured';
        },
      });
      if (captured === undefined) return `Error: the read did not run (${res.error ?? clip(res.text, 300)})`;
      return clip(asText(captured), BRIDGE_RESULT_CHARS);
    },
  };


  type StoredJob = { prompt: string; schedule: Schedule; connectors?: string[] };
  const jobName = (name: string) => `agent.${name}`;
  const registerJob = (name: string, job: StoredJob) =>
    ctx.scheduler.register({
      name: jobName(name), schedule: job.schedule, spends: true,
      async run(trigger) {
        await runtime.run({ kind: `job:${name}`, prompt: job.prompt, model: 'fast', trigger: trigger === 'manual' ? 'user' : 'schedule', connectors: job.connectors ?? 'none', stewardTools: 'all' });
      },
    });
  const schedule: ToolEnv['schedule'] = ({ name, prompt, schedule: when, connectors, remove }) => {
    const jobs = repos.kv.get<Record<string, StoredJob>>(JOBS_KEY) ?? {};
    if (remove) {
      delete jobs[name];
      repos.kv.set(JOBS_KEY, jobs);
      ctx.scheduler.unregister(jobName(name));
      return `removed ${name}`;
    }
    if (!prompt || !when) throw new Error('a job needs a prompt and either everyMin or at');
    jobs[name] = { prompt, schedule: when, connectors };
    repos.kv.set(JOBS_KEY, jobs);
    registerJob(name, jobs[name]);
    return `scheduled ${jobName(name)}`;
  };
  for (const [name, job] of Object.entries(repos.kv.get<Record<string, StoredJob>>(JOBS_KEY) ?? {})) registerJob(name, job);


  const toolEnv = (extra: Partial<ToolEnv> = {}): ToolEnv => ({
    ctx, self: built, schedule, bridge,
    policy: engine.policy,
    recap: (id) => recap(id),
    checkApproval: (approval) => executor.check(approval),
    knownConnectorTool: (name) => {
      const known = engine.policy().connectorReadOnly;
      return known?.size ? known.has(name) : null;
    },
    ...extra,
  });

  const chat = createChat(ctx, engine, {
    billing: chatBilling,
    // A kind the user switched off in settings stays out of chat too, which also keeps its tool list out of every prompt.
    connectors: async () => (relayed() ? [] : engine.connectors.resolve(CHAT_CONNECTORS.filter((kind) => ctx.config.get().connectors[kind]?.enabled !== false))),
    // With the connectors attached the relay tools would only be noise.
    steward: (thread, nativeConnectors) => stewardServer(toolEnv(thread), 'all', { deferRare: true, except: nativeConnectors ? BRIDGE_TOOLS : [] }),
    quick,
    activity: setActivity,
    self: built,
  });


  function transcriptFile(sessionId: Id, cwd: string): string | null {
    const configured = (ctx.config.get().code as { claudeDir?: string }).claudeDir ?? '~/.claude';
    const projects = join(configured.replace(/^~/, homedir()), 'projects');
    const direct = join(projects, cwd.replace(/[^a-zA-Z0-9]/g, '-'), `${sessionId}.jsonl`);
    if (existsSync(direct)) return direct;
    try {
      for (const dir of readdirSync(projects)) {
        const file = join(projects, dir, `${sessionId}.jsonl`);
        if (existsSync(file)) return file;
      }
    } catch { /* no projects dir */ }
    return null;
  }

  function transcriptTail(file: string): string {
    const size = statSync(file).size;
    const length = Math.min(size, TRANSCRIPT_TAIL_BYTES);
    const buffer = Buffer.alloc(length);
    const fd = openSync(file, 'r');
    try {
      readSync(fd, buffer, 0, length, size - length);
    } finally {
      closeSync(fd);
    }
    const lines = buffer.toString('utf8').split('\n');
    if (length < size) lines.shift();
    const turns: string[] = [];
    for (const line of lines) {
      let entry: { type?: string; isSidechain?: boolean; isMeta?: boolean; message?: { content?: unknown } };
      // Transcripts also hold very large bookkeeping lines; only message lines are worth parsing.
      if (!line.includes('"type":"user"') && !line.includes('"type":"assistant"')) continue;
      try { entry = JSON.parse(line); } catch { continue; }
      if ((entry.type !== 'user' && entry.type !== 'assistant') || entry.isSidechain || entry.isMeta) continue;
      const content = entry.message?.content;
      const blocks: { type?: string; text?: string; name?: string; input?: unknown }[] = typeof content === 'string' ? [{ type: 'text', text: content }] : Array.isArray(content) ? content : [];
      const text = blocks.map((b) => (b.type === 'text' ? clip(b.text ?? '', 2000) : b.type === 'tool_use' ? `[${b.name}: ${clip(JSON.stringify(b.input ?? {}), 120)}]` : '')).filter(Boolean).join('\n');
      if (text) turns.push(`${entry.type === 'user' ? 'USER' : 'CLAUDE'}: ${text}`);
    }
    let out = '';
    for (let i = turns.length - 1; i >= 0 && out.length + turns[i]!.length < RECAP_CHARS; i--) out = `${turns[i]}\n${out}`;
    return out;
  }

  async function recap(sessionId: Id): Promise<string> {
    const session = repos.sessions.must(sessionId);
    const file = transcriptFile(session.id, session.cwd);
    const tail = file ? transcriptTail(file) : [session.lastUserPrompt && `USER: ${session.lastUserPrompt}`, session.lastAssistantText && `CLAUDE: ${session.lastAssistantText}`].filter(Boolean).join('\n');
    if (!tail.trim()) return 'No transcript found for this session.';
    return during('Recapping a session', () => quick({
      kind: 'recap', trigger: 'user', maxTokens: 1500,
      system: 'You recap coding-agent sessions for the person who started them. Plain text, no markdown.',
      prompt: `This is the tail of a Claude Code session in ${session.repo ?? session.cwd}${session.branch ? ` on ${session.branch}` : ''}. Recap it in 3 to 5 short lines, each starting with its label: Goal, Done, Open, Next. Be specific (file names, ticket ids, what is blocking). Skip a line that has nothing.\n\n${tail}`,
    })).then((text) => text.trim());
  }


  const runtime: AgentRuntime = {
    chat: chat.chat.bind(chat),
    interrupt: chat.interrupt,
    answer: chat.answer.bind(chat),
    questions: chat.questions,
    forget: chat.forget,
    quick,
    available: () => true,
    status: () => ({ busy: activity !== null || engine.busy(), activity }),
    recapSession: recap,

    async run(req: RunRequest): Promise<RunResult> {
      const trigger = req.trigger ?? 'schedule';
      if (trigger !== 'user' && !ctx.cost.canSpendBackground()) throw budgetSpent();
      const wanted = req.connectors && req.connectors !== 'none' && req.connectors.length > 0;
      const servers = wanted ? await engine.connectors.resolve(req.connectors).catch((err: Error) => { throw new HttpError(503, 'connector_unavailable', `Connectors could not be listed: ${err.message}`); }) : [];
      if (wanted && !servers.length) throw new HttpError(503, 'connector_unavailable', `No connected connector matches ${JSON.stringify(req.connectors)}`);
      const fast = req.model !== 'main';
      const res = await engine.run({
        kind: req.kind, trigger, prompt: req.prompt,
        system: req.system ?? 'You are Steward, a personal assistant doing a background job. Do exactly what is asked, then reply briefly.',
        model: fast ? models().fast : models().main,
        // Connectors exist only on the login; without them the API key is preferred because it does not draw on the shared seat.
        billing: servers.length || !hasKey() ? 'login' : 'api',
        connectors: servers, hideWrites: !req.writesVisible,
        // A run that has the connectors does not also get the relay to them.
        ...(req.stewardTools && { steward: stewardServer(toolEnv(), req.stewardTools, { except: servers.length ? BRIDGE_TOOLS : [] }) }),
        builtins: req.builtins ? READ_BUILTINS : [],
        maxTurns: req.maxTurns ?? 12,
        effort: fast ? 'low' : ctx.config.get().agent.effort,
      });
      return { runId: res.runId, ok: res.ok, text: res.ok ? res.text : res.text || res.error || 'run failed', costUsd: res.costUsd };
    },

    async capture(noteId: Id, text: string, context?: UiContext): Promise<void> {
      const projects = repos.projects.list().filter((p) => p.status === 'active');
      const seen = [context?.app, context?.title, context?.url].filter(Boolean).join(' | ');
      const raw = await during('Sorting your capture', () => quick({
        kind: 'capture', trigger: 'user', maxTokens: 4000, schema: CAPTURE_SCHEMA,
        system: 'You turn a person\'s brain dump into their to-do items. Output JSON only.',
        prompt: `Now: ${stamp(Date.now())} (${new Date().toLocaleDateString('en-GB', { weekday: 'long' })}).${seen ? `\nThey were looking at: ${seen}` : ''}
Projects: ${projects.map((p) => p.title).join('; ') || '(none)'}

Split the dump below.
- tasks: things they plainly told themselves to do. Keep their wording, as a short imperative title. Extra detail goes in notes.
- suggestions: items you had to infer, or that are ambiguous. Say why in "why".
- question: at most one, and only if something important cannot be guessed. Otherwise "".
priority: 0 unless they signal it (1 low, 2 high, 3 urgent). due: only when they give a time; resolve "tomorrow", "Friday" against Now. project: only an exact title from Projects. Do not invent items.

Dump:
${text}`,
      }));
      const parsed = JSON.parse(raw.slice(raw.indexOf('{'), raw.lastIndexOf('}') + 1)) as { tasks: CaptureItem[]; suggestions: CaptureItem[]; question: string };
      const fields = (item: CaptureItem) => {
        let dueAt: number | null = null;
        try { dueAt = toMs(item.due) ?? null; } catch { /* an unparseable date is dropped, the task is kept */ }
        return {
          title: item.title, notes: item.notes ?? '', priority: item.priority ?? 0, dueAt,
          projectId: projects.find((p) => p.title.toLowerCase() === (item.project ?? '').toLowerCase())?.id ?? null,
          people: item.people ?? [], waitingOn: item.waitingOn || null,
        };
      };
      const tasks = (parsed.tasks ?? []).filter((t) => t.title?.trim()).map((item) => repos.tasks.create({
        ...fields(item), status: item.waitingOn ? 'waiting' : 'todo', source: 'capture', sourceRef: noteId,
        links: context?.url ? [{ kind: 'url', title: context.title ?? context.url, url: context.url }] : [],
      }));
      const suggestions = (parsed.suggestions ?? []).filter((s) => s.title?.trim()).map((item) => repos.suggestions.create({
        kind: 'new_task', title: item.title, rationale: item.why ?? '', payload: fields(item), source: 'capture', sourceRef: noteId, sourceUrl: context?.url ?? null, confidence: 0.6,
      }));
      if (parsed.question?.trim()) repos.suggestions.create({ kind: 'question', title: parsed.question.trim(), payload: { question: parsed.question.trim(), noteId }, source: 'capture', sourceRef: noteId });

      const count = (n: number, word: string) => `${n} ${word}${n === 1 ? '' : 's'}`;
      const parts = [tasks.length && `${count(tasks.length, 'task')} added`, suggestions.length && count(suggestions.length, 'suggestion'), parsed.question?.trim() && '1 question'].filter(Boolean);
      repos.nudges.create({
        kind: 'task', priority: 1, title: parts.join(', ') || 'Nothing to file from that capture',
        body: tasks.map((t) => t.title).slice(0, 4).join(' · '),
        actions: [{ id: 'open', label: 'Open', kind: 'open_view', view: suggestions.length || parsed.question?.trim() ? 'inbox' : 'today' }],
      });
    },

    executeApproval: (approval) => executor.execute(approval),
    checkApproval: (approval, edited) => executor.check(approval, edited),

    async prepMeeting(meetingId: Id, trigger: 'user' | 'schedule' = 'user'): Promise<{ runId: Id }> {
      const meeting = repos.meetings.must(meetingId);
      if (meeting.prepStatus === 'running') throw new HttpError(409, 'conflict', 'A prep run for this meeting is already going');
      const servers = await engine.connectors.resolve(['meetings', 'chat', 'tickets']).catch(() => []);
      const model = models().fast;
      const billing: Billing = servers.length || !hasKey() ? 'login' : 'api';
      const run = ctx.cost.start({ kind: 'brief:prep', trigger, model, billing });
      repos.meetings.update(meeting.id, { prepStatus: 'running', prepError: null });
      void during(`Preparing for ${clip(meeting.title, 40)}`, () => engine.run({
        runId: run.id, kind: 'brief:prep', trigger, model, billing, effort: 'low', maxTurns: 16,
        connectors: servers, hideWrites: true,
        steward: stewardServer(toolEnv(), ['tasks_search', 'people_search', 'notes_search', 'meetings_search', 'signals_search', 'memory_list', 'memory_read']),
        system: 'You are Steward, preparing your user for a meeting. You only read. Reply with the prep note and nothing else.',
        prompt: `Prepare a note for this meeting.
Title: ${meeting.title}
When: ${stamp(meeting.startAt)} to ${stamp(meeting.endAt)}
With: ${meeting.attendees.join(', ') || 'unknown'}${meeting.summary ? `\nDescription: ${clip(meeting.summary, 600)}` : ''}

Look in this order and stop when you have enough: steward tools (earlier meetings with the same title or people, open tasks mentioning them, notes, memory on these people), then the connectors (meeting recorder for the last occurrence, chat and tickets for what is open with these people). A few targeted reads, not a crawl.

Reply in markdown, under 200 words, with these parts (leave one out if you found nothing for it):
**Who**: one line per person that matters.
**Last time**: decisions and action items from the previous occurrence.
**Open with them**: tasks and threads still pending.
**Talking points**: 2 to 4 concrete suggestions.`,
      })).then((res) => {
        if (!res.ok || !res.text.trim()) throw new Error(res.error ?? 'empty prep note');
        repos.meetings.update(meeting.id, { prepNote: res.text.trim(), prepStatus: null, prepError: null });
        repos.nudges.create({ kind: 'meeting', priority: 1, title: `Prep ready: ${clip(meeting.title, 60)}`, body: clip(res.text.replace(/[*#]/g, '').trim(), 160), actions: [{ id: 'open', label: 'Open', kind: 'open_view', view: 'meetings', path: `/meetings/${meeting.id}` }] });
      }).catch((err: Error) => {
        log.warn(`meeting prep failed: ${err.message}`);
        // The meeting may have been removed by a calendar sync while the run was going.
        if (repos.meetings.get(meeting.id)) repos.meetings.update(meeting.id, { prepStatus: 'failed', prepError: clip(err.message, 300) });
        // A prep nobody asked for fails quietly; the Meetings screen still shows why.
        if (trigger === 'user') repos.nudges.create({ kind: 'system', priority: 1, title: 'Meeting prep failed', body: clip(err.message, 200), actions: [{ id: 'open', label: 'Open', kind: 'open_view', view: 'meetings', path: `/meetings/${meeting.id}` }] });
      });
      return { runId: run.id };
    },

    async rebuildApp(): Promise<{ ok: boolean; log: string; approvalId?: string }> {
      try {
        return await built.rebuild();
      } finally {
        setActivity(null);
      }
    },
  };

  repos.health.set('agent:api', hasKey() ? 'ok' : 'off');
  // Costs nothing (no prompt is sent) but starts a child process, so it stays off the startup path.
  setTimeout(() => void engine.connectors.catalog().catch((err: Error) => log.warn(`connector probe failed: ${err.message}`)), 3000).unref();

  return runtime;
}
