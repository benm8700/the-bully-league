const assert = require("assert");
const {resolveApplyFee} = require("../hubJudges");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

console.log("judgeApply fee");

check("off unless BOTH the tournament and the fee flag are on", () => {
  assert.strictEqual(resolveApplyFee(null).enabled, false);
  assert.strictEqual(resolveApplyFee({enabled: true}).enabled, false);
  assert.strictEqual(
      resolveApplyFee({judgeApplyFeeEnabled: true}).enabled, false);
  assert.strictEqual(
      resolveApplyFee({enabled: true, judgeApplyFeeEnabled: true}).enabled,
      true);
});

check("fee falls back to the default when missing or out of bounds", () => {
  assert.strictEqual(resolveApplyFee({}).fee, 50);
  assert.strictEqual(resolveApplyFee({judgeApplyFee: 0}).fee, 50); // below min
  assert.strictEqual(resolveApplyFee({judgeApplyFee: -5}).fee, 50);
  assert.strictEqual(resolveApplyFee({judgeApplyFee: "x"}).fee, 50);
  assert.strictEqual(resolveApplyFee({judgeApplyFee: 2_000_000}).fee, 50);
});

check("a valid fee is kept", () => {
  assert.strictEqual(resolveApplyFee({judgeApplyFee: 75}).fee, 75);
});

console.log(`\n${passed} checks passed`);
