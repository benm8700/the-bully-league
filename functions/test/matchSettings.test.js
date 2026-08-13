/**
 * Local tests for match-timing config resolution (functions/
 * matchSettings.js). Runs with plain `node test/matchSettings.test.js`.
 *
 * Worth testing directly because this config is edited by hand in the
 * Firebase console against a LIVE app, with no validation layer in
 * between. A typo there reaches real matches, so the merge order and the
 * bounds are the whole safety net.
 */

const assert = require("assert");
const {resolveSettings, DEFAULTS} = require("../matchSettings");

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

test("a missing document falls back to the documented V1 defaults", () => {
  assert.deepStrictEqual(resolveSettings(null, "ranked"), DEFAULTS);
});

test("an empty document falls back to defaults", () => {
  assert.deepStrictEqual(resolveSettings({}, "ranked"), DEFAULTS);
});

test("top-level values override the defaults", () => {
  const r = resolveSettings({roundCount: 5, roundLengthSeconds: 30}, "ranked");
  assert.strictEqual(r.roundCount, 5);
  assert.strictEqual(r.roundLengthSeconds, 30);
  assert.strictEqual(r.countdownSeconds, DEFAULTS.countdownSeconds, "untouched fields keep defaults");
});

test("a per-mode override beats the top-level value", () => {
  const doc = {roundCount: 5, perMode: {tournament: {roundCount: 7}}};
  assert.strictEqual(resolveSettings(doc, "tournament").roundCount, 7);
  assert.strictEqual(resolveSettings(doc, "ranked").roundCount, 5, "other modes keep the top-level value");
});

test("a per-mode block for a different mode is ignored", () => {
  const doc = {perMode: {exhibition: {roundLengthSeconds: 99}}};
  assert.strictEqual(resolveSettings(doc, "ranked").roundLengthSeconds, DEFAULTS.roundLengthSeconds);
});

// --- The bounds, which are what actually protect live matches ----------

test("roundCount of 0 is refused - it would end a match before it began", () => {
  assert.strictEqual(resolveSettings({roundCount: 0}, "ranked").roundCount, DEFAULTS.roundCount);
});

test("an absurd turn length is refused", () => {
  // 9999s would strand two people staring at each other for nearly 3 hours.
  assert.strictEqual(
      resolveSettings({roundLengthSeconds: 9999}, "ranked").roundLengthSeconds,
      DEFAULTS.roundLengthSeconds,
  );
});

test("a negative value is refused", () => {
  assert.strictEqual(resolveSettings({countdownSeconds: -5}, "ranked").countdownSeconds,
      DEFAULTS.countdownSeconds);
});

test("non-numeric junk is refused rather than crashing", () => {
  const r = resolveSettings({roundCount: "three", roundLengthSeconds: null, bioRevealSeconds: {}}, "ranked");
  assert.deepStrictEqual(r, DEFAULTS);
});

test("a bad per-mode value falls back to the top-level value, not the default", () => {
  // The point of the fallback chain: one bad override shouldn't discard a
  // perfectly good top-level setting the developer also configured.
  const doc = {roundLengthSeconds: 20, perMode: {ranked: {roundLengthSeconds: 9999}}};
  assert.strictEqual(resolveSettings(doc, "ranked").roundLengthSeconds, 20);
});

test("fractional values are rounded to whole seconds", () => {
  assert.strictEqual(resolveSettings({roundLengthSeconds: 15.6}, "ranked").roundLengthSeconds, 16);
});

test("countdownSeconds of 0 is allowed - skipping the countdown is legitimate", () => {
  assert.strictEqual(resolveSettings({countdownSeconds: 0}, "ranked").countdownSeconds, 0);
});

test("every resolved field is always present and a number", () => {
  const r = resolveSettings({roundCount: "junk"}, "exhibition");
  for (const field of Object.keys(DEFAULTS)) {
    assert.strictEqual(typeof r[field], "number", `${field} must always resolve to a number`);
  }
});

console.log(`matchSettings: ${passed} checks passed`);
