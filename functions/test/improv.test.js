/**
 * Local tests for the Improv Station prompt helpers (functions/improv.js).
 * Runs with plain `node test/improv.test.js`.
 *
 * The one property that matters: a match must ALWAYS get exactly the number of
 * prompts it expects, even when the config is missing or garbage - a round
 * with no prompt is a broken match. So most of these pin the fallbacks.
 */

const assert = require("assert");
const {
  readImprovPrompts, pickPrompts, DEFAULT_PROMPTS, MAX_PROMPTS,
} = require("../improv");

let passed = 0;
function check(name, fn) { fn(); passed++; console.log(`  ok - ${name}`); }

console.log("improv - prompts");

check("missing/garbage config falls back to the default catalog", () => {
  assert.deepStrictEqual(readImprovPrompts(undefined), DEFAULT_PROMPTS);
  assert.deepStrictEqual(readImprovPrompts({}), DEFAULT_PROMPTS);
  assert.deepStrictEqual(readImprovPrompts({prompts: "nope"}), DEFAULT_PROMPTS);
  assert.deepStrictEqual(readImprovPrompts({prompts: []}), DEFAULT_PROMPTS);
});

check("config prompts are cleaned (trim, drop empties/dupes/too-long)", () => {
  const out = readImprovPrompts({prompts: [
    "  Airports  ", "Airports", "airports", "", "   ", 42, null,
    "x".repeat(200), "Taxes",
  ]});
  assert.deepStrictEqual(out, ["Airports", "Taxes"]);
});

check("a config that cleans to empty falls back rather than returning none", () => {
  assert.deepStrictEqual(readImprovPrompts({prompts: ["", "   ", 7]}), DEFAULT_PROMPTS);
});

check("pickPrompts returns exactly n, distinct when the pool allows", () => {
  const got = pickPrompts(DEFAULT_PROMPTS, 3, mulberry(1));
  assert.strictEqual(got.length, 3);
  assert.strictEqual(new Set(got).size, 3, "distinct");
  for (const p of got) assert.ok(DEFAULT_PROMPTS.includes(p));
});

check("pickPrompts tops up with repeats when the pool is smaller than n", () => {
  const got = pickPrompts(["only one"], 3, mulberry(2));
  assert.strictEqual(got.length, 3);
  assert.deepStrictEqual(got, ["only one", "only one", "only one"]);
});

check("pickPrompts clamps n to >=1 and <= MAX_PROMPTS", () => {
  assert.strictEqual(pickPrompts(DEFAULT_PROMPTS, 0, mulberry(3)).length, 1);
  assert.strictEqual(
      pickPrompts(DEFAULT_PROMPTS, 999, mulberry(3)).length,
      Math.min(MAX_PROMPTS, DEFAULT_PROMPTS.length));
});

check("empty/garbage pool falls back to the default catalog", () => {
  const got = pickPrompts([], 3, mulberry(4));
  assert.strictEqual(got.length, 3);
  for (const p of got) assert.ok(DEFAULT_PROMPTS.includes(p));
});

// Small deterministic PRNG so the "distinct" assertions are stable.
function mulberry(seed) {
  let a = seed >>> 0;
  return function() {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

console.log(`\n${passed} passed`);
