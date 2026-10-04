/**
 * Pure tests for the GOAT throne-threat logic (functions/goatThrone.js).
 * Run: node test/goatThrone.test.js
 */
const assert = require("assert");
const {throneThreat, pairKey} = require("../goatThrone");

const OPTS = {poolSize: 5, minXp: 5000, margin: 75};
// Five XP-eligible GOATs, lowest at 1250.
const GOATS = [
  {uid: "g1", name: "G1", rating: 1600, points: 6000},
  {uid: "g2", name: "G2", rating: 1500, points: 6000},
  {uid: "g3", name: "G3", rating: 1400, points: 6000},
  {uid: "g4", name: "G4", rating: 1300, points: 6000},
  {uid: "g5", name: "G5", rating: 1250, points: 6000},
];

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

test("a close, XP-eligible challenger puts the lowest GOAT under threat", () => {
  const challenger = {uid: "c", name: "Rookie", rating: 1200, points: 6000}; // gap 50
  const t = throneThreat([...GOATS, challenger], OPTS);
  assert.strictEqual(t.underThreat, true);
  assert.strictEqual(t.goat.uid, "g5", "the most vulnerable GOAT is the lowest-rated");
  assert.strictEqual(t.challenger.uid, "c");
});

test("a challenger beyond the margin is NOT a threat", () => {
  const challenger = {uid: "c", name: "Rookie", rating: 1100, points: 6000}; // gap 150
  assert.strictEqual(throneThreat([...GOATS, challenger], OPTS).underThreat, false);
});

test("an open pool (fewer than 5 eligible) is never a threat", () => {
  // Only 4 eligible GOATs + a close challenger: the challenger would JOIN, not
  // displace anyone, so nobody's throne is at risk.
  const four = GOATS.slice(0, 4);
  const challenger = {uid: "c", name: "Rookie", rating: 1240, points: 6000};
  assert.strictEqual(throneThreat([...four, challenger], OPTS).underThreat, false);
});

test("a full pool with NO challenger below it is not a threat", () => {
  assert.strictEqual(throneThreat(GOATS, OPTS).underThreat, false);
});

test("a high-rated but XP-INELIGIBLE player can never threaten the throne", () => {
  // Rating 1248 (gap 2!) but no XP - cannot become GOAT, so not a threat. The
  // only eligible non-GOAT is far below the margin.
  const ineligibleHot = {uid: "x", name: "Lucky", rating: 1248, points: 0};
  const eligibleFar = {uid: "c", name: "Rookie", rating: 1100, points: 6000};
  assert.strictEqual(
      throneThreat([...GOATS, ineligibleHot, eligibleFar], OPTS).underThreat,
      false);
});

test("input order does not matter (sorted internally)", () => {
  const challenger = {uid: "c", name: "Rookie", rating: 1200, points: 6000};
  const shuffled = [challenger, GOATS[2], GOATS[0], GOATS[4], GOATS[1], GOATS[3]];
  const t = throneThreat(shuffled, OPTS);
  assert.strictEqual(t.underThreat, true);
  assert.strictEqual(t.goat.uid, "g5");
  assert.strictEqual(t.challenger.uid, "c");
});

test("a dead heat (gap 0) is under threat", () => {
  const challenger = {uid: "c", name: "Rookie", rating: 1250, points: 6000};
  assert.strictEqual(throneThreat([...GOATS, challenger], OPTS).underThreat, true);
});

test("pairKey is stable and order-sensitive", () => {
  assert.strictEqual(pairKey("a", "b"), "a|b");
  assert.notStrictEqual(pairKey("a", "b"), pairKey("b", "a"));
});

if (process.exitCode) {
  console.error("\ngoatThrone: some checks FAILED");
} else {
  console.log(`goatThrone: ${passed} checks passed`);
}
