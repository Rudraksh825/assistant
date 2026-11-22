import { Table, type Param } from '../core/db.js';
import type { ItemContext, Note, Person, Signal, SourceKind, Ms } from '../core/types.js';
import { invalid, newId } from '../core/util.js';
import { crud, type Deps } from './crud.js';

export function createNotes({ db, bus }: Deps) {
  const table = new Table<Note>(db, 'notes', {
    id: 's', kind: 's', title: 's', body: 's', taskId: 's', meetingId: 's', pinned: 'b', createdAt: 'n', updatedAt: 'n',
  }, () => bus.changed('notes'));
  return {
    ...crud<Note>(table, (now) => ({ id: newId(), kind: 'journal', title: '', body: '', taskId: null, meetingId: null, pinned: false, createdAt: now, updatedAt: now })),
    list(f: { kind?: string; taskId?: string; meetingId?: string; q?: string; limit?: number } = {}): Note[] {
      const where: string[] = [];
      const params: Param[] = [];
      for (const key of ['kind', 'taskId', 'meetingId'] as const) {
        if (f[key]) {
          where.push(`${key} = ?`);
          params.push(f[key]);
        }
      }
      if (f.q) {
        where.push('(title LIKE ? OR body LIKE ?)');
        params.push(`%${f.q}%`, `%${f.q}%`);
      }
      return table.where(`${where.length ? `WHERE ${where.join(' AND ')}` : ''} ORDER BY pinned DESC, updatedAt DESC LIMIT ?`, ...params, f.limit ?? 200);
    },
    /** The scratchpad the HUD shows: the most recently edited `live` note. */
    live: (): Note | null => table.where("WHERE kind = 'live' ORDER BY updatedAt DESC LIMIT 1")[0] ?? null,
  };
}

export function createPeople({ db, bus }: Deps) {
  const table = new Table<Person>(db, 'people', { id: 's', name: 's', handles: 'o', notes: 's', lastContactAt: 'n' }, () => bus.changed('people'));
  const base = crud(table, () => ({ id: newId(), name: '', handles: {}, notes: '', lastContactAt: null }), ['name']);
  return {
    ...base,
    list(q?: string): Person[] {
      return q ? table.where('WHERE name LIKE ? OR handles LIKE ? ORDER BY name COLLATE NOCASE', `%${q}%`, `%${q}%`) : table.where('ORDER BY name COLLATE NOCASE');
    },
    /** Find by name (case-insensitive) and merge, or create. Handles merge key by key. */
    upsert(input: Partial<Person> & { name: string }): Person {
      const existing = table.where('WHERE name = ? COLLATE NOCASE LIMIT 1', input.name)[0];
      if (!existing) return base.create(input);
      return base.update(existing.id, { ...input, handles: { ...existing.handles, ...input.handles } });
    },
  };
}

export type SignalInput = Pick<Signal, 'source' | 'kind' | 'externalId' | 'title'> & Partial<Signal>;

export function createSignals({ db }: Deps) {
  const table = new Table<Signal>(db, 'signals', {
    id: 's', source: 's', kind: 's', externalId: 's', title: 's', body: 's', url: 's', actor: 's', occurredAt: 'n',
    payload: 'o', triage: 's', processedAt: 'n',
  });
  return {
    get: (id: string) => table.get(id),
    find: (source: string, externalId: string): Signal | null => table.where('WHERE source = ? AND externalId = ? LIMIT 1', source, externalId)[0] ?? null,
    /** Signals pointing at one of `urls`, newest first. */
    byUrl(urls: string[], limit = 20): Signal[] {
      if (!urls.length) return [];
      return table.where(`WHERE url IN (${urls.map(() => '?').join(', ')}) ORDER BY occurredAt DESC LIMIT ?`, ...urls, limit);
    },
    /** The most recent signal from each actor, as lower-cased name -> time. */
    lastByActor(since: Ms): Map<string, Ms> {
      const rows = db.prepare('SELECT lower(actor) AS actor, MAX(occurredAt) AS at FROM signals WHERE actor IS NOT NULL AND occurredAt >= ? GROUP BY lower(actor)').all(since) as { actor: string; at: Ms }[];
      return new Map(rows.map((r) => [r.actor, r.at]));
    },

    /** Stores the signals not seen before (by source + externalId) and returns only those. */
    ingest(inputs: SignalInput[]): Signal[] {
      const fresh: Signal[] = [];
      for (const input of inputs) {
        const given = table.pick(input, ['id']);
        if (!given.source || !given.externalId) throw invalid('a signal needs source and externalId');
        if (table.count('WHERE source = ? AND externalId = ?', given.source, given.externalId)) continue;
        fresh.push(table.insert({
          id: newId(), source: 'manual', kind: '', externalId: '', title: '', body: '', url: null, actor: null,
          occurredAt: Date.now(), payload: {}, triage: 'new', processedAt: null, ...given,
        }));
      }
      return fresh;
    },

    list(f: { source?: SourceKind | string; since?: Ms; triage?: Signal['triage']; q?: string; limit?: number } = {}): Signal[] {
      const where: string[] = [];
      const params: Param[] = [];
      if (f.source) { where.push('source = ?'); params.push(f.source); }
      if (f.since) { where.push('occurredAt >= ?'); params.push(f.since); }
      if (f.triage) { where.push('triage = ?'); params.push(f.triage); }
      if (f.q) { where.push('(title LIKE ? OR body LIKE ?)'); params.push(`%${f.q}%`, `%${f.q}%`); }
      return table.where(`${where.length ? `WHERE ${where.join(' AND ')}` : ''} ORDER BY occurredAt DESC LIMIT ?`, ...params, f.limit ?? 200);
    },

    setTriage(ids: string[], triage: Signal['triage']): void {
      for (const id of ids) table.update(id, { triage, processedAt: Date.now() });
    },
  };
}

/** One row per subject: what "See more" fetched and the reply drafted for it. */
export function createContexts({ db, bus }: Deps) {
  const table = new Table<ItemContext>(db, 'item_context', {
    id: 's', subject: 's', status: 's', body: 's', error: 's', fetchedAt: 'n', costUsd: 'n',
    draftStatus: 's', draft: 's', draftApprovalId: 's', draftNote: 's', draftAt: 'n', createdAt: 'n', updatedAt: 'n',
  }, () => bus.changed('places'));

  // A run still marked running on disk belongs to a process that died mid-run.
  db.prepare("UPDATE item_context SET status = CASE WHEN body = '' THEN 'failed' ELSE 'ok' END, error = CASE WHEN body = '' THEN 'Interrupted by a restart.' ELSE error END WHERE status = 'running'").run();
  db.prepare("UPDATE item_context SET draftStatus = 'failed', draftNote = 'Interrupted by a restart.' WHERE draftStatus = 'running'").run();

  const bySubject = (subject: string): ItemContext | null => table.where('WHERE subject = ? LIMIT 1', subject)[0] ?? null;
  return {
    get: bySubject,
    /** Patch the subject's row, creating it on first use. */
    set(subject: string, patch: Partial<ItemContext>): ItemContext {
      const now = Date.now();
      const current = bySubject(subject);
      if (current) return table.update(current.id, { ...patch, updatedAt: now });
      return table.insert({
        id: newId(), subject, status: null, body: '', error: null, fetchedAt: null, costUsd: 0,
        draftStatus: null, draft: null, draftApprovalId: null, draftNote: null, draftAt: null, ...patch, createdAt: now, updatedAt: now,
      });
    },
  };
}

export type ConnectorStatus = 'ok' | 'error' | 'off' | 'unknown';

export function createKv({ db }: Deps) {
  return {
    get<T>(key: string): T | null {
      const row = db.prepare('SELECT value FROM kv WHERE key = ?').get(key) as { value: string } | undefined;
      return row ? (JSON.parse(row.value) as T) : null;
    },
    set(key: string, value: unknown): void {
      db.prepare('INSERT INTO kv (key, value, updatedAt) VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value, updatedAt = excluded.updatedAt')
        .run(key, JSON.stringify(value), Date.now());
    },
    delete(key: string): void {
      db.prepare('DELETE FROM kv WHERE key = ?').run(key);
    },
  };
}

/** Connector reachability for `/state.health`. Collectors report here; it survives restarts. */
export function createHealth(kv: ReturnType<typeof createKv>) {
  const state = kv.get<{ connectors: Record<string, ConnectorStatus>; lastSyncAt: Record<string, Ms> }>('health') ?? { connectors: {}, lastSyncAt: {} };
  return {
    set(name: string, status: ConnectorStatus): void {
      state.connectors[name] = status;
      kv.set('health', state);
    },
    /** Marks a successful sync: status ok, lastSyncAt now. */
    synced(name: string, at: Ms = Date.now()): void {
      state.connectors[name] = 'ok';
      state.lastSyncAt[name] = at;
      kv.set('health', state);
    },
    snapshot: () => structuredClone(state),
  };
}
