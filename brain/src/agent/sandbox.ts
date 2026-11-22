import type { Options } from '@anthropic-ai/claude-agent-sdk';
import { basename, join } from 'node:path';
import { protectedAncestors, protectedGlobs, protectedRoots, type Places } from './boundary.js';

export const SANDBOX_EXEC = '/usr/bin/sandbox-exec';

/** What the model is told when a sandboxed command fails, so it stops retrying variations and takes a route that works. */
export const SANDBOX_NOTE = [
  'This command ran in Steward\'s sandbox: no network at all (localhost included), and file writes only inside the Steward repo and data dir, minus the protected paths.',
  'If that is why it failed: network reads run outside the sandbox when they are a plain `gh` read (pr/issue/run view or list, `gh api` GET), `git fetch`, `git pull`, `git ls-remote`, `git clone <https url>`, or `curl -sS <https url>` (GET, simple flags), each written out literally with no variables, substitutions or interpreter around it, optionally piped through jq, grep, head, tail, wc, sort, uniq, cut or tr.',
  'Anything else that needs the network, another app or a path outside those folders needs the user\'s approval: call steward.request_approval with tool "Bash" and the exact command. Protected paths cannot be approved.',
].join(' ');

/** Output that says the sandbox, not the command, is what failed. */
export const SANDBOX_SIGNS = /sandbox_violations|Operation not permitted|CONNECT tunnel failed|Could not resolve host|Couldn't connect to server|Network is unreachable|nodename nor servname|ENOTFOUND|EPERM|ECONNREFUSED|EAI_AGAIN|\(-600\)|Connection refused/;

export interface SandboxEnv extends Places { writableRoots: string[]; secretFiles: string[] }

/**
 * Claude Code's own macOS sandbox (Seatbelt) for the agent's Bash tool. Every command runs inside it unless the guard
 * hook lifts it for that one call. No domain is allowed, so nothing inside reaches the network, loopback included;
 * writes are limited to the roots below, minus everything the boundary protects.
 */
export function sandboxSettings(env: SandboxEnv): NonNullable<Options['sandbox']> {
  const roots = [env.repoRoot, env.dataDir, ...env.writableRoots];
  return {
    enabled: true,
    // A machine where the sandbox cannot start gets no Bash at all rather than an unconfined one.
    failIfUnavailable: true,
    autoAllowBashIfSandboxed: false,
    // Lifted per call by the hook, for the network reads the guard recognises word for word.
    allowUnsandboxedCommands: true,
    network: { allowedDomains: [], allowLocalBinding: false, allowAllUnixSockets: false, allowUnixSockets: [] },
    filesystem: {
      allowWrite: roots,
      denyWrite: [...protectedRoots(env), ...roots.flatMap(protectedGlobs)],
      denyRead: env.secretFiles,
    },
    credentials: { envVars: ['ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN'].map((name) => ({ name, mode: 'deny' as const })) },
  };
}

const quote = (path: string) => `"${path.replace(/[\\"]/g, '\\$&')}"`;
const literal = (name: string) => name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/**
 * Seatbelt profile for a command the user approved. It is meant to reach the network and other apps, so everything is
 * allowed except what no approval covers: writing the protected paths and reading the secrets. `.git` stays writable
 * apart from its hooks (an approved push or commit has to update refs), as does gh's own config.
 */
export function approvedProfile(env: SandboxEnv): string {
  const kept = (path: string) => basename(path) !== '.git' && !path.endsWith(join('.config', 'gh'));
  const names = { dirs: ['.claude', '.cursor', '.vscode', '.idea', '.github', '.husky'], files: ['CLAUDE.md', 'CLAUDE.local.md', 'AGENTS.md', '.mcp.json', '.cursorrules', '.envrc'] };
  const roots = [env.repoRoot, env.dataDir, ...env.writableRoots];
  const scoped = (pattern: string) => roots.map((root) => `(regex #"^${literal(root)}/(.*/)?${pattern}")`).join(' ');
  return [
    '(version 1)',
    '(allow default)',
    `(deny file-write* ${protectedRoots(env).filter(kept).map((path) => `(subpath ${quote(path)})`).join(' ')})`,
    `(deny file-write* ${scoped(`(${names.dirs.map(literal).join('|')})(/|$)`)} ${scoped(`(${names.files.map(literal).join('|')})$`)} ${scoped('\\.git/hooks(/|$)')})`,
    // Renaming a folder above a protected file would leave the rule pointing at nothing.
    `(deny file-write-unlink ${protectedAncestors(env).map((path) => `(literal ${quote(path)})`).join(' ')})`,
    ...(env.secretFiles.length ? [`(deny file-read* ${env.secretFiles.map((path) => `(literal ${quote(path)})`).join(' ')})`] : []),
  ].join('\n');
}
