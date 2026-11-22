import type { Bus } from '../core/bus.js';
import type { Db, Table } from '../core/db.js';
import type { Id, Ms } from '../core/types.js';
import { invalid } from '../core/util.js';

export interface Deps { db: Db; bus: Bus }

/** get / must / create / update / remove over a table, with validated input and timestamps. */
export function crud<T extends { id: Id }>(table: Table<T>, defaults: (now: Ms) => T, required: (keyof T & string)[] = []) {
  const stamped = 'updatedAt' in defaults(0);
  return {
    get: (id: Id): T | null => table.get(id),
    must: (id: Id): T => table.must(id),
    create(input: Partial<T>): T {
      const row = { ...defaults(Date.now()), ...table.pick(input, ['id', 'createdAt', 'updatedAt']) };
      for (const k of required) if (!row[k]) throw invalid(`${k} is required`);
      return table.insert(row);
    },
    update(id: Id, input: Partial<T>): T {
      const current = table.must(id);
      const patch = table.changes(current, table.pick(input, ['id', 'createdAt', 'updatedAt']));
      // Collectors re-send whole records on every poll; an identical one must not look like an edit.
      if (!Object.keys(patch).length) return current;
      return table.update(id, stamped ? { ...patch, updatedAt: Date.now() } : patch);
    },
    remove: (id: Id): void => table.delete(id),
  };
}
