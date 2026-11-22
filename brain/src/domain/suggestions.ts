import { Table } from '../core/db.js';
import type { Id, Link, Suggestion, Task } from '../core/types.js';
import { conflict, invalid, isPlainObject, newId } from '../core/util.js';
import type { Deps } from './crud.js';
import type { Tasks } from './tasks.js';

export type SuggestionInput = Pick<Suggestion, 'kind' | 'title'> & Partial<Suggestion>;

export function createSuggestions({ db, bus }: Deps, tasks: Tasks) {
  const table = new Table<Suggestion>(db, 'suggestions', {
    id: 's', kind: 's', title: 's', rationale: 's', payload: 'o', source: 's', sourceRef: 's', sourceUrl: 's',
    confidence: 'n', status: 's', createdAt: 'n', decidedAt: 'n',
  }, () => bus.changed('suggestions'));

  const pending = (id: Id): Suggestion => {
    const s = table.must(id);
    if (s.status !== 'pending') throw conflict(`suggestion is already ${s.status}`);
    return s;
  };
  const targetTask = (s: Suggestion): Id => {
    if (typeof s.payload.taskId !== 'string') throw invalid(`a ${s.kind} suggestion needs payload.taskId`);
    return s.payload.taskId;
  };

  const suggestions = {
    get: (id: Id) => table.get(id),
    list: (status?: string) => (status ? table.where('WHERE status = ? ORDER BY createdAt DESC', status) : table.where('ORDER BY createdAt DESC LIMIT 500')),
    count: (status: Suggestion['status']) => table.count('WHERE status = ?', status),

    create(input: SuggestionInput): Suggestion {
      return table.insert({
        id: newId(), kind: 'insight', title: '', rationale: '', payload: {}, source: 'agent', sourceRef: null, sourceUrl: null, confidence: 0.5,
        ...table.pick(input, ['id', 'status', 'createdAt', 'decidedAt']),
        status: 'pending', createdAt: Date.now(), decidedAt: null,
      });
    },

    /** Applies the suggestion. `edits` are the user's changes on top of the proposed payload. */
    accept(id: Id, edits: unknown = {}): { suggestion: Suggestion; task?: Task } {
      const s = pending(id);
      const changes = isPlainObject(edits) ? edits : {};
      let task: Task | undefined;
      let payload = s.payload;

      if (s.kind === 'new_task' || s.kind === 'followup') {
        const input: Partial<Task> = { title: s.title, status: 'todo', ...s.payload, ...changes, source: s.source, sourceRef: s.sourceRef };
        if (s.kind === 'followup' && input.waitingOn && !('status' in s.payload) && !('status' in changes)) input.status = 'waiting';
        if (s.sourceUrl && !input.links?.length) input.links = [{ kind: 'url', title: s.title, url: s.sourceUrl }];
        task = tasks.create(input);
      } else if (s.kind === 'update_task') {
        task = tasks.update(targetTask(s), { ...(isPlainObject(s.payload.patch) ? s.payload.patch : {}), ...changes });
      } else if (s.kind === 'complete_task') {
        task = tasks.complete(targetTask(s));
      } else if (s.kind === 'link') {
        task = tasks.addLink(targetTask(s), { ...(s.payload.link as Link), ...changes });
      } else {
        // insight / question: nothing to apply; keep the user's answer with the suggestion.
        payload = { ...s.payload, ...changes };
      }
      return { suggestion: table.update(id, { status: 'accepted', decidedAt: Date.now(), payload }), task };
    },

    dismiss(id: Id): Suggestion {
      pending(id);
      return table.update(id, { status: 'dismissed', decidedAt: Date.now() });
    },

    /** Accepts each id independently; one bad suggestion does not block the rest. */
    acceptAll(ids: Id[]): { accepted: { suggestion: Suggestion; task?: Task }[]; failed: { id: Id; message: string }[] } {
      const accepted: { suggestion: Suggestion; task?: Task }[] = [];
      const failed: { id: Id; message: string }[] = [];
      for (const id of ids) {
        try {
          accepted.push(suggestions.accept(id));
        } catch (err) {
          failed.push({ id, message: (err as Error).message });
        }
      }
      return { accepted, failed };
    },
  };
  return suggestions;
}
