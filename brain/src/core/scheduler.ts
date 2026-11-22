import type { Bus } from './bus.js';
import type { Config, ConfigStore } from './config.js';
import type { Cost } from './cost.js';
import type { Db } from './db.js';
import type { Log } from './log.js';
import type { Ms } from './types.js';
import { conflict, DAY, HOUR, invalid, isPlainObject, MIN, notFound, startOfDay } from './util.js';

/** Every N minutes, or daily at local "HH:MM" on the given weekdays (0 = Sunday; omitted = every day). */
export type Schedule = { everyMin: number } | { at: string; days?: number[] };

export interface JobDef {
  name: string;
  schedule: Schedule;
  run(trigger: 'schedule' | 'manual'): Promise<void> | void;
  /** Initial state only; once a job has run or been toggled, the stored flag wins. Default true. */
  enabled?: boolean;
  /** Skip scheduled runs outside config.user.workHours. */
  workHoursOnly?: boolean;
  /** The job makes LLM calls: scheduled runs are skipped once the budget is spent. */
  spends?: boolean;
}

export interface JobInfo {
  name: string; schedule: string; lastRunAt: Ms | null; lastStatus: string | null; nextRunAt: Ms | null; enabled: boolean; running: boolean;
  /** The schedule in force, structured, and whether the user set it (false = the job's own default). */
  scheduleSpec: Schedule; customSchedule: boolean;
}

/** `override` is the user's schedule from `PATCH /jobs/:name`; it wins over the definition's and survives restarts. */
interface Job { def: JobDef; override: Schedule | null; enabled: boolean; lastRunAt: Ms | null; lastStatus: string | null; running: Promise<void> | null; since: Ms; rescheduledAt: Ms }

// A daily job missed by more than this (machine asleep, brain down) waits for its next slot.
const CATCH_UP = 4 * HOUR;
const TICK = 30_000;
const WEEKDAYS = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];

function minutesOf(hhmm: string): number {
  const m = /^(\d{1,2}):(\d{2})$/.exec(hhmm);
  if (!m || +m[1]! > 23 || +m[2]! > 59) throw new Error(`bad time "${hhmm}", expected HH:MM`);
  return +m[1]! * 60 + +m[2]!;
}

export function isWorkHours(hours: Config['user']['workHours'], now: Ms = Date.now()): boolean {
  const d = new Date(now);
  const minute = d.getHours() * 60 + d.getMinutes();
  return hours.days.includes(d.getDay()) && minute >= minutesOf(hours.start) && minute < minutesOf(hours.end);
}

/** The slot of a daily schedule nearest to `now`: the latest one at or before it (dir -1) or the first one after it (dir 1). */
export function occurrence(at: string, days: number[] | undefined, now: Ms, dir: -1 | 1): Ms | null {
  const minutes = minutesOf(at);
  for (let i = 0; i <= 7; i++) {
    const d = new Date(startOfDay(now));
    d.setDate(d.getDate() + i * dir);
    d.setHours(Math.floor(minutes / 60), minutes % 60);
    const t = d.getTime();
    if ((dir === -1 ? t <= now : t > now) && (!days || days.includes(d.getDay()))) return t;
  }
  return null;
}

/** Untrusted input → a Schedule, or a 400. */
export function parseSchedule(input: unknown): Schedule {
  if (!isPlainObject(input)) throw invalid('schedule must be { everyMin } or { at, days? }');
  if (typeof input.everyMin === 'number') {
    if (!(input.everyMin >= 1)) throw invalid('everyMin must be at least 1');
    return { everyMin: Math.round(input.everyMin) };
  }
  if (typeof input.at !== 'string') throw invalid('schedule must be { everyMin } or { at, days? }');
  try {
    minutesOf(input.at);
  } catch (err) {
    throw invalid((err as Error).message);
  }
  const days = input.days;
  if (days !== undefined && (!Array.isArray(days) || !days.length || days.some((d) => !Number.isInteger(d) || d < 0 || d > 6))) throw invalid('days must be weekday numbers 0..6 (0 = Sunday)');
  return days ? { at: input.at, days: days as number[] } : { at: input.at };
}

export function describeSchedule(s: Schedule): string {
  if ('everyMin' in s) return s.everyMin % 60 === 0 ? `every ${s.everyMin / 60}h` : `every ${s.everyMin}m`;
  return s.days ? `${s.at} ${s.days.map((d) => WEEKDAYS[d]).join(',')}` : `${s.at} daily`;
}

export class Scheduler {
  private jobs = new Map<string, Job>();
  private timer: NodeJS.Timeout | null = null;
  private firstTick: NodeJS.Immediate | null = null;

  constructor(private deps: { db: Db; bus: Bus; log: Log; config: ConfigStore; cost: Cost }) {}

  /** Registering an existing name replaces its definition and keeps its history. */
  register(def: JobDef): void {
    if (!('everyMin' in def.schedule)) minutesOf(def.schedule.at);
    else if (!(def.schedule.everyMin > 0)) throw new Error(`job ${def.name}: everyMin must be positive`);
    const existing = this.jobs.get(def.name);
    if (existing) existing.def = def;
    else {
      const row = this.deps.db.prepare('SELECT enabled, lastRunAt, lastStatus, schedule FROM jobs WHERE name = ?').get(def.name) as
        { enabled: number; lastRunAt: number | null; lastStatus: string | null; schedule: string | null } | undefined;
      this.jobs.set(def.name, {
        def,
        override: row?.schedule ? (JSON.parse(row.schedule) as Schedule) : null,
        enabled: row ? !!row.enabled : def.enabled ?? true,
        lastRunAt: row?.lastRunAt ?? null,
        // 'running' on disk means the previous process died mid-run.
        lastStatus: row?.lastStatus === 'running' ? 'interrupted' : row?.lastStatus ?? null,
        running: null,
        since: Date.now(),
        rescheduledAt: 0,
      });
    }
    this.deps.bus.changed('jobs');
  }

  unregister(name: string): void {
    if (this.jobs.delete(name)) this.deps.bus.changed('jobs');
  }

  list(now: Ms = Date.now()): JobInfo[] {
    return [...this.jobs.values()].map((j) => ({
      name: j.def.name,
      schedule: describeSchedule(j.override ?? j.def.schedule),
      lastRunAt: j.lastRunAt,
      lastStatus: j.lastStatus,
      nextRunAt: j.enabled ? this.nextRunAt(j, now) : null,
      enabled: j.enabled,
      running: !!j.running,
      scheduleSpec: j.override ?? j.def.schedule,
      customSchedule: j.override !== null,
    }));
  }

  setEnabled(name: string, enabled: boolean): void {
    const job = this.must(name);
    job.enabled = enabled;
    this.persist(job);
  }

  /** The user's schedule for a job; null goes back to the job's own. */
  setSchedule(name: string, schedule: Schedule | null): void {
    const job = this.must(name);
    job.override = schedule;
    // A slot the new schedule puts in the past is not a missed run.
    job.rescheduledAt = Date.now();
    this.persist(job);
  }

  /** Starts the job and returns its completion. Throws at once if the job is unknown or already running. */
  runNow(name: string): Promise<void> {
    const job = this.must(name);
    if (job.running) throw conflict(`job ${name} is already running`);
    return this.run(job, 'manual');
  }

  isWorkHours(now: Ms = Date.now()): boolean {
    return isWorkHours(this.deps.config.get().user.workHours, now);
  }

  start(): void {
    if (this.timer) return;
    this.timer = setInterval(() => this.tick(), TICK);
    this.timer.unref();
    this.firstTick = setImmediate(() => this.tick());
  }

  /** Stops scheduling and waits for running jobs to settle. */
  async stop(): Promise<void> {
    if (this.timer) clearInterval(this.timer);
    if (this.firstTick) clearImmediate(this.firstTick);
    this.timer = this.firstTick = null;
    await Promise.allSettled([...this.jobs.values()].map((j) => j.running));
  }

  tick(now: Ms = Date.now()): void {
    for (const job of this.jobs.values()) {
      if (!job.enabled || job.running || this.nextRunAt(job, now) > now) continue;
      if (job.def.workHoursOnly && !this.isWorkHours(now)) continue;
      if (job.def.spends && !this.deps.cost.canSpendBackground()) continue;
      void this.run(job, 'schedule');
    }
  }

  private nextRunAt(job: Job, now: Ms): Ms {
    const s = job.override ?? job.def.schedule;
    if ('everyMin' in s) return job.lastRunAt === null ? job.since : job.lastRunAt + s.everyMin * MIN;
    const last = occurrence(s.at, s.days, now, -1);
    const missed = last !== null && last > Math.max(job.lastRunAt ?? job.since, job.rescheduledAt) && now - last <= CATCH_UP;
    return missed ? last : occurrence(s.at, s.days, now, 1) ?? now + 7 * DAY;
  }

  private run(job: Job, trigger: 'schedule' | 'manual'): Promise<void> {
    const log = this.deps.log.child(`job:${job.def.name}`);
    job.lastRunAt = Date.now();
    job.lastStatus = 'running';
    job.running = (async () => {
      try {
        await job.def.run(trigger);
        job.lastStatus = 'ok';
      } catch (err) {
        job.lastStatus = `error: ${(err as Error).message ?? err}`;
        log.error('failed', err);
      } finally {
        job.running = null;
        this.persist(job);
      }
    })();
    this.persist(job);
    return job.running;
  }

  private must(name: string): Job {
    const job = this.jobs.get(name);
    if (!job) throw notFound(`job ${name}`);
    return job;
  }

  private persist(job: Job): void {
    this.deps.db
      .prepare('INSERT INTO jobs (name, enabled, lastRunAt, lastStatus, schedule) VALUES (?, ?, ?, ?, ?) ON CONFLICT(name) DO UPDATE SET enabled = excluded.enabled, lastRunAt = excluded.lastRunAt, lastStatus = excluded.lastStatus, schedule = excluded.schedule')
      .run(job.def.name, job.enabled ? 1 : 0, job.lastRunAt, job.lastStatus, job.override ? JSON.stringify(job.override) : null);
    this.deps.bus.changed('jobs');
  }
}
