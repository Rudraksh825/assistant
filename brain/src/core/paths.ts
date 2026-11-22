import { randomBytes } from 'node:crypto';
import { chmodSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const pkgRoot = resolve(fileURLToPath(import.meta.url), '../../..');

export const VERSION: string = JSON.parse(readFileSync(join(pkgRoot, 'package.json'), 'utf8')).version;

export interface Paths {
  home: string;
  configFile: string;
  secretsFile: string;
  tokenFile: string;
  portFile: string;
  dbFile: string;
  memoryDir: string;
  logsDir: string;
  agentDir: string;
  checkpointsDir: string;
  /** The Steward checkout this brain runs from (cwd for self-modify runs). */
  repoRoot: string;
}

export function resolvePaths(home = process.env.STEWARD_HOME || join(homedir(), 'Library', 'Application Support', 'Steward')): Paths {
  home = resolve(home);
  const p: Paths = {
    home,
    configFile: join(home, 'config.json'),
    secretsFile: join(home, 'secrets.env'),
    tokenFile: join(home, 'brain.token'),
    portFile: join(home, 'brain.port'),
    dbFile: join(home, 'steward.db'),
    memoryDir: join(home, 'memory'),
    logsDir: join(home, 'logs'),
    agentDir: join(home, 'agent'),
    checkpointsDir: join(home, 'checkpoints'),
    repoRoot: resolve(pkgRoot, '..'),
  };
  for (const dir of [p.home, p.memoryDir, p.logsDir, p.agentDir, p.checkpointsDir]) {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
  }
  chmodSync(p.home, 0o700);
  return p;
}

/** A fresh token per start: anything holding an old one loses access when the brain restarts. */
export function writeToken(p: Paths): string {
  const token = randomBytes(32).toString('hex');
  writePrivate(p.tokenFile, token);
  return token;
}

export function writePrivate(file: string, content: string): void {
  writeFileSync(file, content, { mode: 0o600 });
  chmodSync(file, 0o600);
}
