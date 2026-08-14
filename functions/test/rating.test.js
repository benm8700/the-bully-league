/**
 * Local tests for Elo rating and vote-confidence weighting
 * (functions/rating.js). Runs with plain `node test/rating.test.js`.
 *
 * The confidence weighting exists because of a concrete, measured problem:
 * before it, a single friendly vote moved 14 rating points at 1200, and
 * 29 such wins reached the Headliner threshold. One friend voting in every
 * match was a straight path up the ladder, indistinguishable from real
 * wins. These tests pin both that the damping works and that it stops
 * damping once a result is genuinely well judged.
 */

const assert = require("assert");
const {
  applyEloChange,
  voteConfidence,
  kFactorForRating,
  computeBaseRankTitle,
  FULL_CONFIDENCE_WEIGHT,
  RATING_FLOOR,
  RANK_TIERS,
} = require("../rating");

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

// --- Confidence curve -----------------------------------------------------

test("no votes means no confidence", () => {
  assert.strictEqual(voteConfidence(0), 0);
  assert.strictEqual(voteConfidence(-1), 0);
  assert.strictEqual(voteConfidence(NaN), 0);
});

test("confidence rises with vote weight and saturates at 1", () => {
  assert.ok(voteConfidence(1) < voteConfidence(5), "more votes means more confidence");
  assert.strictEqual(voteConfidence(FULL_CONFIDENCE_WEIGHT), 1);
  assert.strictEqual(voteConfidence(FULL_CONFIDENCE_WEIGHT * 10), 1, "never exceeds 1");
});

// --- The behaviour this was built to fix ----------------------------------

test("a single vote barely moves rating", () => {
  const before = 1200;
  const after = applyEloChange(before, before, 1, voteConfidence(1));
  const moved = after - before;
  assert.ok(moved >= 1, `a single vote should still count for something, moved ${moved}`);
  assert.ok(moved <= 3, `a single vote should not move much, moved ${moved}`);
});

test("a well-judged match moves the full amount", () => {
  const before = 1200;
  const full = applyEloChange(before, before, 1, voteConfidence(FULL_CONFIDENCE_WEIGHT));
  const unweighted = applyEloChange(before, before, 1);
  assert.strictEqual(full, unweighted,
      "at full confidence the weighting must be a complete no-op");
});

test("collusion via single votes is roughly ten times slower", () => {
  // The concrete regression: climbing from 1200 to the Headliner
  // threshold on one friendly vote per match.
  const target = RANK_TIERS.find((t) => t.title === "Headliner").minRating;
  function matchesToReach(confidence) {
    let rating = 1200;
    let matches = 0;
    while (rating < target && matches < 5000) {
      const next = applyEloChange(rating, 1200, 1, confidence);
      if (next <= rating) break; // rounding floor - can no longer climb
      rating = next;
      matches++;
    }
    return rating >= target ? matches : Infinity;
  }
  const before = matchesToReach(1);
  const after = matchesToReach(voteConfidence(1));
  assert.ok(before < 40, `sanity: unweighted climb was ${before} matches`);
  assert.ok(after >= before * 5,
      `single-vote climb should be far slower: ${before} -> ${after} matches`);
});

// --- Existing behaviour must be unchanged ---------------------------------

test("confidence defaults to full, so existing callers are unaffected", () => {
  assert.strictEqual(applyEloChange(1200, 1200, 1), 1214);
  assert.strictEqual(applyEloChange(1200, 1200, 0), 1186);
});

test("the variable K-factor by rating band still applies", () => {
  // Two independent multipliers: the band covers how settled the PLAYER
  // is, confidence covers how settled the RESULT is.
  assert.strictEqual(kFactorForRating(1100), 40);
  assert.strictEqual(kFactorForRating(1200), 28);
  assert.strictEqual(kFactorForRating(1650), 16);
  const lowRated = applyEloChange(1100, 1100, 1, 1) - 1100;
  const highRated = applyEloChange(1650, 1650, 1, 1) - 1650;
  assert.ok(lowRated > highRated, "newer players still move faster");
});

test("beating a higher-rated opponent still gains more", () => {
  // CLAUDE.md relies on this for tournament random seeding - it must
  // survive the confidence multiplier.
  const upset = applyEloChange(1200, 1500, 1, 1) - 1200;
  const expected = applyEloChange(1200, 1200, 1, 1) - 1200;
  assert.ok(upset > expected, `upset ${upset} should beat even match ${expected}`);
});

test("the rating floor still holds", () => {
  const bottomed = applyEloChange(RATING_FLOOR, 2000, 0, 1);
  assert.ok(bottomed >= RATING_FLOOR, "no bottomless losing spiral");
});

test("a confidence outside 0..1 is clamped rather than trusted", () => {
  assert.strictEqual(applyEloChange(1200, 1200, 1, 5), applyEloChange(1200, 1200, 1, 1));
  assert.strictEqual(applyEloChange(1200, 1200, 1, -2), 1200, "negative cannot reverse a win");
});

// --- Tier computation, unchanged ------------------------------------------

test("rank titles still require both rating and matches played", () => {
  assert.strictEqual(computeBaseRankTitle(1500, 0), "Average Joe",
      "a high rating with no matches must not grant a high rank");
  assert.strictEqual(computeBaseRankTitle(1500, 20), "Headliner");
});

console.log(`rating: ${passed} checks passed`);
