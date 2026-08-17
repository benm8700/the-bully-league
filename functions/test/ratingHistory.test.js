const assert = require("assert");
const {summarise, FORM_WINDOW} = require("../ratingHistory");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

// Newest first, which is the order the query returns.
const e = (delta, won, ratingAfter = 1200) =>
  ({delta, won, ratingAfter, ratingBefore: ratingAfter - delta});

console.log("ratingHistory");

check("an empty history summarises to nothing rather than throwing", () => {
  const s = summarise([]);
  assert.strictEqual(s.matches, 0);
  assert.strictEqual(s.form, null);
  assert.strictEqual(s.streak, null);
});

check("garbage in gives a valid summary, not a crash", () => {
  for (const bad of [null, undefined, "history"]) {
    assert.strictEqual(summarise(bad).matches, 0);
  }
});

check("net change over the window decides the form", () => {
  assert.strictEqual(summarise([e(14, true), e(12, true)]).form, "climbing");
  assert.strictEqual(summarise([e(-14, false), e(-8, false)]).form, "sliding");
  assert.strictEqual(summarise([e(10, true), e(-10, false)]).form, "level");
});

check("the form window is bounded, so old history cannot dominate", () => {
  // One recent bad run must still register even after a long good one.
  const entries = [
    ...Array.from({length: FORM_WINDOW}, () => e(-10, false)),
    ...Array.from({length: 50}, () => e(20, true)),
  ];
  const s = summarise(entries);
  assert.strictEqual(s.form, "sliding");
  assert.strictEqual(s.windowMatches, FORM_WINDOW);
  // ...while the total count still reflects everything.
  assert.strictEqual(s.matches, FORM_WINDOW + 50);
});

check("a streak counts the CURRENT run and stops when it breaks", () => {
  const s = summarise([e(12, true), e(11, true), e(-9, false), e(13, true)]);
  assert.deepStrictEqual(s.streak, {type: "win", count: 2});
});

check("a losing streak is reported as such", () => {
  const s = summarise([e(-9, false), e(-8, false), e(12, true)]);
  assert.deepStrictEqual(s.streak, {type: "loss", count: 2});
});

check("A DRAW BREAKS A STREAK rather than extending one", () => {
  // Neither player won a tie, so counting it inside a winning run would
  // be a straightforward lie about what happened.
  const s = summarise([e(12, true), {delta: 0, won: null}, e(11, true)]);
  assert.deepStrictEqual(s.streak, {type: "win", count: 1});
});

check("a history that opens with a draw has no streak at all", () => {
  const s = summarise([{delta: 0, won: null}, e(12, true)]);
  assert.strictEqual(s.streak, null);
});

check("peak rating is the highest ever reached, not the latest", () => {
  const s = summarise([
    e(-20, false, 1180),
    e(30, true, 1200),
    e(10, true, 1170),
  ]);
  assert.strictEqual(s.peakRating, 1200);
});

check("net change sums the real deltas, including a missing one", () => {
  const s = summarise([e(14, true), {won: false}, e(-6, false)]);
  assert.strictEqual(s.netChange, 8);
});

console.log(`\n${passed} checks passed.`);
