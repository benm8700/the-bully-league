/**
 * Pure tests for the emoji-cleanup logic (functions/emojiScrub.js).
 * Run: node test/emojiScrub.test.js
 */
const assert = require("assert");
const {
  scrubPlan, removableEmojiKeys, isRemovableEmoji, scrubUsedToday,
} = require("../emojiScrub");

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

test("only the NEGATIVE emojis are removable (derived from the shared set)", () => {
  assert.deepStrictEqual(removableEmojiKeys().sort(),
      ["boring", "red_flag", "trash"]);
  assert.strictEqual(isRemovableEmoji("boring"), true);
  assert.strictEqual(isRemovableEmoji("trash"), true);
  // The two positives can never be cleaned up.
  assert.strictEqual(isRemovableEmoji("fire"), false);
  assert.strictEqual(isRemovableEmoji("clever"), false);
  // Garbage is refused.
  assert.strictEqual(isRemovableEmoji("nope"), false);
  assert.strictEqual(isRemovableEmoji(null), false);
});

test("scrubPlan removes the requested amount when nothing else binds", () => {
  const p = scrubPlan({current: 20, requested: 5, dailyRemaining: 25, balance: 1000, price: 10});
  assert.deepStrictEqual(p, {removed: 5, cost: 50});
});

test("scrubPlan is clamped by the current count", () => {
  const p = scrubPlan({current: 3, requested: 5, dailyRemaining: 25, balance: 1000, price: 10});
  assert.deepStrictEqual(p, {removed: 3, cost: 30});
});

test("scrubPlan is clamped by the daily remaining", () => {
  const p = scrubPlan({current: 50, requested: 10, dailyRemaining: 4, balance: 1000, price: 10});
  assert.deepStrictEqual(p, {removed: 4, cost: 40});
});

test("scrubPlan is clamped by what the balance can afford", () => {
  // Balance 35 at 10/each affords 3.
  const p = scrubPlan({current: 50, requested: 10, dailyRemaining: 25, balance: 35, price: 10});
  assert.deepStrictEqual(p, {removed: 3, cost: 30});
});

test("scrubPlan removes nothing when the balance can't afford one", () => {
  const p = scrubPlan({current: 50, requested: 5, dailyRemaining: 25, balance: 9, price: 10});
  assert.deepStrictEqual(p, {removed: 0, cost: 0});
});

test("scrubPlan removes nothing when there is nothing to remove", () => {
  const p = scrubPlan({current: 0, requested: 5, dailyRemaining: 25, balance: 1000, price: 10});
  assert.deepStrictEqual(p, {removed: 0, cost: 0});
});

test("scrubPlan tolerates junk and never goes negative", () => {
  const p = scrubPlan({current: -4, requested: NaN, dailyRemaining: "x", balance: null, price: 0});
  assert.strictEqual(p.removed, 0);
  assert.strictEqual(p.cost, 0);
});

test("scrubUsedToday resets on a new day and reads a same-day count", () => {
  assert.strictEqual(scrubUsedToday({}, "2026-10-03"), 0);
  assert.strictEqual(scrubUsedToday(null, "2026-10-03"), 0);
  assert.strictEqual(
      scrubUsedToday({emojiScrub: {day: "2026-10-02", count: 9}}, "2026-10-03"), 0);
  assert.strictEqual(
      scrubUsedToday({emojiScrub: {day: "2026-10-03", count: 9}}, "2026-10-03"), 9);
});

if (process.exitCode) {
  console.error("\nemojiScrub: some checks FAILED");
} else {
  console.log(`emojiScrub: ${passed} checks passed`);
}
