import { execFile } from 'node:child_process';
import { existsSync } from 'node:fs';
import type { AppContext } from '../core/context.js';
import type { Approval } from '../core/types.js';
import { isPlainObject } from '../core/util.js';
import { APPROVAL_HINT, decide, type Decision } from './guard.js';
import type { Engine } from './engine.js';
import { approvedProfile, SANDBOX_EXEC } from './sandbox.js';
import type { Self, SelfModifyInput } from './self.js';

export const REBUILD_TOOL = 'app_rebuild';

const clip = (text: string, max: number) => (text.length > max ? `${text.slice(0, max)}…` : text);
const asText = (v: unknown) => (typeof v === 'string' ? v : JSON.stringify(v));

/** Why the guard wants the user to see this, in the guard's words. Shown on the approval card; never the agent's text. */
export function approvalNote(verdict: Decision): string {
  if (verdict.verdict === 'deny') return verdict.reason.replace(APPROVAL_HINT, '').trim();
  if (verdict.verdict === 'sandbox') return `Left alone, this command runs in the sandbox (${verdict.why}). Approving runs it outside, with network access and whatever it does there; the protected paths and the secrets stay out of its reach.`;
  return '';
}

export interface ExecutorDeps {
  ctx: AppContext;
  engine: Engine;
  self: Self;
  fastModel: () => string;
  serverOf: (tool: string) => Promise<string | undefined>;
  during: <T>(text: string, fn: () => Promise<T>) => Promise<T>;
}

/** Carries out what the user approved, and nothing the user could not have approved. */
export function createExecutor({ ctx, engine, self, fastModel, serverOf, during }: ExecutorDeps) {
  /**
   * Why this payload cannot be queued or run, or null. Called when the agent asks and again when the user approves,
   * so an input edited on the card is held to the same rules as the one first shown.
   */
  function check(approval: Pick<Approval, 'tool' | 'input'>, edited = false): string | null {
    const { tool, input } = approval;
    if (!isPlainObject(input)) return 'The input must be a JSON object';
    if (tool === REBUILD_TOOL) return edited ? 'A rebuild approval covers one exact source tree and cannot be edited' : typeof input.tree === 'string' ? null : 'A rebuild approval needs the tree it was made for';
    if (tool === 'Bash') {
      if (typeof input.command !== 'string' || !input.command.trim()) return 'Bash input needs a command string';
      if (input.cwd !== undefined && typeof input.cwd !== 'string') return 'cwd must be a path';
      if (Object.keys(input).some((k) => k !== 'command' && k !== 'cwd')) return 'Bash input takes command and cwd only';
      // Approval lifts the external-write block and the sandbox; what is never allowed stays never allowed.
      const verdict = decide('Bash', { command: input.command }, engine.policy());
      return verdict.verdict === 'deny' && !verdict.approvable ? verdict.reason : null;
    }
    if (!tool.startsWith('mcp__') || tool.startsWith('mcp__steward__')) return `Steward cannot execute ${tool}`;
    return null;
  }

  async function execute(approval: Approval): Promise<{ ok: boolean; result: string }> {
    const { tool, input } = approval;
    const problem = check(approval);
    if (problem) return { ok: false, result: problem };

    if (tool === REBUILD_TOOL) {
      const out = await self.rebuild({ approvedTree: (input as unknown as SelfModifyInput).tree });
      return { ok: out.ok, result: out.ok ? 'Built; the app is relaunching.' : out.log.slice(-1500) };
    }

    if (tool === 'Bash') {
      const command = input.command as string;
      if (!existsSync(SANDBOX_EXEC)) return { ok: false, result: `${SANDBOX_EXEC} is missing, so the protected paths cannot be kept out of reach; nothing was run` };
      const cwd = typeof input.cwd === 'string' && existsSync(input.cwd) ? input.cwd : ctx.paths.repoRoot;
      // The command itself may be anything the user read and approved; the kernel still refuses the protected paths and the secrets to it.
      return during('Running an approved command', () => new Promise((resolve) => {
        execFile(SANDBOX_EXEC, ['-p', approvedProfile(engine.sandboxEnv()), '/bin/bash', '-c', command], { cwd, timeout: 120_000, maxBuffer: 4 * 1024 * 1024 }, (err, stdout, stderr) => {
          const output = `${stdout}${stderr}`.trim().slice(-1500);
          resolve({ ok: !err, result: err ? `${output}\n(${err.killed ? 'timed out after 120s' : `exit ${err.code ?? err.message}`})`.trim() : output || 'Done (no output)' });
        });
      }));
    }

    const server = await serverOf(tool);
    if (!server) return { ok: false, result: `${tool} is not a tool of a connected connector` };
    let captured: unknown;
    const res = await during('Carrying out an approved action', () => engine.run({
      kind: 'approval', trigger: 'user', model: fastModel(), billing: 'login', effort: 'low', maxTurns: 6,
      connectors: [server], policy: { exact: { tool, input, approved: true } },
      system: 'You carry out exactly one approved tool call and nothing else.',
      prompt: `The user approved this action. Call ${tool} exactly once with exactly this JSON input: the same keys and values, no optional parameters added (load it with ToolSearch "select:${tool}" if needed):\n${JSON.stringify(input)}\nThen reply "done".`,
      onToolResult(name, response) {
        if (name !== tool) return undefined;
        captured = response;
        return 'captured';
      },
    }));
    if (captured === undefined) return { ok: false, result: `The action did not run: ${res.error ?? clip(res.text, 300)}` };
    return { ok: true, result: clip(asText(captured), 1500) };
  }

  return { check, execute };
}
