const assert = require("assert");
const {shouldAutoStart, AUTO_START_GRACE_MS} =
    require("../mainStageTournament");

let passed = 0;
function check(name, fn) { fn(); passed++; console.log(`  ok - ${name}`); }

const SHOW = 2_000_000_000_000;
const field = ["f1", "f2", "f3", "f4"];
const locked = (over = {}) =>
  ({status: "locked", showAtMs: SHOW, field, ...over});

console.log("mainStage auto-start backstop");

check("fires once 6pm + grace has passed on a locked, full field", () => {
  assert.strictEqual(
      shouldAutoStart(locked(), SHOW + AUTO_START_GRACE_MS + 1), true);
});

check("does NOT fire before the grace is up (the #1 still has their moment)", () => {
  assert.strictEqual(shouldAutoStart(locked(), SHOW + 1000), false);
});

check("does NOT fire before showtime at all", () => {
  assert.strictEqual(shouldAutoStart(locked(), SHOW - 60000), false);
});

check("does NOT fire on a show that is not locked (already live/accepting)", () => {
  const now = SHOW + AUTO_START_GRACE_MS + 1;
  assert.strictEqual(shouldAutoStart(locked({status: "live"}), now), false);
  assert.strictEqual(shouldAutoStart(locked({status: "accepting"}), now), false);
});

check("does NOT fire without a full 4-player field", () => {
  const now = SHOW + AUTO_START_GRACE_MS + 1;
  assert.strictEqual(shouldAutoStart(locked({field: ["a", "b"]}), now), false);
});

check("does NOT fire with no showAtMs (older doc)", () => {
  assert.strictEqual(
      shouldAutoStart(locked({showAtMs: undefined}), Date.now()), false);
});

console.log(`\n${passed} passed`);
