import { appendFileSync, renameSync, statSync } from 'node:fs';
import { join } from 'node:path';

const LEVELS = ['debug', 'info', 'warn', 'error', 'silent'] as const;
type Level = (typeof LEVELS)[number];

export interface Log {
  debug(msg: string, extra?: unknown): void;
  info(msg: string, extra?: unknown): void;
  warn(msg: string, extra?: unknown): void;
  error(msg: string, extra?: unknown): void;
  child(scope: string): Log;
}

export function createLog(logsDir: string, opts: { maxBytes?: number; level?: Level } = {}): Log {
  const file = join(logsDir, 'brain.log');
  const maxBytes = opts.maxBytes ?? 5 * 1024 * 1024;
  const envLevel = process.env.STEWARD_LOG_LEVEL as Level | undefined;
  const min = LEVELS.indexOf(opts.level ?? (envLevel && LEVELS.includes(envLevel) ? envLevel : 'info'));
  let size = 0;
  try { size = statSync(file).size; } catch { /* first run */ }

  const write = (level: Level, scope: string, msg: string, extra?: unknown) => {
    if (LEVELS.indexOf(level) < min) return;
    const detail = extra === undefined ? '' : ' ' + (extra instanceof Error ? extra.stack ?? extra.message : safeJson(extra));
    const line = `${new Date().toISOString()} ${level.toUpperCase().padEnd(5)} ${scope ? `[${scope}] ` : ''}${msg}${detail}\n`;
    process.stderr.write(line);
    try {
      if (size + line.length > maxBytes) {
        renameSync(file, file + '.1');
        size = 0;
      }
      appendFileSync(file, line, { mode: 0o600 });
      size += Buffer.byteLength(line);
    } catch { /* logging must never take the daemon down */ }
  };

  const make = (scope: string): Log => ({
    debug: (m, e) => write('debug', scope, m, e),
    info: (m, e) => write('info', scope, m, e),
    warn: (m, e) => write('warn', scope, m, e),
    error: (m, e) => write('error', scope, m, e),
    child: (s) => make(scope ? `${scope}:${s}` : s),
  });
  return make('');
}

function safeJson(v: unknown): string {
  try { return JSON.stringify(v); } catch { return String(v); }
}
