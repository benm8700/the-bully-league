const assert = require("assert");
const {weekKeyForDay, weekKeys, streakAfterRanked} = require("../rankedStreak");
const {streakAfterEmptyQueue} = require("../voteStreak");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

console.log("rankedStreak");

check("weeks start on Monday", () => {
  assert.strictEqual(weekKeyForDay("2026-11-11"), "2026-11-09"); // Wed
  assert.strictEqual(weekKeyForDay("2026-11-09"), "2026-11-09"); // Mon
  assert.strictEqual(weekKeyForDay("2026-11-15"), "2026-11-09"); // Sun
  assert.strictEqual(weekKeyForDay("2026-11-16"), "2026-11-16"); // next Mon
});

check("week keys cross a month and a year", () => {
  assert.strictEqual(weekKeyForDay("2027-01-01"), "2026-12-28");
});

check("last week is exactly 7 days before this week", () => {
  // 2026-11-11 20:00 UTC = Wednesday midday Pacific.
  const {thisWeek, lastWeek} = weekKeys(Date.UTC(2026, 10, 11, 20));
  assert.strictEqual(thisWeek, "2026-11-09");
  assert.strictEqual(lastWeek, "2026-11-02");
});

check("Sunday night Pacific is still the same week (not UTC Monday)", () => {
  // 2026-11-16 06:00 UTC = Sunday 10pm Pacific.
  assert.strictEqual(weekKeys(Date.UTC(2026, 10, 16, 6)).thisWeek, "2026-11-09");
});

const W = "2026-11-09";
const L = "2026-11-02";
check("first ranked battle starts a 1-week streak", () => {
  const r = streakAfterRanked(undefined, W, L);
  assert.deepStrictEqual([r.weeks, r.weekKey, r.changed], [1, W, true]);
});
check("a second battle in the same week changes nothing", () => {
  const r = streakAfterRanked({weeks: 3, weekKey: W}, W, L);
  assert.deepStrictEqual([r.weeks, r.changed], [3, false]);
});
check("playing last week continues the run", () => {
  const r = streakAfterRanked({weeks: 3, weekKey: L}, W, L);
  assert.deepStrictEqual([r.weeks, r.changed], [4, true]);
});
check("a skipped week resets to 1", () => {
  const r = streakAfterRanked({weeks: 5, weekKey: "2026-10-26"}, W, L);
  assert.strictEqual(r.weeks, 1);
});

console.log("voteStreak empty queue");
const T = "2026-11-11";
const Y = "2026-11-10";
check("an empty queue continues a live streak", () => {
  assert.deepStrictEqual(
      streakAfterEmptyQueue({days: 4, dayKey: Y}, T, Y), {days: 5, dayKey: T});
});
check("an empty queue never starts a streak", () => {
  assert.strictEqual(streakAfterEmptyQueue(undefined, T, Y), null);
  assert.strictEqual(streakAfterEmptyQueue({days: 0, dayKey: Y}, T, Y), null);
});
check("already counted today: no change", () => {
  assert.strictEqual(streakAfterEmptyQueue({days: 2, dayKey: T}, T, Y), null);
});
check("an already broken streak is not revived", () => {
  assert.strictEqual(
      streakAfterEmptyQueue({days: 9, dayKey: "2026-11-08"}, T, Y), null);
});

console.log(`\n${passed} passed`);
