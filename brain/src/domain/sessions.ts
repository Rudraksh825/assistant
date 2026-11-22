import { Table } from '../core/db.js';
import type { CodeSession, Id } from '../core/types.js';
import { invalid } from '../core/util.js';
import type { Deps } from './crud.js';

export function createSessions({ db, bus }: Deps) {
  const table = new Table<CodeSession>(db, 'sessions', {
    id: 's', pid: 'n', name: 's', cwd: 's', repo: 's', branch: 's', ticket: 's', state: 's', stateSince: 'n', title: 's',
    lastUserPrompt: 's', lastAssistantText: 's', pr: 'o', taskId: 's', notes: 's', startedAt: 'n', updatedAt: 'n',
  }, () => bus.changed('sessions'));

  return {
    get: (id: Id) => table.get(id),
    must: (id: Id) => table.must(id),

    list(includeEnded = false): CodeSession[] {
      return table.where(`${includeEnded ? '' : "WHERE state != 'ended'"} ORDER BY stateSince DESC`);
    },

    /** Every session linked to a task, ended ones included, most recently active first. */
    forTask: (taskId: Id): CodeSession[] => table.where('WHERE taskId = ? ORDER BY updatedAt DESC LIMIT 20', taskId),

    /** Sessions that ended since `since`. */
    endedSince: (since: number): CodeSession[] => table.where("WHERE state = 'ended' AND updatedAt >= ? ORDER BY updatedAt DESC LIMIT 100", since),

    /**
     * Insert or patch by session id. A state change resets `stateSince`. Nothing is written or announced
     * when the session is unchanged, so collectors can call this on every poll.
     */
    upsert(input: Partial<CodeSession> & { id: Id }): CodeSession {
      const now = Date.now();
      const given = table.pick(input, ['updatedAt']);
      if (!given.id) throw invalid('id is required');
      const current = table.get(given.id);
      const base: CodeSession = current ?? {
        id: given.id, pid: null, name: null, cwd: '', repo: null, branch: null, ticket: null, state: 'working', stateSince: now,
        title: null, lastUserPrompt: null, lastAssistantText: null, pr: null, taskId: null, notes: '', startedAt: now, updatedAt: now,
      };
      const next: CodeSession = { ...base, ...given };
      if (current && next.state !== current.state && given.stateSince == null) next.stateSince = now;
      if (current && JSON.stringify(next) === JSON.stringify(current)) return current;
      next.updatedAt = now;
      const saved = current ? table.update(next.id, next) : table.insert(next);
      bus.emit('session.updated', saved);
      return saved;
    },
  };
}
