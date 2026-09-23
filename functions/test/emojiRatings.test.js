/**
 * Pure tests for the per-player emoji ratings (functions/emojiRatings.js).
 * Run: node test/emojiRatings.test.js
 */
const assert = require("assert");
const {
  isRating, countsOf, emptyCounts, nicknameFor, earnedEmojiBadges,
  RATING_KEYS, NICKNAME_MIN_RATINGS,
} = require("../emojiRatings");

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

test("exactly the four ratings are allowed", () => {
  assert.deepStrictEqual(RATING_KEYS, ["fire", "clever", "boring", "trash"]);
  for (const k of RATING_KEYS) assert.ok(isRating(k), `${k} should be valid`);
  for (const k of ["skull", "eggplant", "", null, 3, "FIRE"]) {
    assert.ok(!isRating(k), `${k} should be invalid`);
  }
});

test("countsOf tolerates missing, partial and garbage maps", () => {
  assert.deepStrictEqual(countsOf(null), emptyCounts());
  assert.deepStrictEqual(countsOf({}), emptyCounts());
  assert.deepStrictEqual(
      countsOf({emojiCounts: {fire: 3, clever: "x", boring: -2, junk: 9}}),
      {fire: 3, clever: 0, boring: 0, trash: 0});
});

test("no nickname below the minimum signal", () => {
  assert.strictEqual(nicknameFor({emojiCounts: {fire: NICKNAME_MIN_RATINGS - 1}}), null);
  assert.strictEqual(nicknameFor({}), null);
});

test("a clear fire-dominant player gets a fire nickname", () => {
  const n = nicknameFor({emojiCounts: {fire: 40, clever: 8, boring: 1, trash: 1}});
  assert.strictEqual(typeof n, "string");
  assert.ok(n.length > 0);
});

test("nickname is deterministic for the same counts", () => {
  const u = {emojiCounts: {fire: 20, clever: 30, boring: 2, trash: 1}};
  assert.strictEqual(nicknameFor(u), nicknameFor(u));
});

test("a strongly split player reads as polarizing, not one-note", () => {
  // Half love it (fire), half hate it (trash).
  const n = nicknameFor({emojiCounts: {fire: 25, clever: 2, boring: 3, trash: 25}});
  assert.ok(["Love / Hate", "Hit or Miss"].includes(n), `got ${n}`);
});

test("clever-then-boring is 'too smart for the room'", () => {
  const n = nicknameFor({emojiCounts: {clever: 30, boring: 20, fire: 3, trash: 1}});
  assert.strictEqual(n, "Too Smart for the Room");
});

test("badges are earned for positives only, at their thresholds", () => {
  assert.deepStrictEqual(earnedEmojiBadges({emojiCounts: {fire: 9}}), []);
  assert.deepStrictEqual(earnedEmojiBadges({emojiCounts: {fire: 10}}), ["fire_1"]);
  assert.deepStrictEqual(
      earnedEmojiBadges({emojiCounts: {fire: 150, clever: 55}}),
      ["fire_1", "fire_2", "fire_3", "clever_1", "clever_2"]);
  // Being trash/boring earns nothing, however high.
  assert.deepStrictEqual(earnedEmojiBadges({emojiCounts: {trash: 999, boring: 999}}), []);
});

if (process.exitCode) {
  console.error("\nemojiRatings: some checks FAILED");
} else {
  console.log(`emojiRatings: ${passed} checks passed`);
}
