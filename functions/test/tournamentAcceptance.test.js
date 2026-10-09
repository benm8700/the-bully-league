const assert = require("assert");
const {resolveFinalists} = require("../tournamentAcceptance");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

const FINALISTS = ["f1", "f2", "f3", "f4"]; // seed order
const ALTS = ["a1", "a2", "a3", "a4"]; // alternate rank order

console.log("main stage acceptance / alternates");

check("all four finalists confirm -> exactly them, in seed order", () => {
  const r = resolveFinalists({
    finalists: FINALISTS, alternates: ALTS,
    confirmed: ["f1", "f2", "f3", "f4"],
  });
  assert.deepStrictEqual(r.field, ["f1", "f2", "f3", "f4"]);
  assert.strictEqual(r.full, true);
  assert.strictEqual(r.needed, 0);
});

check("a declining finalist is replaced by the top confirmed alternate", () => {
  const r = resolveFinalists({
    finalists: FINALISTS, alternates: ALTS,
    confirmed: ["f1", "f3", "f4", "a1"], // f2 didn't confirm
  });
  assert.deepStrictEqual(r.field, ["f1", "f3", "f4", "a1"]);
  assert.strictEqual(r.full, true);
});

check("multiple no-shows pull multiple alternates, in rank order", () => {
  const r = resolveFinalists({
    finalists: FINALISTS, alternates: ALTS,
    confirmed: ["f1", "f4", "a1", "a2"], // f2, f3 out
  });
  assert.deepStrictEqual(r.field, ["f1", "f4", "a1", "a2"]);
});

check("an alternate who didn't confirm is skipped for the next one", () => {
  const r = resolveFinalists({
    finalists: FINALISTS, alternates: ALTS,
    confirmed: ["f1", "f2", "f3", "a2"], // f4 out, a1 didn't confirm, a2 did
  });
  assert.deepStrictEqual(r.field, ["f1", "f2", "f3", "a2"]);
});

check("highest-ranked confirmed is field[0] (the #1 who gets the callout)",
    () => {
      const r = resolveFinalists({
        finalists: FINALISTS, alternates: ALTS,
        confirmed: ["f2", "f3", "f4", "a1"], // f1 (the top seed) dropped
      });
      assert.strictEqual(r.field[0], "f2", "the next-highest seed becomes #1");
    });

check("not enough confirmations -> short field + needed count", () => {
  const r = resolveFinalists({
    finalists: FINALISTS, alternates: ALTS,
    confirmed: ["f1", "a1"], // only two total confirmed anywhere
  });
  assert.deepStrictEqual(r.field, ["f1", "a1"]);
  assert.strictEqual(r.full, false);
  assert.strictEqual(r.needed, 2);
});

check("confirmations that aren't finalists or alternates are ignored", () => {
  const r = resolveFinalists({
    finalists: FINALISTS, alternates: ALTS,
    confirmed: ["f1", "f2", "f3", "f4", "randomStranger"],
  });
  assert.deepStrictEqual(r.field, ["f1", "f2", "f3", "f4"]);
});

check("accepts a Set for confirmed", () => {
  const r = resolveFinalists({
    finalists: FINALISTS, alternates: ALTS,
    confirmed: new Set(["f1", "f2", "f3", "f4"]),
  });
  assert.strictEqual(r.full, true);
});

console.log(`\n${passed} passed`);
