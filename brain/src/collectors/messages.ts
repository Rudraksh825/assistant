import { statSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import type { AppContext } from '../core/context.js';
import type { Ms } from '../core/types.js';
import { DAY, MIN } from '../core/util.js';
import { notify } from '../jobs/notify.js';
import { clip, connector, setHealth } from './settings.js';

const CHAT_DB = join(homedir(), 'Library', 'Messages', 'chat.db');
// Message dates are nanoseconds since 2001-01-01 UTC.
const APPLE_EPOCH_MS = 978_307_200_000;

/**
 * Newer macOS leaves `message.text` NULL and keeps the body in `attributedBody`, a typedstream archive.
 * The string sits after the NSString class header as a length-prefixed UTF-8 run.
 * shortcut: byte-scrapes instead of unarchiving, so unusual archives yield null; move this to the Swift side (NSUnarchiver) if messages go missing.
 */
export function decodeAttributedBody(blob: Uint8Array | null): string | null {
  if (!blob) return null;
  const buf = Buffer.from(blob);
  const marker = buf.indexOf('NSString');
  const plus = marker < 0 ? -1 : buf.indexOf(0x2b, marker);
  if (plus < 0 || plus + 4 > buf.length) return null;
  const wide = buf[plus + 1] === 0x81;
  const length = wide ? buf.readUInt16LE(plus + 2) : buf[plus + 1]!;
  const start = plus + (wide ? 4 : 2);
  return buf.toString('utf8', start, start + length) || null;
}

interface Row { id: number; guid: string; text: string | null; body: Uint8Array | null; at: Ms; sender: string | null; chat: string | null }

export function createMessagesCollector(ctx: AppContext, dbPath = CHAT_DB) {
  const { repos } = ctx;
  let lastSig = '';
  let timer: NodeJS.Timeout | null = null;

  function poll(now: Ms = Date.now()): void {
    if (!connector(ctx, 'messages').enabled) return setHealth(ctx, 'messages', 'off');
    // New messages land in the write-ahead log first.
    const sig = [dbPath, `${dbPath}-wal`].map((p) => statSync(p, { throwIfNoEntry: false })?.mtimeMs ?? 0).join(':');
    if (sig === lastSig) return;
    try {
      // Not immutable, unlike the browser read: the WAL has to be visible.
      const db = new DatabaseSync(dbPath, { readOnly: true });
      try {
        const cursor = repos.kv.get<number>('messages:cursor') ?? 0;
        const rows = db.prepare(`SELECT m.ROWID AS id, m.guid AS guid, m.text AS text, m.attributedBody AS body,
            m.date / 1000000 + ${APPLE_EPOCH_MS} AS at, h.id AS sender, COALESCE(c.display_name, c.chat_identifier) AS chat
          FROM message m LEFT JOIN handle h ON h.ROWID = m.handle_id
            LEFT JOIN chat_message_join j ON j.message_id = m.ROWID LEFT JOIN chat c ON c.ROWID = j.chat_id
          WHERE m.ROWID > ? AND m.is_from_me = 0 AND m.associated_message_type = 0 AND m.date > (? - ${APPLE_EPOCH_MS}) * 1000000
          ORDER BY m.ROWID LIMIT 200`).all(cursor, now - DAY) as unknown as Row[];
        repos.signals.ingest(rows.flatMap((r) => {
          const text = r.text ?? decodeAttributedBody(r.body);
          return text ? [{ source: 'message' as const, kind: 'imessage', externalId: r.guid, title: r.chat || r.sender || 'Message', body: clip(text, 500), actor: r.sender, occurredAt: r.at }] : [];
        }));
        if (rows.length) repos.kv.set('messages:cursor', rows.at(-1)!.id);
      } finally {
        db.close();
      }
      lastSig = sig;
      repos.health.synced('messages', now);
    } catch (err) {
      // Without Full Disk Access the file cannot even be opened; that is a setting to fix, not an error to retry loudly.
      repos.health.set('messages', 'off');
      notify(ctx, {
        kind: 'system', title: 'Messages needs Full Disk Access', priority: 1, dedupeKey: 'messages:permission',
        body: 'Grant Steward Full Disk Access to read iMessage, or turn the Messages connector off.',
        actions: [{ id: 'open', label: 'Open settings', kind: 'open_url', url: 'x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles' }],
      });
      ctx.log.child('messages').debug('chat.db not readable', err);
    }
  }

  return {
    poll,
    start() {
      poll();
      timer = setInterval(poll, Math.max(1, connector<{ everyMin: number }>(ctx, 'messages').everyMin ?? 2) * MIN);
      timer.unref();
    },
    stop() {
      if (timer) clearInterval(timer);
    },
  };
}
