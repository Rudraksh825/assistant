import { Table } from '../core/db.js';
import type { Approval, Id } from '../core/types.js';
import { conflict, invalid, isPlainObject, newId } from '../core/util.js';
import type { Chat } from './chat.js';
import type { Deps } from './crud.js';
import type { Nudges } from './nudges.js';

export type ApprovalInput = Pick<Approval, 'kind' | 'summary' | 'tool' | 'input'> & Partial<Approval>;
export type ApprovalExecutor = (approval: Approval) => Promise<{ ok: boolean; result: string }>;
/** Why a payload can never run, or null. `edited` marks an input the user changed on the card. */
export type ApprovalCheck = (approval: Approval, edited: boolean) => string | null;

const nudgeKey = (id: Id) => `approval:${id}`;

/**
 * State machine only: pending → approved → executed | failed, pending → denied, pending → expired.
 * Running the approved action is the executor's job (the agent runtime).
 */
export function createApprovals({ db, bus }: Deps, nudges: Nudges, chat: Chat) {
  const table = new Table<Approval>(db, 'approvals', {
    id: 's', kind: 's', summary: 's', tool: 's', input: 'o', note: 's', target: 's', status: 's', result: 's',
    threadId: 's', createdAt: 'n', decidedAt: 'n',
  }, () => bus.changed('approvals'));

  const decide = (id: Id, patch: Partial<Approval>): Approval => {
    const approval = table.must(id);
    if (approval.status !== 'pending') throw conflict(`approval is already ${approval.status}`);
    nudges.dismissByKey(nudgeKey(id));
    return table.update(id, { ...patch, decidedAt: Date.now() });
  };

  return {
    get: (id: Id) => table.get(id),
    must: (id: Id) => table.must(id),
    list: (status?: string) => (status ? table.where('WHERE status = ? ORDER BY createdAt DESC', status) : table.where('ORDER BY createdAt DESC LIMIT 200')),
    count: (status: Approval['status']) => table.count('WHERE status = ?', status),

    /** Queues the action and tells the user: `approval.requested` plus a priority-2 nudge. */
    create(input: ApprovalInput): Approval {
      const approval = table.insert({
        id: newId(), kind: '', summary: '', tool: '', input: {}, note: '', target: null, threadId: null,
        ...table.pick(input, ['id', 'status', 'result', 'createdAt', 'decidedAt']),
        status: 'pending', result: null, createdAt: Date.now(), decidedAt: null,
      });
      bus.emit('approval.requested', approval);
      nudges.create({
        kind: 'approval', title: 'Approval needed', body: approval.summary, priority: 2, dedupeKey: nudgeKey(approval.id),
        actions: [{ id: 'review', label: 'Review', kind: 'open_view', view: 'approvals' }],
      });
      return approval;
    },

    /**
     * `edits`, when given, is the whole input as the user rewrote it and replaces the queued one: what they saw in the
     * editor is what runs, removed fields included. `check` holds it to the rules the agent's version was held to; a
     * refused edit leaves the approval pending. The outcome is stored and, when the approval came from a chat thread,
     * posted there as a system message.
     */
    async approve(id: Id, edits: unknown, execute: ApprovalExecutor, check?: ApprovalCheck): Promise<Approval> {
      const pending = table.must(id);
      if (pending.status !== 'pending') throw conflict(`approval is already ${pending.status}`);
      const edited = isPlainObject(edits);
      const input = edited ? edits : pending.input;
      const problem = check?.({ ...pending, input }, edited);
      if (problem) throw invalid(problem);
      const approved = decide(id, { status: 'approved', input });
      let outcome: { ok: boolean; result: string };
      try {
        outcome = await execute(approved);
      } catch (err) {
        outcome = { ok: false, result: (err as Error).message ?? String(err) };
      }
      const done = table.update(id, { status: outcome.ok ? 'executed' : 'failed', result: outcome.result });
      if (done.threadId && chat.hasThread(done.threadId)) {
        chat.addMessage({ threadId: done.threadId, role: 'system', text: `${outcome.ok ? 'Done' : 'Failed'}: ${done.summary}\n${outcome.result}` });
      }
      return done;
    },

    deny: (id: Id, reason?: string): Approval => decide(id, { status: 'denied', result: typeof reason === 'string' ? reason : null }),
    expire: (id: Id): Approval => decide(id, { status: 'expired' }),
  };
}
