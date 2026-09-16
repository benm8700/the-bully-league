const assert = require("assert");
const {
  readDailyRewardConfig,
  planClaim,
  rewardFor,
  readState,
  prevDayKey,
  DEFAULTS,
  CYCLE_LENGTH,
} = require("../dailyReward");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

console.log("daily reward config");

check("empty config -> defaults", () => {
  const c = readDailyRewardConfig(undefined);
  assert.deepStrictEqual(c.schedule, DEFAULTS.schedule);
  assert.strictEqual(c.enabled, true);
});

check("explicit false disables; typo does not", () => {
  assert.strictEqual(readDailyRewardConfig({dailyRewards: {enabled: false}}).enabled, false);
  assert.strictEqual(readDailyRewardConfig({dailyRewards: {enabled: "no"}}).enabled, true);
});

check("a valid 7-length schedule is taken and rounded", () => {
  const c = readDailyRewardConfig({dailyRewards: {schedule: [1, 2, 3, 4, 5, 6, 7.4]}});
  assert.deepStrictEqual(c.schedule, [1, 2, 3, 4, 5, 6, 7]);
});

check("a wrong-length or dirty schedule is discarded wholesale", () => {
  assert.deepStrictEqual(
      readDailyRewardConfig({dailyRewards: {schedule: [1, 2, 3]}}).schedule,
      DEFAULTS.schedule);
  assert.deepStrictEqual(
      readDailyRewardConfig({dailyRewards: {schedule: [1, 2, 3, 4, 5, 6, -1]}}).schedule,
      DEFAULTS.schedule);
  assert.deepStrictEqual(
      readDailyRewardConfig({dailyRewards: {schedule: [1, 2, 3, 4, 5, 6, "x"]}}).schedule,
      DEFAULTS.schedule);
});

console.log("prevDayKey");

check("steps back a day, including month rollover", () => {
  assert.strictEqual(prevDayKey("2026-09-15"), "2026-09-14");
  assert.strictEqual(prevDayKey("2026-09-01"), "2026-08-31");
  assert.strictEqual(prevDayKey("2026-01-01"), "2025-12-31");
});

console.log("readState");

check("missing / malformed state reads as never-claimed", () => {
  assert.deepStrictEqual(readState({}), {lastClaimDay: null, cycleDay: 0});
  assert.deepStrictEqual(readState({dailyReward: 7}), {lastClaimDay: null, cycleDay: 0});
});

check("cycleDay is clamped to 1..7", () => {
  assert.strictEqual(readState({dailyReward: {lastClaimDay: "2026-09-15", cycleDay: 99}}).cycleDay, 7);
  assert.strictEqual(readState({dailyReward: {lastClaimDay: "2026-09-15", cycleDay: 0}}).cycleDay, 0);
});

console.log("planClaim");

const TODAY = "2026-09-15";
const YESTERDAY = "2026-09-14";

check("first ever claim -> day 1", () => {
  const p = planClaim({lastClaimDay: null, cycleDay: 0}, TODAY, YESTERDAY);
  assert.deepStrictEqual(p, {claimable: true, cycleDay: 1});
});

check("already claimed today -> not claimable, holds the day", () => {
  const p = planClaim({lastClaimDay: TODAY, cycleDay: 3}, TODAY, YESTERDAY);
  assert.strictEqual(p.claimable, false);
  assert.strictEqual(p.cycleDay, 3);
});

check("consecutive day advances the cycle", () => {
  const p = planClaim({lastClaimDay: YESTERDAY, cycleDay: 3}, TODAY, YESTERDAY);
  assert.deepStrictEqual(p, {claimable: true, cycleDay: 4});
});

check("day 7 consecutive wraps to day 1", () => {
  const p = planClaim({lastClaimDay: YESTERDAY, cycleDay: 7}, TODAY, YESTERDAY);
  assert.deepStrictEqual(p, {claimable: true, cycleDay: 1});
});

check("a missed day resets to day 1", () => {
  const p = planClaim({lastClaimDay: "2026-09-10", cycleDay: 5}, TODAY, YESTERDAY);
  assert.deepStrictEqual(p, {claimable: true, cycleDay: 1});
});

console.log("rewardFor");

check("maps 1..7 onto the schedule, clamping out-of-range", () => {
  assert.strictEqual(rewardFor(DEFAULTS.schedule, 1), 20);
  assert.strictEqual(rewardFor(DEFAULTS.schedule, 7), 150);
  assert.strictEqual(rewardFor(DEFAULTS.schedule, 0), 20);
  assert.strictEqual(rewardFor(DEFAULTS.schedule, 99), 150);
});

check("schedule has exactly the cycle length", () => {
  assert.strictEqual(DEFAULTS.schedule.length, CYCLE_LENGTH);
});

console.log(`\n${passed} passed`);
