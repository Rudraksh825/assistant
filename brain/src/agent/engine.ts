import { query, type AgentDefinition, type CanUseTool, type HookCallback, type McpSdkServerConfigWithInstance, type Options, type SDKMessage } from '@anthropic-ai/claude-agent-sdk';
import { accessSync, constants, existsSync, readFileSync, realpathSync } from 'node:fs';
import { homedir } from 'node:os';
import { delimiter, dirname, isAbsolute, join } from 'node:path';
import type { AppContext } from '../core/context.js';
import type { Id, Ms } from '../core/types.js';
import { HOUR } from '../core/util.js';
import { PROTECTED, touchesBoundary } from './boundary.js';
import { decide, type Decision, type Policy } from './guard.js';
import { SANDBOX_NOTE, SANDBOX_SIGNS, sandboxSettings, type SandboxEnv } from './sandbox.js';

export type Billing = 'login' | 'api';
export type Trigger = 'user' | 'schedule' | 'event';

export interface ConnectorTool { name: string; server: string; readOnly: boolean; description: string }
export interface Catalog { at: Ms; servers: { name: string; status: string; tools: ConnectorTool[] }[] }

export interface EngineRun {
  kind: string;
  trigger: Trigger;
  model: string;
  billing: Billing;
  prompt: string;
  system: string;
  /** Connector servers the model can see, as catalog names. Login billing only. */
  connectors?: string[];
  /** Drop the kept servers' write tools from the model's view (background runs never file approvals). */
  hideWrites?: boolean;
  steward?: McpSdkServerConfigWithInstance;
  builtins?: string[];
  agents?: Record<string, AgentDefinition>;
  additionalDirectories?: string[];
  maxTurns?: number;
  resume?: string;
  effort?: string;
  schema?: Record<string, unknown>;
  /** Keep a transcript so the session can be resumed. */
  persist?: boolean;
  policy?: Pick<Policy, 'exact' | 'onlyTool'>;
  abort?: AbortController;
  /** A ledger row opened by the caller (chat hands the run id out before the run starts). */
  runId?: Id;
  onMessage?: (m: SDKMessage) => void;
  onDecision?: (toolUseId: string, tool: string, decision: Decision, input: unknown) => void | Promise<void>;
  /** Sees every tool result; a returned value replaces what the model reads. */
  onToolResult?: (tool: string, response: unknown) => unknown;
}

export interface EngineResult {
  runId: Id;
  ok: boolean;
  text: string;
  costUsd: number;
  inputTokens: number;
  outputTokens: number;
  sessionId: string | null;
  structured?: unknown;
  cancelled: boolean;
  error?: string;
}

const CATALOG_TTL = 6 * HOUR;
const CATALOG_KEY = 'agent:connectors';
const EFFORTS = new Set(['low', 'medium', 'high', 'xhigh', 'max']);
const WRITE_TOOLS = new Set(['Bash', 'Write', 'Edit', 'MultiEdit', 'NotebookEdit']);
/** Environment variables that look like credentials: the agent's shell has no use for them and could print them. */
const SECRET_ENV = /TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|API_?KEY|PRIVATE_?KEY|^AWS_|^GIT_CONFIG|^GIT_(DIR|WORK_TREE|SSH|EXEC_PATH|EXTERNAL_DIFF|ASKPASS|PROXY_COMMAND)/i;
/** Connector kinds → server names to look for. `config.connectors.<kind>.servers` overrides a row. */
const KINDS: Record<string, string[]> = {
  chat: ['Slack', 'Teams', 'Discord'],
  calendar: ['Calendar'],
  tickets: ['Linear', 'Jira', 'Atlassian', 'Asana'],
  meetings: ['Fathom', 'Meetings', 'Granola', 'Zoom', 'Gong'],
  docs: ['Notion', 'Drive', 'Docs', 'Confluence'],
  mail: ['Gmail', 'Mail', 'Outlook'],
};

export const toolPrefix = (server: string) => `mcp__${server.replace(/[^a-zA-Z0-9_-]/g, '_')}__`;
const shortName = (server: string) => server.replace(/^claude\.ai /, '');

/**
 * Loose names ("Calendar", "claude.ai Slack", "mcp__claude_ai_Linear", a kind such as "tickets") → the servers they mean.
 * Whole words only, so "Zoom" does not pick "ZoomInfo".
 */
export function matchServers(wanted: string[], servers: string[], kinds: Record<string, string[]> = KINDS): string[] {
  const norm = (s: string) => shortName(s.replace(/^mcp__/, '').replace(/^claude_ai_/, '')).toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
  const asked = wanted.flatMap((w) => kinds[w] ?? [w]).map(norm).filter(Boolean);
  return servers.filter((server) => asked.some((a) => ` ${norm(server)} `.includes(` ${a} `)));
}

export function createEngine(ctx: AppContext, building: () => boolean = () => false) {
  const log = ctx.log.child('agent');
  let catalog = ctx.repos.kv.get<Catalog>(CATALOG_KEY);
  let probing: Promise<Catalog> | null = null;
  let active = 0;

  // The SDK child must not inherit a parent Claude Code session or a stray key: the credential is chosen per run.
  const env = (billing: Billing, waitForConnectors: boolean): Record<string, string | undefined> => {
    const out: Record<string, string | undefined> = {};
    for (const [k, v] of Object.entries(process.env)) if (!/^(CLAUDE|ANTHROPIC|MCP_|OTEL_)/.test(k) && !SECRET_ENV.test(k)) out[k] = v;
    // The API key reaches the model client only, never the commands the agent runs.
    out.CLAUDE_CODE_SUBPROCESS_ENV_SCRUB = '1';
    // A folder that merely looks like a bare repository must not be taken for one: its config would name commands git runs outside the sandbox.
    Object.assign(out, { GIT_CONFIG_COUNT: '1', GIT_CONFIG_KEY_0: 'safe.bareRepository', GIT_CONFIG_VALUE_0: 'explicit' });
    // Connectors attach about two seconds after start; without this a one-shot first turn never sees them.
    if (waitForConnectors) out.MCP_CONNECTION_NONBLOCKING = '0';
    // Subagents and shells finish inside the turn that started them: a run's result is then complete, and nothing outlives it.
    out.CLAUDE_CODE_DISABLE_BACKGROUND_TASKS = '1';
    if (billing === 'api') out.ANTHROPIC_API_KEY = ctx.config.secret('ANTHROPIC_API_KEY');
    return out;
  };

  const realpath = (path: string): string => {
    let existing = path;
    while (!existsSync(existing) && dirname(existing) !== existing) existing = dirname(existing);
    try {
      return realpathSync.native(existing) + path.slice(existing.length);
    } catch {
      return path;
    }
  };

  /** Where a bare command name resolves on the PATH the agent's shell inherits. */
  const which = (command: string): string | null => {
    for (const dir of (process.env.PATH ?? '').split(delimiter)) {
      if (!isAbsolute(dir)) return null;
      const file = join(dir, command);
      try {
        accessSync(file, constants.X_OK);
        return file;
      } catch { /* next */ }
    }
    return null;
  };
  const apiPort = (): number | undefined => {
    try {
      return Number(readFileSync(ctx.paths.portFile, 'utf8')) || ctx.config.get().port;
    } catch {
      return ctx.config.get().port;
    }
  };

  const basePolicy = (cwd: string): Policy => ({
    repoRoot: ctx.paths.repoRoot,
    dataDir: ctx.paths.home,
    home: homedir(),
    cwd,
    writableRoots: ctx.config.get().agent.writableRoots,
    connectorReadOnly: new Map((catalog?.servers ?? []).flatMap((s) => s.tools.map((t) => [t.name, t.readOnly] as const))),
    realpath,
    apiPort: apiPort(),
    which,
  });

  /** Real paths: the kernel matches sandbox rules against where a file is, not against the name used to reach it. */
  const sandboxEnv = (): SandboxEnv => ({
    repoRoot: realpath(ctx.paths.repoRoot),
    dataDir: realpath(ctx.paths.home),
    home: realpath(homedir()),
    writableRoots: ctx.config.get().agent.writableRoots.map((r) => realpath(r.replace(/^~(?=\/|$)/, homedir()))),
    secretFiles: [ctx.paths.secretsFile, ctx.paths.tokenFile].map(realpath),
  });

  /** Lists the login's connector servers and tool annotations. Starts the Claude Code child but sends no prompt, so it costs nothing. */
  async function probe(): Promise<Catalog> {
    let release!: () => void;
    const gate = new Promise<void>((r) => (release = r));
    const q = query({
      prompt: (async function* () { await gate; })() as never,
      options: { cwd: ctx.paths.agentDir, env: env('login', true), settingSources: [], tools: ['ToolSearch'], systemPrompt: 'probe', persistSession: false },
    });
    try {
      let status = await q.mcpServerStatus();
      for (let i = 0; i < 40 && status.some((s) => s.status === 'pending'); i++) {
        await new Promise((r) => setTimeout(r, 300));
        status = await q.mcpServerStatus();
      }
      const next: Catalog = {
        at: Date.now(),
        servers: status.map((s) => ({
          name: s.name,
          status: s.status,
          tools: (s.tools ?? []).map((t) => ({ name: toolPrefix(s.name) + t.name, server: s.name, readOnly: t.annotations?.readOnly === true, description: (t.description ?? '').slice(0, 300) })),
        })),
      };
      catalog = next;
      ctx.repos.kv.set(CATALOG_KEY, next);
      ctx.repos.health.set('agent:login', 'ok');
      for (const s of next.servers) {
        if (s.status === 'connected' || s.status === 'failed') ctx.repos.health.set(`connector:${shortName(s.name)}`, s.status === 'connected' ? 'ok' : 'error');
      }
      return next;
    } catch (err) {
      ctx.repos.health.set('agent:login', 'error');
      throw err;
    } finally {
      release();
      q.close();
    }
  }

  const connectors = {
    /** Cached for six hours; `fresh` forces a new probe. */
    async catalog(fresh = false): Promise<Catalog> {
      if (!fresh && catalog && Date.now() - catalog.at < CATALOG_TTL) return catalog;
      probing ??= probe().finally(() => (probing = null));
      try {
        return await probing;
      } catch (err) {
        if (catalog) return catalog;
        throw err;
      }
    },
    /** Requested names → connected servers. `config.connectors.<kind>.servers` overrides the built-in list for a kind. */
    async resolve(wanted: string[] | 'all' | 'none' | undefined): Promise<string[]> {
      if (!wanted || wanted === 'none' || (Array.isArray(wanted) && !wanted.length)) return [];
      const connected = (await connectors.catalog()).servers.filter((s) => s.status === 'connected').map((s) => s.name);
      if (wanted === 'all') return connected;
      const configured = Object.fromEntries(Object.entries(ctx.config.get().connectors).flatMap(([kind, c]) => (Array.isArray(c.servers) ? [[kind, c.servers as string[]]] : [])));
      return matchServers(wanted, connected, { ...KINDS, ...configured });
    },
  };

  async function run(r: EngineRun): Promise<EngineResult> {
    const wantsConnectors = r.billing === 'login' && !!r.connectors?.length;
    const cat = wantsConnectors ? await connectors.catalog() : catalog;
    const cwd = ctx.paths.agentDir;
    const policy: Policy = { ...basePolicy(cwd), ...r.policy };
    let onceUsed = false;

    const sandboxed = new Set<string>();
    /** Where each Bash call was judged from, so the second gate judges the same call the same way. */
    const judgedAt = new Map<string, string>();
    const boundaryEnv = (at: string) => ({ repoRoot: policy.repoRoot, dataDir: policy.dataDir, home: policy.home, cwd: at, realpath });
    const judge = (tool: string, input: unknown, at: string): Decision => {
      if (building() && WRITE_TOOLS.has(tool)) return { verdict: 'deny', approvable: false, reason: 'The app is being rebuilt; commands and file edits wait until the build ends.' };
      if (touchesBoundary(tool, input, boundaryEnv(at))) return { verdict: 'deny', approvable: false, reason: PROTECTED };
      return decide(tool, input, { ...policy, cwd: at });
    };

    const guard: HookCallback = async (input) => {
      if (input.hook_event_name !== 'PreToolUse') return {};
      let decision = judge(input.tool_name, input.tool_input, input.cwd || cwd);
      if (input.tool_name === 'Bash') judgedAt.set(input.tool_use_id, input.cwd || cwd);
      // Only the in-process server may speak as steward; a remote server with that name gets no free pass.
      if (decision.verdict !== 'deny' && input.tool_name.startsWith('mcp__steward__') && input.mcp_server && input.mcp_server.source !== 'sdk') {
        decision = { verdict: 'deny', approvable: false, reason: 'Not the Steward tool server.' };
      }
      if (decision.verdict !== 'deny' && policy.exact && input.tool_name === policy.exact.tool) {
        if (onceUsed) decision = { verdict: 'deny', approvable: false, reason: 'The approved action already ran once. Do not repeat it.' };
        onceUsed = true;
      }
      await r.onDecision?.(input.tool_use_id, input.tool_name, decision, input.tool_input);
      // `agent` is set when the call comes from a subagent: the same hook judges those.
      log.debug(`guard ${decision.verdict} ${input.tool_name}`, { kind: r.kind, agent: input.agent_type ?? null });
      if (decision.verdict === 'deny') {
        log.info(`guard denied ${input.tool_name}`, { kind: r.kind, agent: input.agent_type ?? null, reason: decision.reason });
        return { hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: decision.reason } };
      }
      if (input.tool_name !== 'Bash') return { hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'allow' } };
      // The model's own word on the sandbox is never taken: the flag is set here, from the guard's verdict, on every call.
      if (decision.verdict === 'sandbox') sandboxed.add(input.tool_use_id);
      else log.info('bash outside the sandbox', { kind: r.kind, command: String((input.tool_input as { command?: unknown }).command).slice(0, 300) });
      return {
        hookSpecificOutput: {
          hookEventName: 'PreToolUse', permissionDecision: 'allow',
          updatedInput: { ...(input.tool_input as Record<string, unknown>), dangerouslyDisableSandbox: decision.verdict === 'allow' },
        },
      };
    };
    /**
     * Second gate, asked by Claude Code for whatever its own checks will not run on the hook's word alone: a command
     * leaving the sandbox, or a write to a location it considers sensitive. Only a command the guard itself sends
     * outside passes; everything else that gets this far is refused.
     */
    const canUseTool: CanUseTool = async (tool, input, asked) => {
      const decision = judge(tool, input, judgedAt.get(asked.toolUseID) ?? cwd);
      if (tool === 'Bash' && decision.verdict === 'allow' && input.dangerouslyDisableSandbox === true) return { behavior: 'allow', updatedInput: input };
      const message = decision.verdict === 'deny' ? decision.reason : `${PROTECTED} (Claude Code's own safety check stopped this call)`;
      log.info(`second gate refused ${tool}`, { kind: r.kind, reason: message });
      return { behavior: 'deny', message };
    };
    const capture: HookCallback = async (input) => {
      if (input.hook_event_name === 'PostToolUseFailure') {
        return sandboxed.has(input.tool_use_id) ? { hookSpecificOutput: { hookEventName: 'PostToolUseFailure', additionalContext: SANDBOX_NOTE } } : {};
      }
      if (input.hook_event_name !== 'PostToolUse') return {};
      const replacement = r.onToolResult?.(input.tool_name, input.tool_response);
      if (replacement !== undefined) return { hookSpecificOutput: { hookEventName: 'PostToolUse', updatedToolOutput: replacement } };
      // A command can fail inside and still exit 0 (`|| true`, a caught exception): the output says so.
      const hit = sandboxed.has(input.tool_use_id) && SANDBOX_SIGNS.test(JSON.stringify(input.tool_response ?? '').slice(0, 20_000));
      return hit ? { hookSpecificOutput: { hookEventName: 'PostToolUse', additionalContext: SANDBOX_NOTE } } : {};
    };

    const kept = new Set(wantsConnectors ? r.connectors : []);
    const options: Options = {
      model: r.model,
      systemPrompt: r.system,
      cwd,
      env: env(r.billing, wantsConnectors),
      settingSources: [],
      // ToolSearch stays whenever MCP tools exist: without it every connector schema is loaded up front.
      tools: [...(r.builtins ?? []), ...(wantsConnectors || r.steward ? ['ToolSearch'] : [])],
      // Nothing prompts: the hook answers every call, and what Claude Code still wants confirmed goes to `canUseTool`, which refuses by default.
      permissionMode: 'default',
      canUseTool,
      // A guard that throws must stop the call, not wave it through.
      hooks: { PreToolUse: [{ hooks: [guard], onFailure: 'block' }], PostToolUse: [{ hooks: [capture] }], PostToolUseFailure: [{ hooks: [capture] }] },
      ...(r.builtins?.includes('Bash') && { sandbox: sandboxSettings(sandboxEnv()) }),
      persistSession: r.persist ?? false,
      maxTurns: r.maxTurns ?? 12,
      abortController: r.abort,
      includePartialMessages: !!r.onMessage,
      ...(r.steward && { mcpServers: { steward: r.steward } }),
      ...(r.agents && { agents: r.agents }),
      ...(r.additionalDirectories && { additionalDirectories: r.additionalDirectories }),
      ...(r.resume && { resume: r.resume }),
      ...(r.effort && EFFORTS.has(r.effort) && { effort: r.effort as Options['effort'] }),
      ...(r.schema && { outputFormat: { type: 'json_schema', schema: r.schema } }),
      ...(wantsConnectors
        ? {
            settings: { deniedMcpServers: (cat?.servers ?? []).filter((s) => !kept.has(s.name)).map((s) => ({ serverName: s.name })) },
            ...(r.hideWrites && { disallowedTools: (cat?.servers ?? []).filter((s) => kept.has(s.name)).flatMap((s) => s.tools.filter((t) => !t.readOnly).map((t) => t.name)) }),
          }
        : { strictMcpConfig: true }),
    };

    const runId = r.runId ?? ctx.cost.start({ kind: r.kind, trigger: r.trigger, model: r.model, billing: r.billing }).id;
    const out: EngineResult = { runId, ok: false, text: '', costUsd: 0, inputTokens: 0, outputTokens: 0, sessionId: null, cancelled: false };
    active++;
    try {
      for await (const m of query({ prompt: r.prompt, options })) {
        r.onMessage?.(m);
        if (m.type === 'system' && m.subtype === 'init') out.sessionId = m.session_id;
        else if (m.type === 'assistant' && m.error) out.error = m.error;
        else if (m.type === 'result') {
          const u = m.usage;
          // On a resumed session the SDK reports the session's running total, so the ledger takes the difference.
          const key = `agent:cost:${m.session_id}`;
          const before = r.resume ? ctx.repos.kv.get<number>(key) ?? 0 : 0;
          out.costUsd = m.total_cost_usd >= before ? m.total_cost_usd - before : m.total_cost_usd;
          if (r.persist) ctx.repos.kv.set(key, m.total_cost_usd);
          // A query can deliver more than one result: usage is per result, cost is the running total.
          out.inputTokens += u.input_tokens + u.cache_creation_input_tokens + u.cache_read_input_tokens;
          out.outputTokens += u.output_tokens;
          log.info(`run ${r.kind} ${m.subtype}: ${m.num_turns} turns, input ${u.input_tokens} + cache write ${u.cache_creation_input_tokens} + cache read ${u.cache_read_input_tokens}, output ${u.output_tokens}, $${out.costUsd.toFixed(5)}`);
          out.ok = !m.is_error;
          if (m.subtype === 'success') {
            out.text = m.result;
            out.structured = m.structured_output;
          } else out.error = m.subtype;
          if (m.is_error && !out.error) out.error = out.text || 'run failed';
        }
      }
    } catch (err) {
      out.cancelled = !!r.abort?.signal.aborted;
      // The SDK throws after it has already delivered an error result (max turns); keep that result's numbers.
      if (!out.error) out.error = out.cancelled ? 'cancelled' : (err as Error).message ?? String(err);
      out.ok = false;
    } finally {
      active--;
    }
    if (out.error === 'authentication_failed') ctx.repos.health.set(r.billing === 'api' ? 'agent:api' : 'agent:login', 'error');
    else if (out.ok) ctx.repos.health.set(r.billing === 'api' ? 'agent:api' : 'agent:login', 'ok');
    ctx.repos.health.set('agent', out.ok || out.cancelled ? 'ok' : 'error');
    if (!out.ok && !out.cancelled) log.warn(`run ${r.kind} failed: ${out.error}`);
    ctx.cost.finish(runId, {
      status: out.cancelled ? 'cancelled' : out.ok ? 'ok' : 'error',
      inputTokens: out.inputTokens,
      outputTokens: out.outputTokens,
      costUsd: out.costUsd,
      summary: (out.ok ? out.text : out.error ?? '').slice(0, 200) || null,
    });
    return out;
  }

  return { run, connectors, busy: () => active > 0, policy: () => basePolicy(ctx.paths.agentDir), sandboxEnv };
}

export type Engine = ReturnType<typeof createEngine>;
