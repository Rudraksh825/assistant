import { Table, tx, type Param } from '../core/db.js';
import type { Id, Link, Ms, Task } from '../core/types.js';
import { DAY, invalid, newId, startOfDay } from '../core/util.js';
import type { Deps } from './crud.js';
import { scoreTask, type RankInput } from './ranking.js';

const COMPUTED = ['id', 'score', 'scoreReasons', 'createdAt', 'updatedAt', 'completedAt', 'startedAt'];
const OPEN = "status NOT IN ('done', 'dropped')";
const RANKED = 'ORDER BY manualRank IS NULL, manualRank, score DESC, createdAt';

export interface TaskFilter { status?: string[]; projectId?: Id; parentId?: Id; q?: string; limit?: number }

export function createTasks({ db, bus }: Deps, inputsAt: (now: Ms) => (t: Task) => RankInput) {
  const table = new Table<Task>(db, 'tasks', {
    id: 's', title: 's', notes: 's', status: 's', priority: 'n', projectId: 's', parentId: 's', dueAt: 'n',
    scheduledFor: 'n', snoozedUntil: 'n', estimateMin: 'n', pinned: 'b', manualRank: 'n', score: 'n',
    scoreReasons: 'a', waitingOn: 's', people: 'a', tags: 'a', links: 'a', source: 's', sourceRef: 's',
    createdAt: 'n', updatedAt: 'n', completedAt: 'n', startedAt: 'n',
  }, () => bus.changed('tasks'));

  const scored = (t: Task, now: Ms): Task => {
    const { score, reasons } = scoreTask(t, inputsAt(now)(t), now);
    return { ...t, score, scoreReasons: reasons };
  };

  const countByProject = (where: string): Map<Id, number> => {
    const rows = db.prepare(`SELECT projectId, COUNT(*) AS n FROM tasks WHERE ${where} AND projectId IS NOT NULL GROUP BY projectId`).all() as { projectId: Id; n: number }[];
    return new Map(rows.map((r) => [r.projectId, r.n]));
  };

  const tasks = {
    get: (id: Id) => table.get(id),
    must: (id: Id) => table.must(id),

    /** Sorted by manualRank (ranked first), then score. */
    list(f: TaskFilter = {}): Task[] {
      const where: string[] = [];
      const params: Param[] = [];
      if (f.status?.length) {
        where.push(`status IN (${f.status.map(() => '?').join(', ')})`);
        params.push(...f.status);
      }
      for (const key of ['projectId', 'parentId'] as const) {
        if (f[key]) {
          where.push(`${key} = ?`);
          params.push(f[key]);
        }
      }
      if (f.q) {
        where.push('(title LIKE ? OR notes LIKE ?)');
        params.push(`%${f.q}%`, `%${f.q}%`);
      }
      return table.where(`${where.length ? `WHERE ${where.join(' AND ')}` : ''} ${RANKED} LIMIT ?`, ...params, f.limit ?? 500);
    },

    /** Manual tasks start in `todo`; anything a collector or the agent adds lands in `inbox` unless it says otherwise. */
    create(input: Partial<Task>): Task {
      const now = Date.now();
      const given = table.pick(input, COMPUTED);
      if (!given.title?.trim()) throw invalid('title is required');
      const task: Task = {
        id: newId(), title: '', notes: '', status: (given.source ?? 'manual') === 'manual' ? 'todo' : 'inbox', priority: 0,
        projectId: null, parentId: null, dueAt: null, scheduledFor: null, snoozedUntil: null, estimateMin: null,
        pinned: false, manualRank: null, score: 0, scoreReasons: [], waitingOn: null, people: [], tags: [], links: [],
        source: 'manual', sourceRef: null, ...given, createdAt: now, updatedAt: now, completedAt: null, startedAt: null,
      };
      if (task.status === 'done') task.completedAt = now;
      if (task.status === 'doing') task.startedAt = now;
      return table.insert(scored(task, now));
    },

    update(id: Id, input: Partial<Task>): Task {
      const now = Date.now();
      const current = table.must(id);
      const patch = table.changes(current, table.pick(input, COMPUTED));
      if (!Object.keys(patch).length) return current;
      const next: Task = { ...current, ...patch, updatedAt: now };
      next.completedAt = next.status === 'done' ? current.completedAt ?? now : null;
      next.startedAt = next.status === 'doing' ? current.startedAt ?? now : null;
      return table.update(id, scored(next, now));
    },

    remove: (id: Id) => table.delete(id),
    complete: (id: Id) => tasks.update(id, { status: 'done' }),
    snooze: (id: Id, until: Ms) => tasks.update(id, { snoozedUntil: until }),

    /** `exclusive` moves every other `doing` task back to `todo`. */
    start(id: Id, exclusive = false): Task {
      table.must(id);
      if (exclusive) {
        for (const other of table.where("WHERE status = 'doing' AND id != ?", id)) tasks.update(other.id, { status: 'todo' });
      }
      return tasks.update(id, { status: 'doing', snoozedUntil: null });
    },

    /** The given ids take manual ranks 0..n-1 in order. Tasks not listed keep theirs. */
    reorder(ids: Id[]): void {
      tx(db, () => ids.forEach((id, i) => table.update(id, { manualRank: i })));
    },

    addLink(id: Id, link: Link): Task {
      if (typeof link?.url !== 'string' || typeof link.kind !== 'string') throw invalid('link needs kind and url');
      const task = table.must(id);
      if (task.links.some((l) => l.url === link.url)) return task;
      return tasks.update(id, { links: [...task.links, { ...link, title: link.title ?? link.url }] });
    },

    /** Recompute every open task's score; writes (and announces) only the ones that moved. Does not touch updatedAt. */
    rerank(now: Ms = Date.now()): number {
      const inputs = inputsAt(now);
      let changed = 0;
      for (const t of table.where(`WHERE ${OPEN}`)) {
        const { score, reasons } = scoreTask(t, inputs(t), now);
        if (score === t.score && reasons.join('\n') === t.scoreReasons.join('\n')) continue;
        table.update(t.id, { score, scoreReasons: reasons });
        changed++;
      }
      return changed;
    },

    /** The `doing` task the user is on: pinned first, then most recently touched. */
    current(): Task | null {
      return table.where("WHERE status = 'doing' ORDER BY pinned DESC, updatedAt DESC LIMIT 1")[0] ?? null;
    },

    top(limit = 12, now: Ms = Date.now()): Task[] {
      return table.where(`WHERE ${OPEN} AND (snoozedUntil IS NULL OR snoozedUntil <= ?) ${RANKED} LIMIT ?`, now, limit);
    },

    counts(now: Ms = Date.now()): { inbox: number; waiting: number; dueToday: number; overdue: number } {
      const today = startOfDay(now);
      return {
        inbox: table.count("WHERE status = 'inbox'"),
        waiting: table.count("WHERE status = 'waiting'"),
        dueToday: table.count(`WHERE ${OPEN} AND dueAt >= ? AND dueAt < ?`, today, today + DAY),
        overdue: table.count(`WHERE ${OPEN} AND dueAt < ?`, today),
      };
    },

    openByProject: () => countByProject(OPEN),
    doneByProject: () => countByProject("status = 'done'"),
  };
  return tasks;
}

export type Tasks = ReturnType<typeof createTasks>;
