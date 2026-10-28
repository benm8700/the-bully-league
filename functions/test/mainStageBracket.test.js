const assert = require("assert");
const {
  createBracket,
  applyResult,
  nextMatches,
  isComplete,
  stampOpened,
  forfeitWinner,
  stuckMatchupOutcome,
} = require("../mainStageBracket");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

const SEEDS = ["s1", "s2", "s3", "s4"]; // seed order, s1 = #1

console.log("main stage bracket - 4-finalist #1-callout single-elim");

check("the callout pairs #1 vs their pick; the other two auto-pair", () => {
  const b = createBracket(SEEDS, "s3"); // #1 calls out s3
  assert.deepStrictEqual(
      [b.rounds[0][0].a, b.rounds[0][0].b], ["s1", "s3"]);
  assert.deepStrictEqual(
      [b.rounds[0][1].a, b.rounds[0][1].b].sort(), ["s2", "s4"]);
  assert.strictEqual(b.status, "semis");
  assert.strictEqual(b.champion, null);
});

check("#1 cannot call out themselves", () => {
  assert.throws(() => createBracket(SEEDS, "s1"));
});

check("#1 can only call out another finalist", () => {
  assert.throws(() => createBracket(SEEDS, "nobody"));
});

check("needs exactly 4 distinct finalists", () => {
  assert.throws(() => createBracket(["s1", "s2", "s3"], "s2"));
  assert.throws(() => createBracket(["s1", "s2", "s3", "s2"], "s2"));
});

check("only the two semis are ready to play at the start", () => {
  const b = createBracket(SEEDS, "s3");
  const ready = nextMatches(b);
  assert.strictEqual(ready.length, 2);
  assert.ok(ready.every((m) => m.roundIdx === 0));
});

check("the final cannot be decided before both semis", () => {
  let b = createBracket(SEEDS, "s3");
  b = applyResult(b, 1, 0, "s1"); // try to settle the final early
  assert.strictEqual(b.champion, null, "final ignored - players unknown");
  assert.strictEqual(b.status, "semis");
});

check("settling both semis fills the final and flips to 'final'", () => {
  let b = createBracket(SEEDS, "s3");
  b = applyResult(b, 0, 0, "s1"); // s1 beats s3
  assert.strictEqual(b.status, "semis", "still one semi to go");
  b = applyResult(b, 0, 1, "s2"); // s2 beats s4
  assert.strictEqual(b.status, "final");
  assert.deepStrictEqual(
      [b.rounds[1][0].a, b.rounds[1][0].b], ["s1", "s2"]);
  const ready = nextMatches(b);
  assert.strictEqual(ready.length, 1);
  assert.strictEqual(ready[0].roundIdx, 1);
});

check("the final crowns the champion and completes the bracket", () => {
  let b = createBracket(SEEDS, "s3");
  b = applyResult(b, 0, 0, "s1");
  b = applyResult(b, 0, 1, "s2");
  b = applyResult(b, 1, 0, "s2"); // s2 wins the final
  assert.strictEqual(b.champion, "s2");
  assert.strictEqual(b.status, "done");
  assert.ok(isComplete(b));
  assert.strictEqual(nextMatches(b).length, 0);
});

check("the winner must be one of that matchup's players", () => {
  const b0 = createBracket(SEEDS, "s3");
  const b1 = applyResult(b0, 0, 0, "s2"); // s2 isn't in the s1-vs-s3 semi
  assert.strictEqual(b1.rounds[0][0].winner, null, "bogus winner ignored");
});

check("re-applying is idempotent; a different winner is rejected", () => {
  let b = createBracket(SEEDS, "s3");
  b = applyResult(b, 0, 0, "s1");
  const same = applyResult(b, 0, 0, "s1");
  assert.strictEqual(same.rounds[0][0].winner, "s1");
  const flip = applyResult(b, 0, 0, "s3"); // try to overturn
  assert.strictEqual(flip.rounds[0][0].winner, "s1", "can't overturn");
});

check("applyResult never mutates its input", () => {
  const b = createBracket(SEEDS, "s3");
  const snapshot = JSON.stringify(b);
  applyResult(b, 0, 0, "s1");
  assert.strictEqual(JSON.stringify(b), snapshot);
});

// ---- no-show backstop: stampOpened / forfeitWinner / stuckMatchupOutcome ----

check("stampOpened stamps ready matchups, leaves the unfilled final alone", () => {
  const b = stampOpened(createBracket(SEEDS, "s3"), 1000);
  assert.strictEqual(b.rounds[0][0].openedMs, 1000);
  assert.strictEqual(b.rounds[0][1].openedMs, 1000);
  // the final isn't ready (a/b null) so it gets no clock yet
  assert.strictEqual(b.rounds[1][0].openedMs, undefined);
});

check("stampOpened never re-stamps an already-opened matchup", () => {
  let b = stampOpened(createBracket(SEEDS, "s3"), 1000);
  b = stampOpened(b, 5000);
  assert.strictEqual(b.rounds[0][0].openedMs, 1000, "keeps the first stamp");
});

check("stampOpened clocks the final once the semis fill it", () => {
  let b = stampOpened(createBracket(SEEDS, "s3"), 1000);
  b = applyResult(b, 0, 0, "s1");
  b = applyResult(b, 0, 1, "s2"); // final now ready
  b = stampOpened(b, 9000);
  assert.strictEqual(b.rounds[1][0].openedMs, 9000);
  assert.strictEqual(b.rounds[0][0].openedMs, 1000, "semis keep their stamp");
});

check("stampOpened does not mutate its input", () => {
  const b = createBracket(SEEDS, "s3");
  const snap = JSON.stringify(b);
  stampOpened(b, 1000);
  assert.strictEqual(JSON.stringify(b), snap);
});

check("forfeitWinner: whoever showed beats the no-show", () => {
  const m = {a: "s1", b: "s3"};
  assert.strictEqual(forfeitWinner(m, "s3"), "s3", "the one who started wins");
  assert.strictEqual(forfeitWinner(m, "s1"), "s1");
});

check("forfeitWinner: nobody / unknown -> higher seed (the a slot)", () => {
  const m = {a: "s1", b: "s3"};
  assert.strictEqual(forfeitWinner(m, null), "s1");
  assert.strictEqual(forfeitWinner(m, "someone-else"), "s1");
});

const MIN = 60 * 1000;

check("stuck: a never-started matchup force-advances past its no-show window", () => {
  const m = {a: "s1", b: "s3", winner: null, openedMs: 1 * MIN};
  assert.strictEqual(stuckMatchupOutcome(m, null, 10 * MIN, 20 * MIN), null,
      "not stuck yet");
  const out = stuckMatchupOutcome(m, null, 22 * MIN, 20 * MIN);
  assert.strictEqual(out.winner, "s1", "higher seed advances on a double no-show");
});

check("stuck: a matchup with no openedMs is never force-advanced", () => {
  const m = {a: "s1", b: "s3", winner: null};
  assert.strictEqual(stuckMatchupOutcome(m, null, 999 * MIN, 20 * MIN), null);
});

check("stuck: an abandoned started battle advances whoever showed", () => {
  const m = {a: "s1", b: "s3", winner: null, openedMs: 1 * MIN, matchId: "x"};
  const info = {status: "pending", startedBy: "s3", createdMs: 1 * MIN};
  assert.strictEqual(stuckMatchupOutcome(m, info, 10 * MIN, 20 * MIN), null,
      "not stuck yet");
  const out = stuckMatchupOutcome(m, info, 22 * MIN, 20 * MIN);
  assert.strictEqual(out.winner, "s3", "the player who started advances");
});

check("stuck: a FINISHED (completed/decided) battle is left to the judging sweep", () => {
  const m = {a: "s1", b: "s3", winner: null, openedMs: 1 * MIN, matchId: "x"};
  assert.strictEqual(
      stuckMatchupOutcome(m, {status: "completed", createdMs: 1 * MIN},
          999 * MIN, 20 * MIN),
      null, "completed -> judging owns it");
  assert.strictEqual(
      stuckMatchupOutcome(m,
          {status: "in_progress", judgeWinnerId: "s1", createdMs: 1 * MIN},
          999 * MIN, 20 * MIN),
      null, "a verdict already landed -> leave it");
});

check("stuck: a settled matchup is never touched", () => {
  const m = {a: "s1", b: "s3", winner: "s1", openedMs: 1 * MIN};
  assert.strictEqual(stuckMatchupOutcome(m, null, 999 * MIN, 20 * MIN), null);
});

console.log(`\n${passed} passed`);
