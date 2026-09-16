const assert = require("assert");
const {milestoneFor, MILESTONES, MILESTONE_COPY} = require("../follows");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

console.log("fame milestones");

check("below the first milestone crosses nothing", () => {
  assert.strictEqual(milestoneFor(0), 0);
  assert.strictEqual(milestoneFor(9), 0);
});

check("returns the highest milestone crossed", () => {
  assert.strictEqual(milestoneFor(10), 10);
  assert.strictEqual(milestoneFor(49), 10);
  assert.strictEqual(milestoneFor(50), 50);
  assert.strictEqual(milestoneFor(137), 100);
  assert.strictEqual(milestoneFor(500), 500);
  assert.strictEqual(milestoneFor(999), 500);
  assert.strictEqual(milestoneFor(1000), 1000);
  assert.strictEqual(milestoneFor(999999), 1000);
});

check("is monotonic (never decreases as count rises)", () => {
  let prev = 0;
  for (let n = 0; n <= 1200; n++) {
    const m = milestoneFor(n);
    assert.ok(m >= prev, `milestone dropped at ${n}`);
    prev = m;
  }
});

check("every milestone has celebratory copy", () => {
  for (const m of MILESTONES) {
    assert.ok(typeof MILESTONE_COPY[m] === "string" && MILESTONE_COPY[m].length > 0,
        `missing copy for ${m}`);
  }
});

console.log(`\n${passed} passed`);
