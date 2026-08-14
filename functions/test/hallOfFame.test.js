/**
 * The all-time hall of fame's ranking.
 *
 * The property that matters is that it stays a hall of fame rather than
 * degenerating into a list of recent matches as the app grows - which is
 * exactly what raw counts would do.
 *
 * Run: node test/hallOfFame.test.js
 */
const assert = require("assert");
const {
  selectHall,
  acclaimCount,
  eraKeyOf,
  HALL_SIZE,
  ACCLAIM,
} = require("../hallOfFame");

let checks = 0;
function check(label, fn) {
  fn();
  checks += 1;
  console.log(`  ok  ${label}`);
}

const MONTH = 30 * 24 * 60 * 60 * 1000;
const NOW = Date.parse("2026-08-14T00:00:00Z");

const battle = (id, {votes = 10, fire = 0, crickets = 0, ageMs = 0} = {}) => ({
  matchId: id,
  voteCount: votes,
  reactionCounts: {fire, crickets},
  completedAtMs: NOW - ageMs,
});

check("the best battle of a set wins", () => {
  const hall = selectHall([
    battle("meh", {votes: 5}),
    battle("great", {votes: 50}),
    battle("ok", {votes: 12}),
  ]);
  assert.strictEqual(hall[0].matchId, "great");
});

check("the hall is capped", () => {
  const many = Array.from({length: 40}, (_, i) => battle(`m${i}`, {votes: i + 1}));
  assert.strictEqual(selectHall(many).length, HALL_SIZE);
});

check("GROWTH DOES NOT PUSH OUT AN OLDER LEGEND", () => {
  // The whole reason this is scored against its era. A ten-times-median
  // battle from a quiet first month must outrank a merely-average one from
  // a month with ten times the traffic - otherwise the hall of fame
  // silently becomes a list of whatever happened most recently.
  const hall = selectHall([
    // Early era: median around 5, this one is a genuine standout.
    battle("earlyLegend", {votes: 50, ageMs: 6 * MONTH}),
    battle("earlyA", {votes: 5, ageMs: 6 * MONTH}),
    battle("earlyB", {votes: 5, ageMs: 6 * MONTH}),
    // Recent era: ten times the traffic, but this one is unremarkable.
    battle("recentAverage", {votes: 100, ageMs: 0}),
    battle("recentA", {votes: 100, ageMs: 0}),
    battle("recentB", {votes: 100, ageMs: 0}),
  ], {size: 1});
  assert.strictEqual(hall[0].matchId, "earlyLegend",
      "an era-relative standout must beat a recent average one");
});

check("acclaim counts toward greatness", () => {
  // Votes say how many showed up; reactions say what they thought.
  const hall = selectHall([
    battle("watched", {votes: 20, fire: 0}),
    battle("loved", {votes: 20, fire: 30}),
  ], {size: 1});
  assert.strictEqual(hall[0].matchId, "loved");
});

check("bombing does NOT make a battle a legend", () => {
  // Crickets and the rest are honest feedback and count toward how watched
  // something was, but a hall of fame partly ranked on them would enshrine
  // the worst sets alongside the best.
  const hall = selectHall([
    battle("bombed", {votes: 20, crickets: 100}),
    battle("killed", {votes: 20, fire: 10}),
  ], {size: 1});
  assert.strictEqual(hall[0].matchId, "killed");
});

check("only positive reactions count as acclaim", () => {
  assert.strictEqual(acclaimCount({reactionCounts: {crickets: 99, yawn: 99}}), 0);
  assert.strictEqual(acclaimCount({reactionCounts: {fire: 3, skull: 2}}), 5);
  assert.strictEqual(acclaimCount({}), 0);
  assert.strictEqual(acclaimCount(null), 0);
});

check("every acclaim key is a real reaction", () => {
  // A typo here would silently drop a reaction from the ranking.
  const {REACTIONS} = require("../reactions");
  for (const key of ACCLAIM) {
    assert.ok(REACTIONS.includes(key), `${key} is not a reaction`);
  }
});

check("a battle nobody engaged with is never a legend", () => {
  // However quiet its month was.
  assert.deepStrictEqual(
      selectHall([battle("ignored", {votes: 0, fire: 0})]), []);
});

check("an empty set yields an empty hall", () => {
  assert.deepStrictEqual(selectHall([]), []);
});

check("ties break toward the more recent battle", () => {
  const hall = selectHall([
    battle("older", {votes: 10, ageMs: 2 * MONTH}),
    battle("newer", {votes: 10, ageMs: 2 * MONTH - 1000}),
  ], {size: 1});
  assert.strictEqual(hall[0].matchId, "newer");
});

check("eras are calendar months", () => {
  assert.strictEqual(eraKeyOf(Date.parse("2026-08-31T23:59:59Z")), "2026-08");
  assert.strictEqual(eraKeyOf(Date.parse("2026-09-01T00:00:01Z")), "2026-09");
});

check("a single-battle era does not divide by zero", () => {
  const hall = selectHall([battle("alone", {votes: 3})]);
  assert.strictEqual(hall.length, 1);
  assert.ok(Number.isFinite(hall[0].score), `${hall[0].score}`);
});

console.log(`\n${checks} checks passed.`);
