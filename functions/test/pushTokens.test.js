/**
 * Pure tests for push-token de-duplication (functions/notifications.js).
 * Run: node test/pushTokens.test.js
 */
const assert = require("assert");
const {dedupeTargets, addedTokens} = require("../notifications");

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

test("one phone on three accounts is pushed ONCE (the Happy Hour triple)", () => {
  const out = dedupeTargets([
    {uid: "slamrod", tokens: ["iphone"]},
    {uid: "hshshs", tokens: ["iphone"]},
    {uid: "appreviewer", tokens: ["iphone"]},
  ]);
  assert.deepStrictEqual(out, [{token: "iphone", uid: "slamrod"}]);
});

test("different devices are all kept", () => {
  const out = dedupeTargets([
    {uid: "a", tokens: ["phone", "tablet"]},
    {uid: "b", tokens: ["moto"]},
  ]);
  assert.strictEqual(out.length, 3);
});

test("a token repeated inside one account is sent once", () => {
  assert.strictEqual(dedupeTargets([{uid: "a", tokens: ["t", "t"]}]).length, 1);
});

test("junk tokens and missing arrays are skipped, not thrown on", () => {
  const out = dedupeTargets([
    {uid: "a", tokens: ["", null, 5, "ok"]},
    {uid: "b", tokens: undefined},
  ]);
  assert.deepStrictEqual(out, [{token: "ok", uid: "a"}]);
});

test("addedTokens finds only newly registered tokens", () => {
  assert.deepStrictEqual(addedTokens(["old"], ["old", "new"]), ["new"]);
});

test("addedTokens: removing a token (sign-out) claims nothing", () => {
  assert.deepStrictEqual(addedTokens(["a", "b"], ["a"]), []);
});

test("addedTokens: a brand-new doc claims all of its tokens", () => {
  assert.deepStrictEqual(addedTokens(undefined, ["x"]), ["x"]);
});

test("addedTokens: an unrelated write (points etc.) claims nothing", () => {
  assert.deepStrictEqual(addedTokens(["a"], ["a"]), []);
});

console.log(`\n${passed} checks passed.`);
