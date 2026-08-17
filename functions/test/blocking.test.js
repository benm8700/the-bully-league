const assert = require("assert");
const {applyBlock, MAX_BLOCKED} = require("../blocking");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

console.log("blocking");

check("blocking adds someone to the list", () => {
  const r = applyBlock([], "them", true);
  assert.deepStrictEqual(r.list, ["them"]);
  assert.strictEqual(r.changed, true);
});

check("unblocking removes them", () => {
  const r = applyBlock(["them", "other"], "them", false);
  assert.deepStrictEqual(r.list, ["other"]);
  assert.strictEqual(r.changed, true);
});

check("IDEMPOTENT both ways - a retried tap never errors", () => {
  const already = applyBlock(["them"], "them", true);
  assert.deepStrictEqual(already.list, ["them"]);
  assert.strictEqual(already.changed, false);

  const never = applyBlock(["other"], "them", false);
  assert.deepStrictEqual(never.list, ["other"]);
  assert.strictEqual(never.changed, false);
});

check("an existing list is preserved, not replaced", () => {
  const r = applyBlock(["a", "b"], "c", true);
  assert.deepStrictEqual(r.list, ["a", "b", "c"]);
});

check("a missing or malformed list degrades to empty", () => {
  for (const current of [undefined, null, "nope", 7]) {
    const r = applyBlock(current, "them", true);
    assert.deepStrictEqual(r.list, ["them"], `current=${current}`);
  }
});

check("junk entries are dropped rather than carried forward", () => {
  const r = applyBlock(["a", null, "", 42, "b"], "c", true);
  assert.deepStrictEqual(r.list, ["a", "b", "c"]);
});

check("THE CAP holds, and refuses rather than silently dropping", () => {
  // The list lives on the user document, which is read on every
  // entitlement check and queue entry - an unbounded array would make all
  // of those progressively more expensive.
  const full = Array.from({length: MAX_BLOCKED}, (_, i) => `u${i}`);
  const r = applyBlock(full, "one-more", true);
  assert.strictEqual(r.changed, false);
  assert.strictEqual(r.reason, "limit-reached");
  assert.strictEqual(r.list.length, MAX_BLOCKED);
});

check("UNBLOCKING STILL WORKS AT THE CAP", () => {
  // Otherwise a full list would be a trap: unable to add, and if unblock
  // were also refused, unable to ever recover.
  const full = Array.from({length: MAX_BLOCKED}, (_, i) => `u${i}`);
  const r = applyBlock(full, "u0", false);
  assert.strictEqual(r.changed, true);
  assert.strictEqual(r.list.length, MAX_BLOCKED - 1);
});

check("the cap is high enough that no honest user meets it", () => {
  assert.ok(MAX_BLOCKED >= 100, `${MAX_BLOCKED} is too low to be invisible`);
});

check("blocking does not disturb order, so the list stays stable", () => {
  const r = applyBlock(["a", "b"], "c", true);
  assert.strictEqual(r.list.indexOf("a"), 0);
  assert.strictEqual(r.list.indexOf("b"), 1);
});

console.log(`\n${passed} checks passed.`);
