const assert = require("assert");
const {
  rankVolunteers,
  qualifiedPool,
  resolveJudgeMinToQualify,
} = require("../hubJudges");

let n = 0;
function check(label, fn) {
  fn();
  n += 1;
  void label;
}

const standings = [
  {uid: "a", judged: 20},
  {uid: "b", judged: 12},
  {uid: "c", judged: 3},
  {uid: "d", judged: 0}, // in standings but judged 0 (shouldn't happen, tolerated)
];

check("ranks volunteers by judged desc", () => {
  const r = rankVolunteers(["c", "a", "b"], standings, 10);
  assert.deepStrictEqual(r.map((x) => x.uid), ["a", "b", "c"]);
  assert.strictEqual(r[0].judged, 20);
});

check("marks qualified at/above the bar", () => {
  const r = rankVolunteers(["a", "b", "c"], standings, 10);
  const q = Object.fromEntries(r.map((x) => [x.uid, x.qualified]));
  assert.strictEqual(q.a, true); // 20 >= 10
  assert.strictEqual(q.b, true); // 12 >= 10
  assert.strictEqual(q.c, false); // 3 < 10
});

check("a volunteer with no ballots appears, judged 0, unqualified", () => {
  const r = rankVolunteers(["z", "a"], standings, 10);
  const z = r.find((x) => x.uid === "z");
  assert.strictEqual(z.judged, 0);
  assert.strictEqual(z.qualified, false);
  // and sorts last (0 judged)
  assert.strictEqual(r[r.length - 1].uid, "z");
});

check("dedups and ignores non-string uids", () => {
  const r = rankVolunteers(["a", "a", null, 5, "b"], standings, 10);
  assert.deepStrictEqual(r.map((x) => x.uid), ["a", "b"]);
});

check("tie on judged breaks by uid asc", () => {
  const tied = [{uid: "y", judged: 5}, {uid: "x", judged: 5}];
  const r = rankVolunteers(["y", "x"], tied, 1);
  assert.deepStrictEqual(r.map((x) => x.uid), ["x", "y"]);
});

check("qualifiedPool returns only qualified, excludes finalists, ranked", () => {
  const pool = qualifiedPool(["a", "b", "c"], standings, 10, ["a"]);
  // a excluded (finalist), c unqualified -> only b
  assert.deepStrictEqual(pool, ["b"]);
});

check("qualifiedPool empty when nobody qualifies", () => {
  assert.deepStrictEqual(qualifiedPool(["c"], standings, 10, []), []);
  assert.deepStrictEqual(qualifiedPool([], standings, 10, []), []);
});

check("resolveJudgeMinToQualify defaults to 10, honours valid config", () => {
  assert.strictEqual(resolveJudgeMinToQualify(undefined), 10);
  assert.strictEqual(resolveJudgeMinToQualify({}), 10);
  assert.strictEqual(resolveJudgeMinToQualify({judgeMinToQualify: 0}), 0);
  assert.strictEqual(resolveJudgeMinToQualify({judgeMinToQualify: 25}), 25);
  assert.strictEqual(resolveJudgeMinToQualify({judgeMinToQualify: 7.9}), 7);
  // out of bounds / garbage -> default
  assert.strictEqual(resolveJudgeMinToQualify({judgeMinToQualify: -1}), 10);
  assert.strictEqual(resolveJudgeMinToQualify({judgeMinToQualify: 9999}), 10);
  assert.strictEqual(resolveJudgeMinToQualify({judgeMinToQualify: "x"}), 10);
});

console.log(`hubJudges: ${n} checks passed`);
