import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve, sep } from 'node:path';
import type { Ms } from '../core/types.js';
import { invalid, notFound } from '../core/util.js';

export interface MemoryFile { path: string; size: number; updatedAt: Ms }

/** Markdown files under the data dir's `memory/`. Paths are relative to it and can never leave it. */
export function createMemory(memoryDir: string) {
  const root = resolve(memoryDir);
  const locate = (path: string): string => {
    if (typeof path !== 'string' || path.includes('\0')) throw invalid('bad memory path');
    const abs = resolve(root, path);
    if (!abs.startsWith(root + sep) || !abs.endsWith('.md')) throw invalid('memory paths must be .md files inside memory/');
    return abs;
  };

  return {
    root,

    list(): MemoryFile[] {
      return readdirSync(root, { recursive: true, withFileTypes: true })
        .filter((e) => e.isFile() && e.name.endsWith('.md'))
        .map((e) => {
          const abs = join(e.parentPath, e.name);
          const st = statSync(abs);
          return { path: relative(root, abs).split(sep).join('/'), size: st.size, updatedAt: Math.round(st.mtimeMs) };
        })
        .sort((a, b) => a.path.localeCompare(b.path));
    },

    read(path: string): { path: string; content: string; updatedAt: Ms } {
      const abs = locate(path);
      if (!existsSync(abs)) throw notFound('memory file');
      return { path, content: readFileSync(abs, 'utf8'), updatedAt: Math.round(statSync(abs).mtimeMs) };
    },

    write(path: string, content: string): MemoryFile {
      if (typeof content !== 'string') throw invalid('content must be a string');
      const abs = locate(path);
      mkdirSync(dirname(abs), { recursive: true, mode: 0o700 });
      writeFileSync(abs, content, { mode: 0o600 });
      return { path, size: Buffer.byteLength(content), updatedAt: Date.now() };
    },

    remove(path: string): void {
      const abs = locate(path);
      if (!existsSync(abs)) throw notFound('memory file');
      rmSync(abs);
    },
  };
}
