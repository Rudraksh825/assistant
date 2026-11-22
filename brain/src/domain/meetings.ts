import { Table } from '../core/db.js';
import type { Meeting, Ms } from '../core/types.js';
import { invalid, newId } from '../core/util.js';
import { crud, type Deps } from './crud.js';

export function createMeetings({ db, bus }: Deps) {
  const table = new Table<Meeting>(db, 'meetings', {
    id: 's', source: 's', externalId: 's', title: 's', startAt: 'n', endAt: 'n', attendees: 'a', joinUrl: 's', location: 's',
    summary: 's', actionItems: 'a', recordingUrl: 's', prepNote: 's', prepStatus: 's', prepError: 's', startKnown: 'b', cancelledAt: 'n', updatedAt: 'n',
  }, () => bus.changed('meetings'));
  const base = crud<Meeting>(table, (now) => ({
    id: newId(), source: 'calendar', externalId: '', title: '', startAt: now, endAt: now, attendees: [], joinUrl: null,
    location: null, summary: null, actionItems: [], recordingUrl: null, prepNote: null, prepStatus: null, prepError: null, startKnown: true, cancelledAt: null, updatedAt: now,
  }), ['externalId', 'title']);

  // A prep still 'running' on disk belongs to a process that died mid-run.
  db.prepare("UPDATE meetings SET prepStatus = NULL WHERE prepStatus = 'running'").run();

  return {
    ...base,

    /** Meetings overlapping [from, to]. Cancelled events are left out. */
    list(from: Ms = 0, to: Ms = Number.MAX_SAFE_INTEGER): Meeting[] {
      return table.where('WHERE endAt >= ? AND startAt <= ? AND cancelledAt IS NULL ORDER BY startAt', from, to);
    },

    /**
     * After a calendar sync that listed everything in [from, to]: events starting in that window that it did not
     * list (deleted, moved out, or declined) are marked cancelled, so they stop being next, current or prepped.
     * An event the sync lists again comes back. Returns how many were cancelled.
     */
    reconcile(from: Ms, to: Ms, listed: string[], now: Ms = Date.now()): number {
      const gone = table.where("WHERE source = 'calendar' AND startAt >= ? AND startAt <= ? AND cancelledAt IS NULL", from, to).filter((m) => !listed.includes(m.externalId));
      for (const m of gone) base.update(m.id, { cancelledAt: now });
      return gone.length;
    },

    /** Insert or patch by (source, externalId). */
    upsert(input: Partial<Meeting> & Pick<Meeting, 'source' | 'externalId'>): Meeting {
      if (typeof input.source !== 'string' || typeof input.externalId !== 'string') throw invalid('source and externalId are required');
      // A recording has already happened: a source that only knows its date must not make it look live or upcoming.
      if (input.source === 'meeting' && typeof input.endAt === 'number' && input.endAt > Date.now()) input = { ...input, endAt: Math.max(Date.now(), input.startAt ?? 0) };
      const existing = table.where('WHERE source = ? AND externalId = ?', input.source, input.externalId)[0];
      // Being reported again is what un-cancels an event.
      return existing ? base.update(existing.id, { cancelledAt: null, ...input }) : base.create(input);
    },

    /** The recording a meeting signal belongs to: by its link, or by the recording id its externalId starts with. */
    forSignal(url: string | null, externalId: string): Meeting | null {
      return table.where("WHERE source = 'meeting' AND ((recordingUrl IS NOT NULL AND recordingUrl = ?) OR externalId = ? OR externalId = ?) ORDER BY startAt DESC LIMIT 1", url ?? '', externalId, externalId.split(':')[0]!)[0] ?? null;
    },

    // Calendar events only: a recording is a meeting that already happened, whatever times its source gave it.
    next: (now: Ms = Date.now()): Meeting | null => table.where("WHERE source = 'calendar' AND cancelledAt IS NULL AND startAt > ? ORDER BY startAt LIMIT 1", now)[0] ?? null,
    current: (now: Ms = Date.now()): Meeting | null => table.where("WHERE source = 'calendar' AND cancelledAt IS NULL AND startAt <= ? AND endAt > ? ORDER BY startAt DESC LIMIT 1", now, now)[0] ?? null,
  };
}
