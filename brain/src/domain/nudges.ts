import { Table } from '../core/db.js';
import type { Id, Ms, Nudge, NudgeAction } from '../core/types.js';
import { invalid, newId, notFound } from '../core/util.js';
import type { Deps } from './crud.js';

export type NudgeInput = Pick<Nudge, 'kind' | 'title'> & Partial<Nudge>;

export function createNudges({ db, bus }: Deps) {
  const table = new Table<Nudge>(db, 'nudges', {
    id: 's', kind: 's', title: 's', body: 's', priority: 'n', actions: 'a', dedupeKey: 's', createdAt: 'n', expiresAt: 'n', dismissedAt: 'n',
  }, () => bus.changed('nudges'));

  const nudges = {
    get: (id: Id) => table.get(id),

    /**
     * At most one nudge per `dedupeKey`, ever: a second create with the same key returns the first nudge
     * (even a dismissed one) and shows nothing. Put a time bucket in the key for nudges that may repeat.
     */
    create(input: NudgeInput): Nudge {
      const given = table.pick(input, ['id', 'createdAt', 'dismissedAt']);
      if (given.dedupeKey) {
        const existing = table.where('WHERE dedupeKey = ? LIMIT 1', given.dedupeKey)[0];
        if (existing) return existing;
      }
      const nudge = table.insert({
        id: newId(), kind: 'system', title: '', body: '', priority: 0, actions: [], dedupeKey: null,
        expiresAt: null, ...given, createdAt: Date.now(), dismissedAt: null,
      });
      bus.emit('nudge', nudge);
      return nudge;
    },

    active(now: Ms = Date.now()): Nudge[] {
      return table.where('WHERE dismissedAt IS NULL AND (expiresAt IS NULL OR expiresAt > ?) ORDER BY priority DESC, createdAt DESC', now);
    },

    dismiss(id: Id): Nudge {
      const nudge = table.must(id);
      if (nudge.dismissedAt !== null) return nudge;
      const saved = table.update(id, { dismissedAt: Date.now() });
      bus.emit('nudge.dismissed', { id });
      return saved;
    },

    dismissByKey(dedupeKey: string): void {
      for (const n of table.where('WHERE dedupeKey = ? AND dismissedAt IS NULL', dedupeKey)) nudges.dismiss(n.id);
    },

    /** Dismisses everything past its expiry so surfaces drop it. */
    expire(now: Ms = Date.now()): number {
      const due = table.where('WHERE dismissedAt IS NULL AND expiresAt IS NOT NULL AND expiresAt <= ?', now);
      for (const n of due) nudges.dismiss(n.id);
      return due.length;
    },

    /** Resolves the chosen action and dismisses the nudge. The caller carries the action out. */
    act(id: Id, actionId: string): { nudge: Nudge; action: NudgeAction } {
      if (typeof actionId !== 'string') throw invalid('actionId is required');
      const action = table.must(id).actions.find((a) => a.id === actionId);
      if (!action) throw notFound('nudge action');
      return { nudge: nudges.dismiss(id), action };
    },
  };
  return nudges;
}

export type Nudges = ReturnType<typeof createNudges>;
