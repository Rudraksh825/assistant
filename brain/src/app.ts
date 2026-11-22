import { rmSync, writeFileSync } from 'node:fs';
import { createAgentRuntime } from './agent/index.js';
import { registerRoutes } from './api.js';
import { startCollectors } from './collectors/index.js';
import { Bus } from './core/bus.js';
import { ConfigStore } from './core/config.js';
import type { AppContext } from './core/context.js';
import { createCost } from './core/cost.js';
import { openDb } from './core/db.js';
import { createHttpServer, listen, Router } from './core/http.js';
import { createLog } from './core/log.js';
import { resolvePaths, VERSION, writeToken } from './core/paths.js';
import { Scheduler } from './core/scheduler.js';
import { createSse } from './core/sse.js';
import { createRepos } from './domain/index.js';
import { registerJobs } from './jobs/index.js';

export interface Brain { ctx: AppContext; port: number; token: string; stop(): Promise<void> }

/** Wires the daemon. `port` overrides config.port (tests pass 0 for a random one). */
export async function startBrain(opts: { port?: number } = {}): Promise<Brain> {
  const startedAt = Date.now();
  const paths = resolvePaths();
  const log = createLog(paths.logsDir);
  const bus = new Bus((err) => log.error('bus listener failed', err));
  const config = new ConfigStore(paths, bus, log);
  const db = openDb(paths.dbFile);
  const repos = createRepos({ db, bus }, paths);
  const cost = createCost(db, bus, config, (n) => repos.nudges.create(n));
  const scheduler = new Scheduler({ db, bus, log, config, cost });

  const ctx = { config, paths, db, bus, log, cost, scheduler, repos } as AppContext;
  ctx.agent = createAgentRuntime(ctx);

  const router = new Router();
  const sse = createSse(bus);
  router.get('/events', sse.handler);
  registerRoutes(router, ctx, startedAt);
  const token = writeToken(paths);
  const server = createHttpServer(router, token, log.child('http'));
  const port = await listen(server, opts.port ?? config.get().port);
  writeFileSync(paths.portFile, String(port));

  const collectors = await startCollectors(ctx);
  scheduler.register({
    name: 'core.rerank',
    schedule: { everyMin: 5 },
    run() {
      repos.tasks.rerank();
      repos.nudges.expire();
    },
  });
  registerJobs(ctx);
  scheduler.start();
  log.info(`steward brain ${VERSION} listening on 127.0.0.1:${port}`, { home: paths.home });

  return {
    ctx, port, token,
    async stop() {
      await scheduler.stop();
      await collectors.stop();
      sse.close();
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
      rmSync(paths.portFile, { force: true });
      db.close();
    },
  };
}
