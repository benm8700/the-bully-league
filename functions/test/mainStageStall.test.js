const assert = require("assert");
const {stalledJudgingVerdict} = require("../mainStagePlay");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

console.log("main stage - stalled judging verdict (force a winner, never a draw)");

check("plurality winner", () => {
  assert.strictEqual(
      stalledJudgingVerdict({a: "p1", b: "p1", c: "p2"}, "p1", "p2"), "p1");
  assert.strictEqual(
      stalledJudgingVerdict({a: "p2", b: "p2", c: "p1"}, "p1", "p2"), "p2");
});

check("a tie goes to the higher seed (player1)", () => {
  assert.strictEqual(stalledJudgingVerdict({a: "p1", b: "p2"}, "p1", "p2"), "p1");
});

check("an empty / absent panel goes to the higher seed (player1)", () => {
  assert.strictEqual(stalledJudgingVerdict({}, "p1", "p2"), "p1");
  assert.strictEqual(stalledJudgingVerdict(null, "p1", "p2"), "p1");
});

check("stray votes for neither battler are ignored", () => {
  assert.strictEqual(
      stalledJudgingVerdict({a: "ghost", b: "p2"}, "p1", "p2"), "p2");
});

console.log(`\n${passed} passed`);
