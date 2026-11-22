import type { AppContext } from '../core/context.js';
import { createActivityEnricher } from './activity.js';
import { createBadgeCollector } from './badges.js';
import { createBrowserCollector } from './browser.js';
import { createSessionCollector } from './claude-sessions.js';
import { createPrCollector } from './git-prs.js';
import { createMessagesCollector } from './messages.js';
import { resolveBin, settings } from './settings.js';

/** Start every collector. `stop` must end their timers, watchers and child processes. */
export async function startCollectors(ctx: AppContext): Promise<{ stop(): Promise<void> }> {
  // Collectors read this machine's real data (other apps' files, `gh`, the Dock). Test runs must not, so they
  // construct the collectors they exercise themselves, against fixtures.
  if (process.env.STEWARD_COLLECTORS === 'off' || process.env.NODE_TEST_CONTEXT) return { async stop() {} };

  const prs = createPrCollector(ctx);
  const sessions = createSessionCollector(ctx);
  const badges = createBadgeCollector(ctx);
  const browser = createBrowserCollector(ctx);
  const messages = createMessagesCollector(ctx);
  const activity = createActivityEnricher(ctx);

  // The app starts the brain with launchd's bare PATH; one line says what was found there, for when something is missing.
  const { claudeBin, ghBin } = settings(ctx).code;
  void Promise.all([resolveBin('claude', claudeBin), resolveBin('gh', ghBin)]).then(([claude, gh]) =>
    ctx.log.child('collectors').info('binaries', { node: process.execPath, claude, gh, path: process.env.PATH }));

  // Nothing here may hold up the HTTP server coming up: the first passes run in the background.
  void sessions.reconcile().then(() => {
    sessions.poll();
    void prs.refresh();
  });
  for (const collector of [badges, browser, messages]) {
    try {
      collector.start();
    } catch (err) {
      ctx.log.error('collector failed to start', err);
    }
  }

  return {
    async stop() {
      for (const collector of [sessions, prs, badges, browser, messages, activity]) collector.stop();
    },
  };
}
