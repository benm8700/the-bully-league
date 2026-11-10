const assert = require("assert");
const {isVotableBy} = require("../voteQueue");
const {selectForCaptioning} = require("../autoRender");
const {RECORDED_MODES} = require("../matchmaking");
let passed = 0;
function test(name, fn) { fn(); passed++; }

const now = Date.now();
const friend = {mode: "friend", status: "completed", voteFinalized: false,
  player1Id: "a", player2Id: "b", completedAtMs: now - 60000};

test("friend battles are recorded again (2026-11-09)", () => {
  assert.ok(RECORDED_MODES.includes("friend"));
});
test("a stranger can judge a friend battle; the two friends can't", () => {
  assert.strictEqual(isVotableBy(friend, "judge", now), true);
  assert.strictEqual(isVotableBy(friend, "a", now), false);
});
test("friend battles are never paid-captioned", () => {
  const c = (mode) => ({mode, voteFinalized: true, finalizedAtMs: now - 1000,
    voteCount: 9, player1FinalWeight: 5, player2FinalWeight: 4});
  const picked = selectForCaptioning([c("friend"), c("ranked")], {now});
  assert.deepStrictEqual(picked.map((p) => p.mode), ["ranked"]);
});
console.log(`friendJudging: ${passed} checks passed`);
