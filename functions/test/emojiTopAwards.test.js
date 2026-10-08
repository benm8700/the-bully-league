/**
 * Pure tests for the emoji top-award logic (functions/emojiTopAwards.js).
 * Run: node test/emojiTopAwards.test.js
 */
const assert = require("assert");
const {needsAward, EMOJI_AWARD_KEYS} = require("../emojiTopAwards");

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

test("the four emoji keys are present and in order", () => {
  assert.deepStrictEqual(EMOJI_AWARD_KEYS,
      ["fire", "clever", "boring", "trash", "red_flag"]);
});

test("a never-awarded account needs the award", () => {
  assert.strictEqual(needsAward(undefined, "fire"), true);
  assert.strictEqual(needsAward(null, "fire"), true);
  assert.strictEqual(needsAward({}, "fire"), true);
});

test("an account holding a DIFFERENT award still needs this one", () => {
  assert.strictEqual(needsAward({clever: true}, "fire"), true);
});

test("an account already holding the award does NOT need it (idempotent)", () => {
  assert.strictEqual(needsAward({fire: true}, "fire"), false);
});

test("a falsey/garbage flag value counts as not-yet-awarded", () => {
  assert.strictEqual(needsAward({fire: false}, "fire"), true);
  assert.strictEqual(needsAward({fire: 1}, "fire"), true); // only literal true holds
});

if (process.exitCode) {
  console.error("\nemojiTopAwards: some checks FAILED");
} else {
  console.log(`emojiTopAwards: ${passed} checks passed`);
}
