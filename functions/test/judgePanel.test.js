const assert = require("assert");
const {selectPanel} = require("../judgePanel");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

console.log("judge panel selection");

check("hand-picks fill first (in order), then the pool autofills to 5", () => {
  const {judges, shortfall} = selectPanel({
    handPicked: ["founder", "celeb"],
    rankedPool: ["j1", "j2", "j3", "j4", "j5"],
  });
  assert.deepStrictEqual(judges, ["founder", "celeb", "j1", "j2", "j3"]);
  assert.strictEqual(shortfall, 0);
});

check("a finalist is NEVER a judge - even if hand-picked", () => {
  const {judges} = selectPanel({
    handPicked: ["founder", "playerX"],
    rankedPool: ["j1", "j2", "j3", "j4"],
    finalists: ["playerX"],
  });
  assert.ok(!judges.includes("playerX"), "competitor excluded from panel");
  assert.deepStrictEqual(judges, ["founder", "j1", "j2", "j3", "j4"]);
});

check("a finalist at the top of the pool is skipped", () => {
  const {judges} = selectPanel({
    handPicked: ["founder"],
    rankedPool: ["finA", "j1", "j2", "j3", "j4"],
    finalists: ["finA"],
  });
  assert.ok(!judges.includes("finA"));
  assert.deepStrictEqual(judges, ["founder", "j1", "j2", "j3", "j4"]);
});

check("excluded (banned/flagged) accounts are never selected", () => {
  const {judges} = selectPanel({
    handPicked: ["founder"],
    rankedPool: ["bad", "j1", "j2", "j3", "j4"],
    exclude: ["bad"],
  });
  assert.ok(!judges.includes("bad"));
  assert.deepStrictEqual(judges, ["founder", "j1", "j2", "j3", "j4"]);
});

check("a judge in both hand-picks and the pool is counted once", () => {
  const {judges} = selectPanel({
    handPicked: ["founder", "j1"],
    rankedPool: ["j1", "j2", "j3", "j4", "j5"],
  });
  assert.deepStrictEqual(judges, ["founder", "j1", "j2", "j3", "j4"]);
  assert.strictEqual(new Set(judges).size, judges.length, "no duplicates");
});

check("shortfall is reported when there aren't enough eligible judges", () => {
  const {judges, shortfall} = selectPanel({
    handPicked: ["founder"],
    rankedPool: ["j1"],
  });
  assert.deepStrictEqual(judges, ["founder", "j1"]);
  assert.strictEqual(shortfall, 3, "caller falls back to crowd voting");
});

check("more hand-picks than seats truncates to the panel size", () => {
  const {judges} = selectPanel({
    handPicked: ["a", "b", "c", "d", "e", "f"],
    rankedPool: ["j1"],
  });
  assert.deepStrictEqual(judges, ["a", "b", "c", "d", "e"]);
});

check("pure autofill when there are no hand-picks", () => {
  const {judges} = selectPanel({
    rankedPool: ["j1", "j2", "j3", "j4", "j5", "j6"],
  });
  assert.deepStrictEqual(judges, ["j1", "j2", "j3", "j4", "j5"]);
});

check("a custom panel size is honoured", () => {
  const {judges, shortfall} = selectPanel({
    handPicked: ["founder"],
    rankedPool: ["j1", "j2"],
    panelSize: 3,
  });
  assert.deepStrictEqual(judges, ["founder", "j1", "j2"]);
  assert.strictEqual(shortfall, 0);
});

check("garbage uids are ignored", () => {
  const {judges} = selectPanel({
    handPicked: ["founder", "", null, undefined],
    rankedPool: ["j1", 42, "j2"],
  });
  assert.deepStrictEqual(judges, ["founder", "j1", "j2"]);
});

console.log(`\n${passed} passed`);
