const assert = require("assert");
const {tallyJudgeVotes, stalledBattleVerdict, DEFAULT_JUDGE_WINDOW_MS} =
    require("../mainStageJudging");

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

check("forceClose at the deadline decides on votes cast", () => {
  // only 3 of 5 voted (two no-shows not backfilled) -> close on 2-1 for A.
  const r = tallyJudgeVotes({head: "A", j1: "A", j2: "B"}, PANEL,
      {headJudge: "head", forceClose: true});
  assert.strictEqual(r.winner, "A");
  assert.strictEqual(r.decided, true);
});

check("forceClose with zero votes = decided, no winner (crowd fallback)", () => {
  const r = tallyJudgeVotes({}, PANEL, {headJudge: "head", forceClose: true});
  assert.strictEqual(r.winner, null);
  assert.strictEqual(r.decided, true);
  assert.strictEqual(r.cast, 0);
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

// --- stalled-panel force-close (the bracket must never halt) --------------

console.log("\nmain stage - stalled-panel force-close");

const START = 1_000_000_000_000;
const WIN = DEFAULT_JUDGE_WINDOW_MS;
const battle = (over = {}) => ({
  createdAt: START, judgeWindowMs: WIN, player1Id: "A", player2Id: "B", ...over,
});
const FIELD = ["A", "B", "C", "D"]; // A is the #1 seed

check("not stalled before the deadline", () => {
  const r = stalledBattleVerdict({match: battle(), votes: {head: "A"},
    panel: PANEL, headJudge: "head", field: FIELD, now: START + WIN - 1});
  assert.strictEqual(r.stalled, false);
});

check("an already-decided battle is never force-closed", () => {
  const r = stalledBattleVerdict({match: battle({judgeWinnerId: "A"}),
    votes: {}, panel: PANEL, headJudge: "head", field: FIELD,
    now: START + WIN + 999999});
  assert.strictEqual(r.stalled, false);
});

check("a missing start time never force-closes (missing-field safety)", () => {
  const r = stalledBattleVerdict({match: battle({createdAt: null}),
    votes: {}, panel: PANEL, headJudge: "head", field: FIELD,
    now: START + WIN + 999999});
  assert.strictEqual(r.stalled, false);
});

check("past the deadline, a plurality decides it even with seats out", () => {
  const r = stalledBattleVerdict({match: battle(),
    votes: {head: "A", j1: "A", j2: "B"}, panel: PANEL, headJudge: "head",
    field: FIELD, now: START + WIN});
  assert.strictEqual(r.stalled, true);
  assert.strictEqual(r.winner, "A");
});

check("a bare tie at the deadline is broken by the head judge", () => {
  const r = stalledBattleVerdict({match: battle(),
    votes: {head: "B", j1: "A"}, panel: PANEL, headJudge: "head",
    field: FIELD, now: START + WIN});
  assert.strictEqual(r.winner, "B"); // head judge sat with B
});

check("a dead tie with no head-judge vote: the HIGHER SEED advances", () => {
  const r = stalledBattleVerdict({match: battle(),
    votes: {j1: "A", j2: "B"}, panel: PANEL, headJudge: "head",
    field: FIELD, now: START + WIN});
  assert.strictEqual(r.stalled, true);
  assert.strictEqual(r.winner, "A"); // A seeded ahead of B
});

check("ZERO votes at the deadline still yields the higher seed, not null", () => {
  // The battle's host may have vanished before anyone judged - the bracket
  // still has to advance exactly one player.
  const r = stalledBattleVerdict({match: battle({player1Id: "B", player2Id: "A"}),
    votes: {}, panel: PANEL, headJudge: "head", field: FIELD, now: START + WIN});
  assert.strictEqual(r.stalled, true);
  assert.strictEqual(r.winner, "A"); // A outranks B whichever slot it's in
});

check("the stamped judgeWindowMs overrides the default", () => {
  const short = stalledBattleVerdict({match: battle({judgeWindowMs: 1000}),
    votes: {}, panel: PANEL, headJudge: "head", field: FIELD,
    now: START + 1000});
  assert.strictEqual(short.stalled, true); // past the short stamped window
});

console.log(`\n${passed} passed`);
