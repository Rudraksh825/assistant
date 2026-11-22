import type { ServerResponse } from 'node:http';
import type { Bus, LocalEvents } from './bus.js';
import type { Handler } from './http.js';
import { VERSION } from './paths.js';

// Typed against LocalEvents so a new in-process event cannot reach clients by omission.
const LOCAL: Record<keyof LocalEvents, true> = { 'sensor.event': true };
const PING_MS = 15_000;

/** Bridges every non-local bus event to all connected `/events` clients. */
export function createSse(bus: Bus): { handler: Handler; close(): void } {
  const clients = new Set<ServerResponse>();
  const send = (res: ServerResponse, type: string, data: unknown) => res.write(`event: ${type}\ndata: ${JSON.stringify(data)}\n\n`);

  const off = bus.onAny((type, data) => {
    if (!(type in LOCAL)) for (const res of clients) send(res, type, data);
  });
  const ping = setInterval(() => { for (const res of clients) send(res, 'ping', {}); }, PING_MS);
  ping.unref();

  return {
    handler(_req, res) {
      if (!res) throw new Error('/events needs a live connection');
      res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', connection: 'keep-alive' });
      send(res, 'hello', { version: VERSION });
      clients.add(res);
      res.on('close', () => clients.delete(res));
    },
    close() {
      off();
      clearInterval(ping);
      for (const res of clients) res.end();
      clients.clear();
    },
  };
}
