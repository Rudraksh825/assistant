import assert from 'node:assert/strict';
import { test } from 'node:test';
import { describeSchedule, isWorkHours, occurrence, parseSchedule } from '../core/scheduler.js';

const at = (y: number, m: number, d: number, h: number, min = 0) => new Date(y, m, d, h, min).getTime();
// 2026-01-15 is a Thursday.
const THU_NOON = at(2026, 0, 15, 12);

test('occurrence finds the previous and next daily slot', () => {
  assert.equal(occurrence('09:00', undefined, THU_NOON, -1), at(2026, 0, 15, 9));
  assert.equal(occurrence('09:00', undefined, THU_NOON, 1), at(2026, 0, 16, 9));
  assert.equal(occurrence('18:30', undefined, THU_NOON, 1), at(2026, 0, 15, 18, 30));
  assert.equal(occurrence('12:00', undefined, THU_NOON, -1), THU_NOON);
});

test('occurrence respects weekdays', () => {
  assert.equal(occurrence('09:00', [1], THU_NOON, -1), at(2026, 0, 12, 9));
  assert.equal(occurrence('09:00', [1], THU_NOON, 1), at(2026, 0, 19, 9));
  assert.equal(occurrence('09:00', [], THU_NOON, 1), null);
  assert.throws(() => occurrence('25:00', undefined, THU_NOON, 1));
});

test('isWorkHours checks day and time window', () => {
  const hours = { start: '09:00', end: '19:00', days: [1, 2, 3, 4, 5] };
  assert.equal(isWorkHours(hours, THU_NOON), true);
  assert.equal(isWorkHours(hours, at(2026, 0, 15, 8, 59)), false);
  assert.equal(isWorkHours(hours, at(2026, 0, 15, 19)), false);
  assert.equal(isWorkHours(hours, at(2026, 0, 17, 12)), false);
});

test('describeSchedule is readable', () => {
  assert.equal(describeSchedule({ everyMin: 15 }), 'every 15m');
  assert.equal(describeSchedule({ everyMin: 120 }), 'every 2h');
  assert.equal(describeSchedule({ at: '09:00', days: [1, 5] }), '09:00 mon,fri');
});

test('parseSchedule accepts both forms and refuses the rest', () => {
  assert.deepEqual(parseSchedule({ everyMin: 20 }), { everyMin: 20 });
  assert.deepEqual(parseSchedule({ at: '08:30', days: [1, 3] }), { at: '08:30', days: [1, 3] });
  assert.deepEqual(parseSchedule({ at: '08:30' }), { at: '08:30' });
  for (const bad of [null, {}, { everyMin: 0 }, { at: '25:00' }, { at: '09:00', days: [7] }, { at: '09:00', days: [] }]) assert.throws(() => parseSchedule(bad), JSON.stringify(bad));
});
