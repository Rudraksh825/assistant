import { Table } from '../core/db.js';
import type { ChatMessage, ChatThread, Id } from '../core/types.js';
import { newId } from '../core/util.js';
import type { Deps } from './crud.js';

const UNTITLED = 'New chat';

export function createChat({ db }: Deps) {
  const threads = new Table<ChatThread>(db, 'chat_threads', { id: 's', title: 's', createdAt: 'n', updatedAt: 'n', agentSessionId: 's' });
  const messages = new Table<ChatMessage>(db, 'chat_messages', { id: 's', threadId: 's', role: 's', text: 's', tool: 'o', costUsd: 'n', createdAt: 'n' });

  return {
    threads: () => threads.where('ORDER BY updatedAt DESC'),
    thread: (id: Id) => threads.must(id),
    hasThread: (id: Id) => threads.get(id) !== null,

    createThread(input: { title?: string } = {}): ChatThread {
      const now = Date.now();
      return threads.insert({ id: newId(), title: typeof input.title === 'string' && input.title.trim() ? input.title : UNTITLED, createdAt: now, updatedAt: now, agentSessionId: null });
    },

    updateThread(id: Id, patch: Partial<Pick<ChatThread, 'title' | 'agentSessionId'>>): ChatThread {
      return threads.update(id, { ...threads.pick(patch, ['id', 'createdAt']), updatedAt: Date.now() });
    },

    /** Its messages go with it (ON DELETE CASCADE). */
    removeThread: (id: Id): void => threads.delete(id),

    messages(threadId: Id): ChatMessage[] {
      threads.must(threadId);
      return messages.where('WHERE threadId = ? ORDER BY createdAt, id', threadId);
    },

    addMessage(input: Pick<ChatMessage, 'threadId' | 'role' | 'text'> & Partial<Pick<ChatMessage, 'tool' | 'costUsd'>>): ChatMessage {
      const thread = threads.must(input.threadId);
      const now = Date.now();
      const message = messages.insert({ id: newId(), tool: null, costUsd: null, ...messages.pick(input, ['id', 'createdAt']), createdAt: now } as ChatMessage);
      const title = thread.title === UNTITLED && input.role === 'user' ? input.text.trim().split('\n')[0]!.slice(0, 60) || UNTITLED : thread.title;
      threads.update(thread.id, { title, updatedAt: now });
      return message;
    },

    /** For tool messages whose status or result arrives later. */
    updateMessage(id: Id, patch: Partial<Pick<ChatMessage, 'text' | 'tool'>>): ChatMessage {
      return messages.update(id, messages.pick(patch, ['id', 'threadId', 'role', 'createdAt']));
    },
  };
}

export type Chat = ReturnType<typeof createChat>;
