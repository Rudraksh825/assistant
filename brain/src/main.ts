import { startBrain } from './app.js';

// The database, logs and port file hold personal data: owner-only, whatever the inherited umask.
process.umask(0o077);

const standalone = process.argv.includes('--standalone');
const brain = await startBrain();
const log = brain.ctx.log;

let stopping = false;
async function shutdown(reason: string): Promise<void> {
  if (stopping) return;
  stopping = true;
  log.info(`shutting down: ${reason}`);
  // A stuck job or collector must not keep a quitting app's child alive.
  setTimeout(() => process.exit(1), 5000).unref();
  await brain.stop();
  process.exit(0);
}

process.on('SIGTERM', () => void shutdown('SIGTERM'));
process.on('SIGINT', () => void shutdown('SIGINT'));
process.on('unhandledRejection', (err) => log.error('unhandled rejection', err));
process.on('uncaughtException', (err) => {
  log.error('uncaught exception', err);
  process.exit(1);
});

if (!standalone) {
  // The app spawns the brain. If the app dies without killing us we are reparented, and must not linger holding the DB.
  const parent = process.ppid;
  setInterval(() => {
    if (process.ppid !== parent) void shutdown('parent process exited');
  }, 2000).unref();
}
