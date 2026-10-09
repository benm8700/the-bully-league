const assert = require("assert");
const {prizePlan} = require("../prizes");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

console.log("tournament prizes - prizePlan");

check("a points prize with value > 0 is auto-awardable", () => {
  const p = prizePlan({prizeType: "points", prizeValue: 500});
  assert.deepStrictEqual(p, {kind: "points", points: 500});
});

check("a points prize of 0 (the daily default) is no prize", () => {
  assert.strictEqual(prizePlan({prizeType: "points", prizeValue: 0}).kind, "none");
});

check("a non-cash item is identified by its description", () => {
  const p = prizePlan({prizeType: "item", prizeDescription: "PS5"});
  assert.deepStrictEqual(p, {kind: "item", description: "PS5"});
});

check("a bare description with no explicit type is still an item", () => {
  const p = prizePlan({prizeDescription: "Comedy Store tickets"});
  assert.strictEqual(p.kind, "item");
  assert.strictEqual(p.description, "Comedy Store tickets");
});

check("prizeLabel works as an alias for the description", () => {
  assert.strictEqual(prizePlan({prizeLabel: "Flight to LA"}).description, "Flight to LA");
});

check("cash is recognised but kept separate (never auto-paid)", () => {
  const p = prizePlan({prizeType: "cash", prizeValue: 2000});
  assert.strictEqual(p.kind, "cash");
  assert.strictEqual(p.description, "$2000");
});

check("no prize fields -> none", () => {
  assert.strictEqual(prizePlan({}).kind, "none");
  assert.strictEqual(prizePlan(null).kind, "none");
  assert.strictEqual(prizePlan({prizeType: "item", prizeDescription: "  "}).kind, "none");
});

console.log(`\n${passed} passed`);
