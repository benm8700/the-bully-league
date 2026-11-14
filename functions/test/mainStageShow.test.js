const assert = require("assert");
const {roundLabel, showFor} = require("../mainStagePlay");

let n = 0;
function test(name, fn) { fn(); n++; }

test("round labels count back from the final", () => {
  assert.strictEqual(roundLabel(1, 2), "FINAL");
  assert.strictEqual(roundLabel(0, 2), "SEMI-FINAL");
  assert.strictEqual(roundLabel(0, 3), "QUARTER-FINAL");
  assert.strictEqual(roundLabel(0, 4), "ROUND 1");
});

test("seeds are 1-based from the bracket's seed order", () => {
  const bracket = {seeds: ["u1", "u2", "u3", "u4"], rounds: [{matches: []}, {matches: []}]};
  assert.deepStrictEqual(showFor(bracket, 0, "u1", "u4"),
      {round: "SEMI-FINAL", seeds: {u1: 1, u4: 4}});
});

test("missing bracket data degrades to nulls, never throws", () => {
  assert.deepStrictEqual(showFor({}, 0, "a", "b"), {round: null, seeds: {a: null, b: null}});
  assert.deepStrictEqual(showFor(undefined, 0, "a", "b"), {round: null, seeds: {a: null, b: null}});
});

console.log(`mainStageShow: ${n} checks passed`);
