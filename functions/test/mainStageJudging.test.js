const assert = require("assert");
const {tallyJudgeVotes} = require("../mainStageJudging");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

const PANEL = ["head", "j1", "j2", "j3", "j4"]; // 5 seats, head = founder

console.log("main stage judging - open-vote verdict");

check("a clear majority once all have voted decides it", () => {
  const r = tallyJudgeVotes(
      {head: "A", j1: "A", j2: "A", j3: "B", j4: "B"}, PANEL,
      {headJudge: "head"});
  assert.strictEqual(r.winner, "A");
  assert.strictEqual(r.decided, true);
  assert.strictEqual(r.remaining, 0);
});

check("not decided while seats are still out and it could flip", () => {
  const r = tallyJudgeVotes({head: "A", j1: "B"}, PANEL, {headJudge: "head"});
  assert.strictEqual(r.decided, false); // 1-1, 3 seats out
  assert.strictEqual(r.winner, null);
  assert.strictEqual(r.remaining, 3);
});

check("decides EARLY when the lead is bigger than the seats still out", () => {
  // A has 3, B has 0, 2 seats out -> B can reach at most 2, can't catch A.
  const r = tallyJudgeVotes({head: "A", j1: "A", j2: "A"}, PANEL,
      {headJudge: "head"});
  assert.strictEqual(r.winner, "A");
  assert.strictEqual(r.decided, true);
  assert.strictEqual(r.remaining, 2);
});

check("the head judge breaks a tie", () => {
  // 2-2 with head among the tied leaders; head voted A -> A wins.
  const r = tallyJudgeVotes(
      {head: "A", j1: "A", j2: "B", j3: "B"}, ["head", "j1", "j2", "j3"],
      {headJudge: "head"});
  assert.strictEqual(r.winner, "A");
  assert.strictEqual(r.tie, false);
  assert.strictEqual(r.decided, true);
});

check("a bare tie with no head-judge vote resolves to no winner on close", () => {
  // even panel, 2-2, head didn't vote -> tie stands -> null winner, decided.
  const r = tallyJudgeVotes(
      {j1: "A", j2: "A", j3: "B", j4: "B"}, ["j1", "j2", "j3", "j4"],
      {headJudge: "head"});
  assert.strictEqual(r.winner, null);
  assert.strictEqual(r.tie, true);
  assert.strictEqual(r.decided, true); // all seats voted
});

check("only SEATED judges' votes count", () => {
  // an outsider / un-seated voter is ignored.
  const r = tallyJudgeVotes(
      {head: "A", j1: "A", stranger: "B", standbyNotSeated: "B"},
      PANEL, {headJudge: "head"});
  assert.strictEqual(r.counts["A"], 2);
  assert.strictEqual(r.counts["B"] ?? 0, 0);
  assert.strictEqual(r.cast, 2);
});

check("not decided while votes are still out (no deadline forces it)", () => {
  // Only 3 of 5 voted, 2-1 for A: A leads but B could still reach 2 with the
  // two seats out and force the head-judge tiebreak, so it is NOT yet decided -
  // and nothing closes it on a clock.
  const r = tallyJudgeVotes({head: "A", j1: "A", j2: "B"}, PANEL,
      {headJudge: "head"});
  assert.strictEqual(r.decided, false);
  assert.strictEqual(r.remaining, 2);
});

check("a promoted standby counts once folded into the panel", () => {
  // j5 replaces a no-show j4: caller passes the updated panel.
  const panel = ["head", "j1", "j2", "j3", "j5"];
  const r = tallyJudgeVotes(
      {head: "A", j1: "A", j2: "A", j3: "B", j5: "B"}, panel,
      {headJudge: "head"});
  assert.strictEqual(r.winner, "A");
  assert.strictEqual(r.counts["B"], 2); // j5's vote counted
  assert.strictEqual(r.decided, true);
});

console.log(`\n${passed} passed`);
