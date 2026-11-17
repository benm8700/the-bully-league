/**
 * One account searching on two devices (2026-11-15): the newest device owns
 * the search. Plain `node test/searchDevice.test.js`.
 */
const assert = require("node:assert/strict");
const {sameSearchDevice} = require("../matchmaking");

let n = 0;
function check(name, fn) {
  fn();
  n++;
  console.log(`ok - ${name}`);
}

check("same device owns its search", () => {
  assert.equal(sameSearchDevice({deviceId: "A"}, "A"), true);
});
check("another device does not", () => {
  assert.equal(sameSearchDevice({deviceId: "B"}, "A"), false);
});
check("an older build (no id sent) is never locked out", () => {
  assert.equal(sameSearchDevice({deviceId: "B"}, undefined), true);
  assert.equal(sameSearchDevice({deviceId: "B"}, ""), true);
});
check("an entry from an older build (no owner) matches anyone", () => {
  assert.equal(sameSearchDevice({}, "A"), true);
  assert.equal(sameSearchDevice({deviceId: null}, "A"), true);
});
check("no entry at all is not a conflict", () => {
  assert.equal(sameSearchDevice(null, "A"), true);
});
console.log(`${n} checks passed`);
