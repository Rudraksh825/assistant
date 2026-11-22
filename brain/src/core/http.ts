import { timingSafeEqual } from 'node:crypto';
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';
import type { AddressInfo } from 'node:net';
import type { Log } from './log.js';
import { HttpError, invalid, isPlainObject } from './util.js';

export interface Req {
  method: string;
  path: string;
  params: Record<string, string>;
  query: URLSearchParams;
  /** Parsed JSON body; `{}` when the request had none. Always a plain object. */
  body: Record<string, any>;
}

/** Return a value to send it as JSON. A handler that writes to `res` itself (SSE) owns the response. */
export type Handler = (req: Req, res?: ServerResponse) => unknown;

const MAX_BODY = 5 * 1024 * 1024;

export class Router {
  private routes: { method: string; re: RegExp; handler: Handler }[] = [];

  /** Patterns: `/tasks/:id` binds one segment, `/memory/*path` binds the rest of the path. */
  on(method: string, pattern: string, handler: Handler): this {
    const source = pattern.replace(/[:*](\w+)/g, (m, name) => (m[0] === ':' ? `(?<${name}>[^/]+)` : `(?<${name}>.+)`));
    this.routes.push({ method, re: new RegExp(`^${source}$`), handler });
    return this;
  }
  get(pattern: string, handler: Handler) { return this.on('GET', pattern, handler); }
  post(pattern: string, handler: Handler) { return this.on('POST', pattern, handler); }
  patch(pattern: string, handler: Handler) { return this.on('PATCH', pattern, handler); }
  put(pattern: string, handler: Handler) { return this.on('PUT', pattern, handler); }
  delete(pattern: string, handler: Handler) { return this.on('DELETE', pattern, handler); }

  /** Also the in-process entry point: nudge `api` actions run through here. */
  async dispatch(method: string, path: string, opts: { query?: URLSearchParams; body?: unknown; res?: ServerResponse } = {}): Promise<unknown> {
    for (const route of this.routes) {
      const m = route.method === method ? route.re.exec(path) : null;
      if (!m) continue;
      const params: Record<string, string> = {};
      try {
        for (const [k, v] of Object.entries(m.groups ?? {})) params[k] = decodeURIComponent(v);
      } catch {
        throw invalid('malformed path');
      }
      const body = opts.body ?? {};
      if (!isPlainObject(body)) throw invalid('body must be a JSON object');
      return route.handler({ method, path, params, query: opts.query ?? new URLSearchParams(), body }, opts.res);
    }
    throw new HttpError(404, 'not_found', `no route for ${method} ${path}`);
  }
}

export function createHttpServer(router: Router, token: string, log: Log): Server {
  const expected = Buffer.from(token);
  const authorized = (req: IncomingMessage, url: URL): boolean => {
    const header = req.headers.authorization;
    const given = header?.startsWith('Bearer ') ? header.slice(7) : url.pathname === '/events' ? url.searchParams.get('token') : null;
    const buf = Buffer.from(given ?? '');
    return buf.length === expected.length && timingSafeEqual(buf, expected);
  };

  return createServer(async (req, res) => {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1');
    const method = req.method ?? 'GET';
    try {
      if (!(method === 'GET' && url.pathname === '/health') && !authorized(req, url)) {
        throw new HttpError(401, 'unauthorized', 'missing or invalid bearer token');
      }
      const out = await router.dispatch(method, url.pathname, { query: url.searchParams, body: await readJson(req), res });
      if (!res.headersSent) sendJson(res, 200, out ?? { ok: true });
    } catch (err) {
      const e = toHttpError(err);
      if (e.status >= 500) log.error(`${method} ${url.pathname}`, err);
      if (!res.headersSent) sendJson(res, e.status, { error: { code: e.code, message: e.message } });
      else res.end();
    }
  });
}

/** Binds 127.0.0.1 only. If `port` is taken, walks up to the next free one. */
export async function listen(server: Server, port: number): Promise<number> {
  for (let p = port; p < port + 50; p++) {
    try {
      await new Promise<void>((resolve, reject) => {
        server.once('error', reject);
        server.listen(p, '127.0.0.1', () => {
          server.off('error', reject);
          resolve();
        });
      });
      return (server.address() as AddressInfo).port;
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== 'EADDRINUSE') throw err;
    }
  }
  throw new Error(`no free port in ${port}..${port + 49}`);
}

function toHttpError(err: unknown): HttpError {
  if (err instanceof HttpError) return err;
  const message = err instanceof Error ? err.message : String(err);
  // Schema CHECK / NOT NULL / FOREIGN KEY violations are the caller's bad input, not a server fault.
  if ((err as { code?: string }).code === 'ERR_SQLITE_ERROR' && /constraint failed/.test(message)) {
    return /^UNIQUE/.test(message) ? new HttpError(409, 'conflict', message) : invalid(message);
  }
  return new HttpError(500, 'internal', message);
}

async function readJson(req: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_BODY) throw new HttpError(413, 'too_large', 'request body too large');
    chunks.push(chunk);
  }
  if (!size) return undefined;
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    throw invalid('body is not valid JSON');
  }
}

function sendJson(res: ServerResponse, status: number, body: unknown): void {
  const data = JSON.stringify(body);
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'content-length': Buffer.byteLength(data) });
  res.end(data);
}
