import type { Approval, CodeSession, Id, Ms, Nudge } from './types.js';

export type Entity =
  | 'tasks' | 'projects' | 'initiatives' | 'suggestions' | 'sessions' | 'meetings' | 'notes'
  | 'approvals' | 'nudges' | 'budget' | 'settings' | 'people' | 'jobs' | 'places';

/** Sent to every `/events` client as `event: <type>` + `data: <json>`. */
export interface SseEvents {
  'hello': { version: string };
  'state.changed': { entities: Entity[] };
  'session.updated': CodeSession;
  'nudge': Nudge;
  'nudge.dismissed': { id: Id };
  'chat.started': { threadId: Id; runId: Id };
  'chat.delta': { threadId: Id; runId: Id; text: string };
  'chat.tool': { threadId: Id; runId: Id; callId: string; name: string; input: unknown; status: 'running' | 'ok' | 'error' | 'denied'; result?: string };
  'chat.question': { threadId: Id; questionId: string; question: string; options?: string[] };
  'chat.done': { threadId: Id; runId: Id; messageId: Id; costUsd: number };
  'chat.error': { threadId: Id; runId: Id; message: string };
  'agent.activity': { busy: boolean; activity: string | null };
  'approval.requested': Approval;
  'ui.command': { command: 'open_view' | 'show_note' | 'focus_session' | 'speak' | 'open_url' | 'toast'; args: Record<string, unknown> };
  'app.relaunch': { reason: string };
  'ping': Record<string, never>;
}

/** In-process only; never sent to clients. */
export interface LocalEvents {
  'sensor.event': { kind: string; at: Ms; data?: Record<string, unknown> };
}

export type BusEvents = SseEvents & LocalEvents;
type Listener<K extends keyof BusEvents> = (data: BusEvents[K]) => void;
type AnyListener = <K extends keyof BusEvents>(type: K, data: BusEvents[K]) => void;

export class Bus {
  private listeners = new Map<string, Set<(data: never) => void>>();
  private any = new Set<AnyListener>();
  private pending = new Set<Entity>();

  constructor(private onError: (err: unknown) => void = console.error) {}

  on<K extends keyof BusEvents>(type: K, fn: Listener<K>): () => void {
    let set = this.listeners.get(type);
    if (!set) this.listeners.set(type, (set = new Set()));
    set.add(fn);
    return () => set.delete(fn);
  }

  onAny(fn: AnyListener): () => void {
    this.any.add(fn);
    return () => this.any.delete(fn);
  }

  emit<K extends keyof BusEvents>(type: K, data: BusEvents[K]): void {
    for (const fn of [...(this.listeners.get(type) ?? [])]) this.guard(() => (fn as Listener<K>)(data));
    for (const fn of [...this.any]) this.guard(() => fn(type, data));
  }

  /** Queue a `state.changed`. All mutations in one synchronous burst collapse into a single event. */
  changed(...entities: Entity[]): void {
    if (this.pending.size === 0) {
      queueMicrotask(() => {
        const batch = [...this.pending];
        this.pending.clear();
        this.emit('state.changed', { entities: batch });
      });
    }
    for (const e of entities) this.pending.add(e);
  }

  private guard(fn: () => void): void {
    try { fn(); } catch (err) { this.onError(err); }
  }
}
