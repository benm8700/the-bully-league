/**
 * Local tests for the season soft reset (functions/seasonReset.js).
 * Runs with `node test/seasonReset.test.js`.
 *
 * This rewrites the number the entire ladder is built on, for every
 * account at once, and there is no undo beyond the archive it writes
 * first. So the arithmetic and the side effects are pinned exactly rather
 * than inferred from a successful run.
 */

const assert = require("assert");
const {pulledRating, resetFor, DEFAULT_PULL, PULL_LIMITS} =
  require("../seasonReset");
const {STARTING_RATING, computeBaseRankTitle} = require("../rating");

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

// --- the pull -------------------------------------------------------------

test("SOFT, not hard: half the distance to the centre", () => {
  assert.strictEqual(pulledRating(1400, 0.5), 1300);
  assert.strictEqual(pulledRating(1000, 0.5), 1100);
});

test("it pulls from BOTH sides, not just the top", () => {
  // A reset that only dragged leaders down would be a punishment for
  // winning rather than a compression of the spread.
  assert.ok(pulledRating(1600, 0.5) < 1600);
  assert.ok(pulledRating(800, 0.5) > 800);
});

test("someone already at the centre does not move", () => {
  assert.strictEqual(pulledRating(STARTING_RATING, 0.5), STARTING_RATING);
});

test("skill ORDER survives - that is what makes it soft", () => {
  const before = [900, 1100, 1200, 1350, 1600];
  const after = before.map((r) => pulledRating(r, DEFAULT_PULL));
  for (let i = 1; i < after.length; i++) {
    assert.ok(after[i] > after[i - 1],
        `${before[i]} and ${before[i - 1]} were reordered`);
  }
});

test("a bad pull falls back rather than flattening the ladder", () => {
  // This arrives from an admin call. A pull of 1 is a hard reset and a
  // pull of 0 is a no-op that would look like a broken button.
  for (const bad of [0, 1, -1, 5, "half", null, undefined, NaN]) {
    assert.strictEqual(pulledRating(1400, bad), pulledRating(1400, DEFAULT_PULL),
        `accepted a pull of ${String(bad)}`);
  }
  assert.ok(PULL_LIMITS.min > 0 && PULL_LIMITS.max < 1);
});

test("a missing or junk rating is treated as the starting one", () => {
  assert.strictEqual(pulledRating(undefined, 0.5), STARTING_RATING);
  assert.strictEqual(pulledRating("high", 0.5), STARTING_RATING);
});

// --- what a reset does to an account -------------------------------------

test("THE PLACEMENT PERIOD: the season counter goes to zero", () => {
  const r = resetFor({rating: 1500, rankedMatchesPlayed: 40}, 0.5);
  assert.strictEqual(r.rankedMatchesPlayed, 0);
  assert.strictEqual(r.rankTitle, computeBaseRankTitle(r.rating, 0),
      "the title must reflect having played nothing this season");
});

test("THE CAREER TOTAL SURVIVES, which is what stops a reset breaking the "
    + "window's ranked-only rule", () => {
  // The entitlement carve-out lets a genuinely new player practise during
  // the window. If it read the season counter, a reset would hand that
  // exemption to the entire userbase at once.
  const r = resetFor({rating: 1500, rankedMatchesPlayed: 40}, 0.5);
  assert.strictEqual(r.careerRankedMatches, 40);
});

test("a second reset does not restart the career total", () => {
  const first = resetFor({rating: 1500, rankedMatchesPlayed: 40}, 0.5);
  const second = resetFor({...first}, 0.5);
  assert.strictEqual(second.careerRankedMatches, 40,
      "career must not be re-seeded from the zeroed season counter");
});

test("MIGRATION: an account with no career field keeps its history", () => {
  // Every account predating this field. Reading a missing career total as
  // zero would say "never played" about someone with a hundred matches.
  const r = resetFor({rating: 1300, rankedMatchesPlayed: 100}, 0.5);
  assert.strictEqual(r.careerRankedMatches, 100);
});

test("THE ANNOUNCEMENT IS SUPPRESSED, or everyone is roasted at once", () => {
  // A reset moves almost everybody down a tier simultaneously. Without
  // this the next sweep pushes a demotion message to the entire userbase
  // on the one day it says nothing about how they played.
  const r = resetFor({rating: 1600, rankedMatchesPlayed: 40,
    rankTitle: "Headliner", lastNotifiedRankTitle: "Headliner",
    lastSeenRankTitle: "Headliner"}, 0.5);
  assert.strictEqual(r.lastNotifiedRankTitle, r.rankTitle);
  assert.strictEqual(r.lastSeenRankTitle, r.rankTitle);
});

test("wins and losses are left alone", () => {
  // A career record. The reset is about the ladder, not about erasing
  // what somebody did.
  const r = resetFor({rating: 1400, wins: 20, losses: 9}, 0.5);
  assert.strictEqual(r.wins, undefined, "the reset must not write wins");
  assert.strictEqual(r.losses, undefined);
});

test("points and the balance are untouched", () => {
  const r = resetFor({rating: 1400, points: 900, pointsBalance: 400}, 0.5);
  assert.strictEqual(r.points, undefined);
  assert.strictEqual(r.pointsBalance, undefined);
});

console.log(`seasonReset: ${passed} checks passed`);
