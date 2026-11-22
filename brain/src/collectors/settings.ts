import { execFile } from 'node:child_process';
import { accessSync, constants } from 'node:fs';
import { homedir } from 'node:os';
import { delimiter, join } from 'node:path';
import type { Config, ConnectorConfig } from '../core/config.js';
import type { AppContext } from '../core/context.js';
import { deepMerge } from '../core/util.js';

export interface BadgeApp { id: string; family: string }

/**
 * Config keys the collectors and jobs read on top of the core defaults. They are not written to
 * config.json; a value there overrides the one here (objects merge, arrays replace).
 */
export const EXTRA = {
  code: {
    claudeDir: '~/.claude',
    claudeBin: '',
    ghBin: '',
    pollSec: 2.5,
    idleAfterHours: 12,
    editorApps: ['Code', 'Cursor', 'Zed', 'Windsurf', 'Xcode', 'Terminal', 'iTerm2', 'Ghostty', 'Warp', 'WezTerm', 'kitty', 'Alacritty'],
  },
  connectors: {
    chat: { servers: ['Slack', 'Teams', 'Discord'] },
    calendar: { servers: ['Calendar'] },
    tickets: { servers: ['Linear', 'Jira', 'Atlassian', 'Asana'] },
    meetings: { servers: ['Fathom', 'Meetings', 'Granola', 'Zoom', 'Gong'] },
    docs: { servers: ['Notion', 'Drive', 'Docs', 'Confluence'] },
    github: { enabled: true, everyMin: 5 },
    badges: {
      enabled: true,
      everySec: 15,
      apps: [
        { id: 'com.tinyspeck.slackmacgap', family: 'chat' },
        { id: 'com.microsoft.teams2', family: 'chat' },
        { id: 'com.hnc.Discord', family: 'chat' },
        { id: 'com.linear', family: 'tickets' },
        { id: 'notion.id', family: 'docs' },
        { id: 'com.apple.mail', family: 'mail' },
        { id: 'com.microsoft.Outlook', family: 'mail' },
        { id: 'com.apple.MobileSMS', family: 'messages' },
      ] as BadgeApp[],
    },
    browser: {
      historyPath: '',
      everyMin: 5,
      patterns: [
        'github\\.com/[^/]+/[^/]+/(pull|issues)/\\d+',
        'gitlab\\.com/.+/-/(merge_requests|issues)/\\d+',
        'linear\\.app/[^/]+/(issue|project)/',
        'atlassian\\.net/(browse|wiki)/',
        'docs\\.google\\.com/(document|spreadsheets|presentation)/d/',
        'notion\\.so/.+',
        'figma\\.com/(file|design|board)/',
      ],
    },
    messages: { everyMin: 2 },
  },
  nudges: { maxPer10Min: 3 },
  /** When something promised or started counts as left behind (`GET /loose-ends`). */
  looseEnds: {
    commitmentAfterDays: 2,
    sessionWaitingHours: 4,
    waitingSilentDays: 3,
    prStaleDays: 2,
    pageVisitDays: 3,
    pageWindowDays: 14,
    maxPerGroup: 8,
  },
};

export interface Settings extends Config {
  code: Config['code'] & typeof EXTRA.code;
  nudges: Config['nudges'] & typeof EXTRA.nudges;
  looseEnds: typeof EXTRA.looseEnds;
}

const merged = new WeakMap<Config, Settings>();

/** The effective config: core values with the keys above filled in. Cached until the config object is replaced. */
export function settings(ctx: AppContext): Settings {
  const config = ctx.config.get();
  let out = merged.get(config);
  if (!out) merged.set(config, (out = deepMerge(EXTRA as unknown as Settings, config)));
  return out;
}

export function connector<T = Record<string, never>>(ctx: AppContext, name: string): ConnectorConfig & T {
  return (settings(ctx).connectors[name] ?? { enabled: false }) as ConnectorConfig & T;
}

/** Reports a connector status, without a write when it is already that. */
export function setHealth(ctx: AppContext, name: string, status: 'ok' | 'error' | 'off'): void {
  if (ctx.repos.health.snapshot().connectors[name] !== status) ctx.repos.health.set(name, status);
}

export const expandHome = (p: string): string => (p === '~' || p.startsWith('~/') ? join(homedir(), p.slice(1)) : p);

export const clip = (s: string, max: number): string => (s.length > max ? s.slice(0, max - 1) + '…' : s);

export interface Ran { code: number; stdout: string; stderr: string }

/** Runs a program to completion. Never rejects: a spawn failure or timeout comes back as code -1. */
export function run(bin: string, args: string[], opts: { timeoutMs?: number; env?: NodeJS.ProcessEnv } = {}): Promise<Ran> {
  return new Promise((done) => {
    execFile(bin, args, { timeout: opts.timeoutMs ?? 15_000, maxBuffer: 32 * 1024 * 1024, env: opts.env ?? process.env }, (err, stdout, stderr) => {
      done({ code: err ? (typeof err.code === 'number' ? err.code : -1) : 0, stdout, stderr: stderr || (err?.message ?? '') });
    });
  });
}

const INSTALL_DIRS = ['~/.local/bin', '~/.claude/local', '/opt/homebrew/bin', '/usr/local/bin', '~/bin', '~/.bun/bin', '~/.npm-global/bin', '/usr/bin', '/bin'];
const RETRY_MISSING = 10 * 60_000;
const resolved = new Map<string, { path: string | null; at: number }>();

const executable = (path: string): boolean => {
  try {
    accessSync(path, constants.X_OK);
    return true;
  } catch {
    return false;
  }
};

/**
 * The app spawns the brain with launchd's minimal PATH, so `claude` and `gh` are rarely on it:
 * look in the usual install dirs as well, then ask a login shell once.
 */
export async function resolveBin(name: string, override = ''): Promise<string | null> {
  if (override) return executable(expandHome(override)) ? expandHome(override) : null;
  const hit = resolved.get(name);
  if (hit && (hit.path || Date.now() - hit.at < RETRY_MISSING)) return hit.path;
  const dirs = [...(process.env.PATH ?? '').split(delimiter).filter(Boolean), ...INSTALL_DIRS.map(expandHome)];
  let path = dirs.map((d) => join(d, name)).find(executable) ?? null;
  if (!path) {
    const shell = await run(process.env.SHELL || '/bin/zsh', ['-lc', `command -v ${name}`], { timeoutMs: 5000 });
    const line = shell.stdout.trim().split('\n').pop() ?? '';
    if (line.startsWith('/') && executable(line)) path = line;
  }
  resolved.set(name, { path, at: Date.now() });
  return path;
}

/** Ticket ids in `text` per `config.code.ticketPattern`, upper-cased, in order of appearance. */
export function ticketsIn(pattern: string, ...texts: (string | null | undefined)[]): string[] {
  let re: RegExp;
  try {
    // Bounded on both sides so "release-2024" does not yield "ELEASE-2024".
    re = new RegExp(`(?<![A-Za-z0-9])(?:${pattern})(?![A-Za-z0-9])`, 'g');
  } catch {
    return [];
  }
  const out: string[] = [];
  for (const text of texts) {
    for (const m of text?.match(re) ?? []) if (!out.includes(m.toUpperCase())) out.push(m.toUpperCase());
  }
  return out;
}
