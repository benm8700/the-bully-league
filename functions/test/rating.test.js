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
  computeTitleFromXp,
  FULL_CONFIDENCE_WEIGHT,
  RATING_FLOOR,
  RANK_TIERS,
  XP_TIERS,
  GOAT_ELIGIBLE_MIN_XP,
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

// --- XP ladder (2026-08-25) -----------------------------------------------

test("XP titles use the same strings and order as the Elo ladder", () => {
  // Everything downstream (rank-change copy, ORDER, matchmaking bands) keys
  // on these exact strings. If the two ladders ever disagree on the titles
  // or their order, a promotion could be announced as a demotion - the
  // exact bug that put this copy server-side. Pin them together.
  assert.deepStrictEqual(
      XP_TIERS.map((t) => t.title),
      RANK_TIERS.map((t) => t.title),
      "XP tier titles must match the Elo tier titles one-for-one");
});

test("a brand-new account with no XP is Average Joe", () => {
  assert.strictEqual(computeTitleFromXp(0), "Average Joe");
  assert.strictEqual(computeTitleFromXp(undefined), "Average Joe");
  assert.strictEqual(computeTitleFromXp(NaN), "Average Joe");
  assert.strictEqual(computeTitleFromXp(-100), "Average Joe",
      "a nonsense negative floors rather than throwing");
});

test("each XP threshold lands exactly on its title, one below stays under", () => {
  for (let i = 0; i < XP_TIERS.length; i++) {
    const tier = XP_TIERS[i];
    assert.strictEqual(computeTitleFromXp(tier.minXp), tier.title,
        `${tier.minXp} XP should be ${tier.title}`);
    if (i > 0) {
      assert.strictEqual(computeTitleFromXp(tier.minXp - 1), XP_TIERS[i - 1].title,
          `one XP below ${tier.title} should still be ${XP_TIERS[i - 1].title}`);
    }
  }
});

test("XP titles are monotonic - more XP never means a lower title", () => {
  let lastIndex = -1;
  for (let xp = 0; xp <= 6000; xp += 25) {
    const idx = XP_TIERS.findIndex((t) => t.title === computeTitleFromXp(xp));
    assert.ok(idx >= lastIndex, `title went backwards at ${xp} XP`);
    lastIndex = idx;
  }
});

test("the XP curve steepens - each gap is at least as large as the last", () => {
  // The scarcity argument: higher titles must cost progressively more, or
  // the top stops being scarce. Guards a careless edit to the thresholds.
  for (let i = 2; i < XP_TIERS.length; i++) {
    const gap = XP_TIERS[i].minXp - XP_TIERS[i - 1].minXp;
    const prevGap = XP_TIERS[i - 1].minXp - XP_TIERS[i - 2].minXp;
    assert.ok(gap >= prevGap,
        `gap into ${XP_TIERS[i].title} (${gap}) is smaller than the one before it (${prevGap})`);
  }
});

test("the top XP title is below GOAT eligibility, and GOAT is not an XP tier", () => {
  assert.strictEqual(GOAT_ELIGIBLE_MIN_XP, XP_TIERS[XP_TIERS.length - 1].minXp,
      "GOAT eligibility is earning to the top of the visible ladder");
  assert.ok(!XP_TIERS.some((t) => t.title === "GOAT"),
      "GOAT is a live Elo position, never an XP threshold");
});

console.log(`rating: ${passed} checks passed`);
