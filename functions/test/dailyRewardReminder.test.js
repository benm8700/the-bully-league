/**
 * Pure tests for the daily-reward reminder schedule
 * (functions/dailyRewardReminder.js). Run:
 *   node test/dailyRewardReminder.test.js
 */
const assert = require("assert");
const {reminderDue, TARGET_HOUR_PACIFIC} =
    require("../dailyRewardReminder");

let passed = 0;
function test(name, fn) {
  try {
    fn();
    passed++;
  } catch (e) {
    console.error(`FAIL: ${name}\n  ${e.message}`);
    process.exitCode = 1;
  }
}

const today = "2026-09-29";
const yesterday = "2026-09-28";
const target = TARGET_HOUR_PACIFIC * 60;

test("too early in the day: not due", () => {
  assert.strictEqual(
      reminderDue({minutes: target - 1, dayKey: today, sentDayKey: null}),
      false);
  assert.strictEqual(
      reminderDue({minutes: 0, dayKey: today, sentDayKey: null}),
      false);
});

test("at the target hour, nothing sent today: due", () => {
  assert.strictEqual(
      reminderDue({minutes: target, dayKey: today, sentDayKey: null}),
      true);
});

test("after the target hour, nothing sent today: due", () => {
  assert.strictEqual(
      reminderDue({minutes: target + 120, dayKey: today, sentDayKey: null}),
      true);
});

test("already sent TODAY: not due (idempotent per Pacific day)", () => {
  assert.strictEqual(
      reminderDue({minutes: target + 60, dayKey: today, sentDayKey: today}),
      false);
});

test("sent YESTERDAY is a clean slate: due again today", () => {
  assert.strictEqual(
      reminderDue({minutes: target + 60, dayKey: today, sentDayKey: yesterday}),
      true);
});

test("the target hour is the evening (after the 6-7pm window)", () => {
  assert.ok(TARGET_HOUR_PACIFIC >= 19,
      `expected an evening hour, got ${TARGET_HOUR_PACIFIC}`);
});

if (process.exitCode) {
  console.error("\ndailyRewardReminder: some checks FAILED");
} else {
  console.log(`dailyRewardReminder: ${passed} checks passed`);
}
