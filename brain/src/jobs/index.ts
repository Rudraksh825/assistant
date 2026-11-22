import type { AppContext } from '../core/context.js';
import { applySeeds, runBrief, runMeetingPrep, runMemoryDigest, runOnboarding, runSessionTitles, shiftTime } from './briefs.js';
import { registerLooseEnds } from './loose-ends.js';
import { createNudger } from './nudges.js';
import { registerSyncs } from './sync.js';
import { registerTriage } from './triage.js';

/** Register scheduled jobs with `ctx.scheduler.register(...)`. Called once, before the scheduler starts. */
export function registerJobs(ctx: AppContext): void {
  // Under the test runner the jobs would fire into whatever a test is asserting on; tests that want them call installJobs.
  if (!process.env.NODE_TEST_CONTEXT) installJobs(ctx);
}

export function installJobs(ctx: AppContext): void {
  const { scheduler } = ctx;
  const log = ctx.log.child('jobs');
  const nudger = createNudger(ctx);
  scheduler.register({ name: 'nudges', schedule: { everyMin: 1 }, run: () => nudger.sweep() });
  registerTriage(ctx);
  registerLooseEnds(ctx);
  scheduler.register({ name: 'meeting-prep', schedule: { everyMin: 5 }, spends: true, run: () => runMeetingPrep(ctx) });
  scheduler.register({ name: 'session-titles', schedule: { everyMin: 15 }, spends: true, run: () => runSessionTitles(ctx) });
  // Manual only: it stays disabled so the scheduler never starts it, and "run now" still works.
  scheduler.register({ name: 'onboarding-scan', schedule: { at: '04:00' }, enabled: false, run: (trigger) => (trigger === 'manual' ? runOnboarding(ctx) : undefined) });

  // These follow settings (sync periods, work hours); registering again replaces the definition and keeps the history.
  const timed = (): void => {
    const { start, end, days } = ctx.config.get().user.workHours;
    registerSyncs(ctx);
    scheduler.register({ name: 'brief:morning', schedule: { at: start, days }, spends: true, run: (t) => runBrief(ctx, 'morning', t) });
    scheduler.register({ name: 'brief:evening', schedule: { at: shiftTime(end, -30), days }, spends: true, run: (t) => runBrief(ctx, 'evening', t) });
    scheduler.register({ name: 'brief:weekly', schedule: { at: shiftTime(end, -90), days: days.slice(-1) }, spends: true, run: (t) => runBrief(ctx, 'weekly', t) });
    scheduler.register({ name: 'memory-digest', schedule: { at: shiftTime(end, 15), days }, spends: true, run: () => runMemoryDigest(ctx) });
  };
  timed();

  ctx.bus.on('state.changed', ({ entities }) => {
    try {
      if (entities.includes('settings')) timed();
      if (entities.includes('suggestions')) applySeeds(ctx);
    } catch (err) {
      log.error('settings or seed hook failed', err);
    }
  });
}
