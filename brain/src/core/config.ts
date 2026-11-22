import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, renameSync } from 'node:fs';
import type { Bus } from './bus.js';
import type { Log } from './log.js';
import { writePrivate, type Paths } from './paths.js';
import { deepMerge, invalid, isPlainObject } from './util.js';

export interface ConnectorConfig { enabled: boolean; everyMin?: number; [key: string]: unknown }

export interface Config {
  port: number;
  user: { name: string; workHours: { start: string; end: string; days: number[] }; timezone: string };
  models: { main: string; fast: string };
  agent: { billing: 'login' | 'api'; writableRoots: string[]; effort: string; selfModify: 'auto' | 'ask' };
  budget: { dailyCapUsd: number; monthlyCapUsd: number };
  code: { roots: string[]; ticketPattern: string; scanDepth: number };
  connectors: Record<string, ConnectorConfig>;
  nudges: { sessionWaitingAfterSec: number; meetingLeadMin: number; quietHours: { start: string; end: string } | null };
  hotkeys: Record<string, string>;
  ui: { hudDisplay: string; notchOnAllDisplays: boolean; haptics: boolean; sounds: boolean };
}

export const DEFAULTS: Config = {
  port: 47600,
  user: { name: '', workHours: { start: '09:00', end: '19:00', days: [1, 2, 3, 4, 5] }, timezone: '' },
  models: { main: 'claude-opus-5-5', fast: 'claude-haiku-5-5' },
  agent: { billing: 'login', writableRoots: [], effort: 'medium', selfModify: 'ask' },
  budget: { dailyCapUsd: 15, monthlyCapUsd: 300 },
  code: { roots: ['~'], ticketPattern: '[A-Za-z]{2,6}-\\d+', scanDepth: 1 },
  connectors: {
    chat: { enabled: true, everyMin: 15 },
    calendar: { enabled: true, everyMin: 30 },
    tickets: { enabled: true, everyMin: 20 },
    meetings: { enabled: true, everyMin: 60 },
    docs: { enabled: false, everyMin: 720 },
    messages: { enabled: false },
    browser: { enabled: true },
  },
  nudges: { sessionWaitingAfterSec: 45, meetingLeadMin: 3, quietHours: null },
  hotkeys: { capture: 'ctrl+opt+space', agent: 'ctrl+opt+a', voice: 'ctrl+opt+v', hud: 'ctrl+opt+h', notch: 'ctrl+opt+n' },
  ui: { hudDisplay: 'auto', notchOnAllDisplays: true, haptics: true, sounds: false },
};

const SECRET_NAME = /^[A-Z][A-Z0-9_]*$/;

export class ConfigStore {
  private value: Config;

  constructor(private paths: Paths, private bus: Bus, log: Log) {
    let user: unknown = {};
    if (existsSync(paths.configFile)) {
      try {
        user = JSON.parse(readFileSync(paths.configFile, 'utf8'));
        checkShape(DEFAULTS, user, 'config');
      } catch (err) {
        // Keep the user's file untouched so a typo does not cost them their settings.
        log.warn(`config.json ignored, running on defaults: ${(err as Error).message}`);
        user = {};
      }
      this.value = deepMerge(DEFAULTS, user);
      // The schedule of every timed job is built from these: one bad string must not stop them all from registering.
      const problem = workHoursProblem(this.value.user.workHours);
      if (problem) {
        log.warn(`config.json user.workHours ignored, using the defaults: ${problem}`);
        this.value.user.workHours = structuredClone(DEFAULTS.user.workHours);
      }
    } else {
      this.value = structuredClone(DEFAULTS);
      this.value.user.name = accountName();
      this.persist();
    }
  }

  get(): Config {
    return this.value;
  }

  /** Deep-merges a partial config, persists it and announces `state.changed{settings}`. */
  update(patch: unknown): Config {
    if (!isPlainObject(patch)) throw invalid('settings must be a JSON object');
    checkShape(DEFAULTS, patch, 'settings');
    const next = deepMerge(this.value, patch);
    const problem = workHoursProblem(next.user.workHours);
    if (problem) throw invalid(`user.workHours: ${problem}`);
    if (next.agent.selfModify !== 'auto' && next.agent.selfModify !== 'ask') throw invalid('agent.selfModify must be "auto" or "ask"');
    this.value = next;
    this.persist();
    this.bus.changed('settings');
    return this.value;
  }

  secret(name: string): string | undefined {
    return this.readSecrets()[name];
  }

  secretNames(): string[] {
    return Object.keys(this.readSecrets());
  }

  /** An empty value removes the secret. */
  setSecret(name: string, value: string): void {
    if (!SECRET_NAME.test(name)) throw invalid('secret name must look like UPPER_SNAKE_CASE');
    if (/[\r\n]/.test(value)) throw invalid('secret value must be a single line');
    const all = this.readSecrets();
    if (value) all[name] = value;
    else delete all[name];
    writePrivate(this.paths.secretsFile, Object.entries(all).map(([k, v]) => `${k}=${v}\n`).join(''));
    this.bus.changed('settings');
  }

  private readSecrets(): Record<string, string> {
    const out: Record<string, string> = {};
    if (!existsSync(this.paths.secretsFile)) return out;
    for (const line of readFileSync(this.paths.secretsFile, 'utf8').split('\n')) {
      const m = /^\s*(?:export\s+)?([A-Z][A-Z0-9_]*)\s*=\s*(.*?)\s*$/.exec(line);
      if (m) out[m[1]!] = m[2]!.replace(/^(['"])(.*)\1$/, '$2');
    }
    return out;
  }

  private persist(): void {
    const tmp = this.paths.configFile + '.tmp';
    writePrivate(tmp, JSON.stringify(this.value, null, 2) + '\n');
    renameSync(tmp, this.paths.configFile);
  }
}

/** The macOS account's full name, so a first run already knows who "the user" is. Empty when it cannot be read, and in test runs. */
function accountName(): string {
  if (process.env.NODE_TEST_CONTEXT) return '';
  try {
    return execFileSync('/usr/bin/id', ['-F'], { encoding: 'utf8', timeout: 2000 }).trim();
  } catch {
    return '';
  }
}

const HHMM = /^([01]?\d|2[0-3]):[0-5]\d$/;
function workHoursProblem(hours: Config['user']['workHours']): string | null {
  if (!HHMM.test(hours.start) || !HHMM.test(hours.end)) return `start and end must be HH:MM, got "${hours.start}" and "${hours.end}"`;
  if (!hours.days.every((d) => Number.isInteger(d) && d >= 0 && d <= 6)) return 'days must be weekday numbers 0..6';
  return null;
}

// Unknown keys pass (connectors and hotkeys are open maps); known keys must keep their default's type.
function checkShape(shape: unknown, value: unknown, path: string): void {
  if (shape === null || shape === undefined) return;
  const want = Array.isArray(shape) ? 'array' : typeof shape;
  const got = value === null ? 'null' : Array.isArray(value) ? 'array' : typeof value;
  if (want !== got) throw invalid(`${path}: expected ${want}, got ${got}`);
  if (isPlainObject(shape) && isPlainObject(value)) {
    for (const [k, v] of Object.entries(value)) if (k in shape) checkShape(shape[k], v, `${path}.${k}`);
  }
}
