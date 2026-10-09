const assert = require("assert");
const {
  computeStandings,
  computeJudgeStandings,
  topN,
} = require("../weeklyQualifier");
const {assembleMainStage} = require("../mainStageAssembly");
const {applyResult, isComplete} = require("../mainStageBracket");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

const WIN = {startMs: 1000, cutoffMs: 2000};

// 8 players, descending weekly Elo gain, 5 ranked games each (all eligible).
function qualifierEntries() {
  const totals = {p1: 100, p2: 90, p3: 80, p4: 70, p5: 60, p6: 50, p7: 40,
    p8: 30};
  const out = [];
  for (const [uid, total] of Object.entries(totals)) {
    for (let i = 0; i < 5; i++) {
      out.push({uid, delta: total / 5, mode: "ranked", at: 1500});
    }
  }
  return out;
}

// 4 judges with descending ballot counts.
function judgeBallots() {
  const counts = {jX: 4, jY: 3, jZ: 2, jW: 1};
  const out = [];
  for (const [uid, n] of Object.entries(counts)) {
    for (let i = 0; i < n; i++) out.push({uid, at: 1500});
  }
  return out;
}

console.log("main stage assembly - full pipeline (seam test)");

const standings = computeStandings(qualifierEntries(), {...WIN, minGames: 5});
const judgePool = computeJudgeStandings(judgeBallots(), WIN);
const finalists = topN(standings, 4).map((p) => p.uid);
const alternates = standings.slice(4, 8).map((p) => p.uid);

check("the qualifier feeds clean finalists + alternates", () => {
  assert.deepStrictEqual(finalists, ["p1", "p2", "p3", "p4"]);
  assert.deepStrictEqual(alternates, ["p5", "p6", "p7", "p8"]);
  assert.deepStrictEqual(judgePool.map((j) => j.uid), ["jX", "jY", "jZ", "jW"]);
});

// p2 declines; top alternate p5 confirms and is promoted. Founder hand-picks
// himself + p3 (a finalist, who must be rejected as a judge). #1 (p1) calls
// out p4.
const asm = assembleMainStage({
  finalists,
  alternates,
  confirmed: ["p1", "p3", "p4", "p5", "founder", "jX", "jY", "jZ", "jW"],
  handPicked: ["founder", "p3"],
  judgePool,
  pick: "p4",
});

check("a declined finalist is replaced; field re-seeds, #1 is p1", () => {
  assert.deepStrictEqual(asm.field, ["p1", "p3", "p4", "p5"]);
  assert.strictEqual(asm.full, true);
  assert.strictEqual(asm.top, "p1");
});

check("the panel excludes finalists (even a hand-picked one) - the seam", () => {
  assert.deepStrictEqual(asm.judges, ["founder", "jX", "jY", "jZ", "jW"]);
  assert.strictEqual(asm.judgeShortfall, 0);
  // No judge is also a player - the integrity invariant across the two cores.
  const fieldSet = new Set(asm.field);
  assert.ok(asm.judges.every((j) => !fieldSet.has(j)));
});

check("the bracket is the callout, and its players are all in the field", () => {
  assert.ok(asm.bracket, "bracket built once field is full + pick made");
  assert.strictEqual(asm.bracketError, null);
  const [semiA, semiB] = asm.bracket.rounds[0];
  assert.deepStrictEqual([semiA.a, semiA.b], ["p1", "p4"]); // the callout
  assert.deepStrictEqual([semiB.a, semiB.b].sort(), ["p3", "p5"]);
  const fieldSet = new Set(asm.field);
  for (const m of [semiA, semiB]) {
    assert.ok(fieldSet.has(m.a) && fieldSet.has(m.b));
  }
});

check("playing the bracket out produces a valid champion from the field", () => {
  let b = asm.bracket;
  b = applyResult(b, 0, 0, "p1"); // p1 beats p4
  b = applyResult(b, 0, 1, "p3"); // p3 beats p5
  b = applyResult(b, 1, 0, "p1"); // p1 wins the final
  assert.ok(isComplete(b));
  assert.strictEqual(b.champion, "p1");
  assert.ok(asm.field.includes(b.champion));
});

check("no pick yet -> field + panel locked, bracket still pending", () => {
  const pre = assembleMainStage({
    finalists, alternates,
    confirmed: ["p1", "p2", "p3", "p4", "founder", "jX", "jY", "jZ", "jW"],
    handPicked: ["founder"],
    judgePool,
    pick: null, // the callout hasn't happened yet
  });
  assert.strictEqual(pre.full, true);
  assert.strictEqual(pre.judges.length, 5);
  assert.strictEqual(pre.bracket, null, "bracket waits for the live callout");
});

check("an illegal callout is reported, not thrown", () => {
  const bad = assembleMainStage({
    finalists, alternates,
    confirmed: ["p1", "p2", "p3", "p4"],
    handPicked: ["founder"],
    judgePool,
    pick: "p1", // #1 can't call out themselves
  });
  assert.strictEqual(bad.bracket, null);
  assert.ok(bad.bracketError, "the illegal pick surfaces as an error string");
});

console.log(`\n${passed} passed`);
