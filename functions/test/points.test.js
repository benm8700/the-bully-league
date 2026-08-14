/**
 * The points economy's arithmetic and configuration.
 *
 * The properties worth pinning are the ones that keep a balance honest:
 * points only ever go up, the prime-time bonus is a multiplier on POINTS
 * rather than rating, and a hand-edited config cannot produce a rate that
 * breaks the economy.
 *
 * Idempotence - the part that actually stops balances being inflated by
 * retries - lives in awardPoints's transaction and is exercised against
 * the deployed backend rather than here, because it is a property of the
 * write, not of the arithmetic.
 *
 * Run: node test/points.test.js
 */
const assert = require("assert");
const {awardAmount, readPointsSettings, DEFAULTS, LIMITS} = require("../points");

let checks = 0;
function check(label, fn) {
  fn();
  checks += 1;
  console.log(`  ok  ${label}`);
}

// --- award arithmetic ---

check("an ordinary award is the base rate", () => {
  assert.strictEqual(awardAmount(10), 10);
});

check("the window multiplier doubles it", () => {
  assert.strictEqual(awardAmount(10, {multiplier: 2}), 20);
});

check("awards are whole numbers", () => {
  // A balance shown as 37.5 points would look broken.
  assert.strictEqual(awardAmount(5, {multiplier: 1.5}), 8);
  assert.strictEqual(Number.isInteger(awardAmount(7, {multiplier: 1.3})), true);
});

check("points can never go DOWN", () => {
  // The whole reason this currency exists next to rating: someone on a
  // losing streak has a rating falling and a balance still climbing. A
  // negative award would quietly turn it into a second rating.
  assert.strictEqual(awardAmount(-50), 0);
  assert.strictEqual(awardAmount(10, {multiplier: -3}), 0);
});

check("nonsense inputs award nothing rather than NaN", () => {
  // A NaN written into a balance would poison it permanently - every
  // later increment stays NaN.
  for (const bad of [undefined, null, "lots", NaN, {}]) {
    assert.strictEqual(awardAmount(bad), 0, `base=${String(bad)}`);
    assert.strictEqual(Number.isInteger(awardAmount(10, {multiplier: bad})), true);
  }
});

// --- configuration ---

check("defaults apply when the document is missing", () => {
  assert.deepStrictEqual(readPointsSettings(null), DEFAULTS);
  assert.deepStrictEqual(readPointsSettings(undefined), DEFAULTS);
});

check("a valid override is honoured", () => {
  const s = readPointsSettings({matchWon: 40, voteCast: 8});
  assert.strictEqual(s.matchWon, 40);
  assert.strictEqual(s.voteCast, 8);
});

check("an out-of-range rate falls back rather than breaking the economy", () => {
  // Hand-edited in a console with no validation in between. A win worth a
  // million points would make every cosmetic free forever.
  assert.strictEqual(readPointsSettings({matchWon: 1e9}).matchWon, DEFAULTS.matchWon);
  assert.strictEqual(readPointsSettings({matchWon: -5}).matchWon, DEFAULTS.matchWon);
});

check("one bad field does not discard the rest", () => {
  const s = readPointsSettings({matchWon: "loads", voteCast: 9});
  assert.strictEqual(s.matchWon, DEFAULTS.matchWon);
  assert.strictEqual(s.voteCast, 9);
});

check("the window multiplier can never be less than 1", () => {
  // Below 1 it would become a PENALTY for playing during the window that
  // exists to attract people to it.
  assert.strictEqual(
      readPointsSettings({eventWindowMultiplier: 0.5}).eventWindowMultiplier,
      DEFAULTS.eventWindowMultiplier);
  assert.strictEqual(LIMITS.eventWindowMultiplier.min, 1);
});

check("a rate of zero is allowed, so an award can be switched off", () => {
  // Useful for turning a source off without a release - and awardAmount
  // treats zero as "no award" rather than writing an empty ledger entry.
  assert.strictEqual(readPointsSettings({voteCast: 0}).voteCast, 0);
  assert.strictEqual(awardAmount(0, {multiplier: 2}), 0);
});

// --- the ratios that encode the design ---

check("judging is worth a meaningful fraction of playing", () => {
  // Votes are the scarce resource the whole ladder runs on, and the people
  // whose votes matter most care nothing for cosmetics. If judging paid a
  // rounding error the currency would not move the behaviour that needs
  // moving.
  assert.ok(DEFAULTS.voteCast >= DEFAULTS.matchPlayed / 4,
      `voteCast ${DEFAULTS.voteCast} too small next to matchPlayed ${DEFAULTS.matchPlayed}`);
});

check("winning pays more than merely turning up", () => {
  assert.ok(DEFAULTS.matchWon > DEFAULTS.matchPlayed);
});

check("every configurable rate has a bound", () => {
  // An unbounded rate is one console typo away from breaking the economy.
  for (const key of Object.keys(DEFAULTS)) {
    assert.ok(LIMITS[key], `no bounds for ${key}`);
  }
});

console.log(`\n${checks} checks passed.`);
