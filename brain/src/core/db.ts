import { DatabaseSync } from 'node:sqlite';
import { migrations } from './migrations/index.js';
import { invalid, isPlainObject, notFound } from './util.js';

export type Db = DatabaseSync;
export type Param = string | number | null;

export function openDb(file: string): Db {
  const db = new DatabaseSync(file);
  db.exec('PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;');
  const { user_version } = db.prepare('PRAGMA user_version').get() as { user_version: number };
  for (let v = user_version; v < migrations.length; v++) {
    tx(db, () => db.exec(`${migrations[v]}; PRAGMA user_version = ${v + 1};`));
  }
  return db;
}

export function tx<T>(db: Db, fn: () => T): T {
  db.exec('BEGIN');
  try {
    const out = fn();
    db.exec('COMMIT');
    return out;
  } catch (err) {
    db.exec('ROLLBACK');
    throw err;
  }
}

/** s string, n number, b boolean (stored 0/1), a array and o object (stored as JSON text). */
export type Kind = 's' | 'n' | 'b' | 'a' | 'o';
export type Cols<T> = { [K in keyof T & string]-?: Kind };

const fits: Record<Kind, (v: unknown) => boolean> = {
  s: (v) => typeof v === 'string',
  n: (v) => typeof v === 'number' && Number.isFinite(v),
  b: (v) => typeof v === 'boolean',
  a: Array.isArray,
  o: isPlainObject,
};

/** A table whose columns are exactly the fields of T. `onWrite` fires after every mutation. */
export class Table<T extends { id: string }> {
  private kinds: Record<string, Kind>;
  private keys: string[];

  constructor(private db: Db, readonly name: string, cols: Cols<T>, private onWrite: () => void = () => {}) {
    this.kinds = cols;
    this.keys = Object.keys(cols);
  }

  get(id: string): T | null {
    const row = this.db.prepare(`SELECT * FROM ${this.name} WHERE id = ?`).get(id);
    return row ? this.decode(row) : null;
  }

  must(id: string): T {
    const row = typeof id === 'string' ? this.get(id) : null;
    if (!row) throw notFound(this.name.replace(/^chat_/, '').replace(/s$/, ''));
    return row;
  }

  /** `tail` is everything after `SELECT * FROM <table>`: WHERE, ORDER BY, LIMIT. */
  where(tail = '', ...params: Param[]): T[] {
    return this.db.prepare(`SELECT * FROM ${this.name} ${tail}`).all(...params).map(this.decode);
  }

  count(tail = '', ...params: Param[]): number {
    return (this.db.prepare(`SELECT COUNT(*) AS n FROM ${this.name} ${tail}`).get(...params) as { n: number }).n;
  }

  insert(row: T): T {
    const sql = `INSERT INTO ${this.name} (${this.keys.map((k) => `"${k}"`).join(', ')}) VALUES (${this.keys.map(() => '?').join(', ')})`;
    this.db.prepare(sql).run(...this.keys.map((k) => this.encode(k, (row as Record<string, unknown>)[k])));
    this.onWrite();
    return row;
  }

  /** The fields of `patch` whose stored value would actually change. */
  changes(current: T, patch: Partial<T>): Partial<T> {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(patch)) {
      if (k in this.kinds && k !== 'id' && this.encode(k, v) !== this.encode(k, (current as Record<string, unknown>)[k])) out[k] = v;
    }
    return out as Partial<T>;
  }

  /** Writes only what differs; a patch that changes nothing is not a mutation and fires no `onWrite`. */
  update(id: string, patch: Partial<T>): T {
    const current = this.must(id);
    const diff = this.changes(current, patch) as Record<string, unknown>;
    const keys = Object.keys(diff);
    if (!keys.length) return current;
    const sql = `UPDATE ${this.name} SET ${keys.map((k) => `"${k}" = ?`).join(', ')} WHERE id = ?`;
    this.db.prepare(sql).run(...keys.map((k) => this.encode(k, diff[k])), id);
    this.onWrite();
    return this.must(id);
  }

  delete(id: string): void {
    this.must(id);
    this.db.prepare(`DELETE FROM ${this.name} WHERE id = ?`).run(id);
    this.onWrite();
  }

  /** Untrusted input → the known, correctly typed fields. Unknown keys are dropped; null is left for the schema to judge. */
  pick(input: unknown, deny: readonly string[] = []): Partial<T> {
    if (!isPlainObject(input)) throw invalid('expected a JSON object');
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(input)) {
      const kind = this.kinds[k];
      if (!kind || v === undefined || deny.includes(k)) continue;
      if (v !== null && !fits[kind](v)) throw invalid(`${k}: wrong type`);
      out[k] = v;
    }
    return out as Partial<T>;
  }

  private decode = (row: Record<string, unknown>): T => {
    for (const k of this.keys) {
      const kind = this.kinds[k];
      if (kind === 'b') row[k] = !!row[k];
      else if ((kind === 'a' || kind === 'o') && typeof row[k] === 'string') row[k] = JSON.parse(row[k]);
    }
    return row as T;
  };

  private encode(k: string, v: unknown): Param {
    if (v === null || v === undefined) return null;
    const kind = this.kinds[k];
    if (kind === 'b') return v ? 1 : 0;
    if (kind === 'a' || kind === 'o') return JSON.stringify(v);
    return v as Param;
  }
}
