const assert = require("assert");
const {roundOutcome, matchResultFromRounds, tallyBallots, funniestRound} =
    require("../perRoundVoting");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

console.log("perRoundVoting");

check("a round goes to whoever has more weight", () => {
  assert.strictEqual(roundOutcome(3, 1), 1);
  assert.strictEqual(roundOutcome(1, 3), 2);
  assert.strictEqual(roundOutcome(2, 2), 0);
  assert.strictEqual(roundOutcome(0, 0), 0);
});

check("weighted (sub-24h) votes still decide a round", () => {
  // one full-weight vote for p1 beats one half-weight vote for p2
  assert.strictEqual(roundOutcome(1, 0.5), 1);
});

check("most rounds won takes the match (2-1)", () => {
  const r = matchResultFromRounds(
      [{p1: 3, p2: 1}, {p1: 1, p2: 2}, {p1: 2, p2: 0}], "A", "B");
  assert.strictEqual(r.winnerId, "A");
  assert.strictEqual(r.roundsWonP1, 2);
  assert.strictEqual(r.roundsWonP2, 1);
});

check("a clean sweep works (3-0)", () => {
  const r = matchResultFromRounds(
      [{p1: 2, p2: 0}, {p1: 2, p2: 1}, {p1: 5, p2: 4}], "A", "B");
  assert.strictEqual(r.winnerId, "A");
  assert.strictEqual(r.roundsWonP1, 3);
});

check("equal rounds won is an overall TIE (no winner)", () => {
  // one round each plus a tied round -> nobody won more rounds
  const r = matchResultFromRounds(
      [{p1: 3, p2: 1}, {p1: 1, p2: 3}, {p1: 2, p2: 2}], "A", "B");
  assert.strictEqual(r.winnerId, null);
  assert.strictEqual(r.roundsWonP1, 1);
  assert.strictEqual(r.roundsWonP2, 1);
  assert.strictEqual(r.roundsTied, 1);
});

check("a match where every round ties is an overall tie", () => {
  const r = matchResultFromRounds(
      [{p1: 1, p2: 1}, {p1: 0, p2: 0}], "A", "B");
  assert.strictEqual(r.winnerId, null);
  assert.strictEqual(r.roundsTied, 2);
});

check("no rounds / empty input is a tie, not a crash", () => {
  assert.strictEqual(matchResultFromRounds([], "A", "B").winnerId, null);
  assert.strictEqual(matchResultFromRounds(null, "A", "B").winnerId, null);
});

check("tallyBallots sums weighted per-round picks", () => {
  const ballots = [
    {weight: 1, picks: {0: "A", 1: "A", 2: "B"}},
    {weight: 1, picks: {0: "A", 1: "B", 2: "B"}},
    {weight: 0.5, picks: {0: "B", 1: "B", 2: "B"}},
  ];
  const t = tallyBallots(ballots, "A", "B", 3);
  assert.strictEqual(t.ballotCount, 3);
  assert.strictEqual(t.totalWeight, 2.5);
  // round 0: A=2, B=0.5 ; round 1: A=1, B=1.5 ; round 2: A=0, B=2.5
  assert.deepStrictEqual(t.rounds, [
    {p1: 2, p2: 0.5}, {p1: 1, p2: 1.5}, {p1: 0, p2: 2.5},
  ]);
  const r = matchResultFromRounds(t.rounds, "A", "B");
  assert.strictEqual(r.winnerId, "B"); // B won rounds 1 and 2
});

check("a ballot that skips a round does not tip that round", () => {
  const ballots = [{weight: 1, picks: {0: "A"}}]; // only round 0 picked
  const t = tallyBallots(ballots, "A", "B", 3);
  assert.deepStrictEqual(t.rounds, [{p1: 1, p2: 0}, {p1: 0, p2: 0}, {p1: 0, p2: 0}]);
});

check("string and numeric round keys both work", () => {
  const t1 = tallyBallots([{weight: 1, picks: {"0": "A"}}], "A", "B", 1);
  const t2 = tallyBallots([{weight: 1, picks: {0: "A"}}], "A", "B", 1);
  assert.deepStrictEqual(t1.rounds, t2.rounds);
});

check("a bad weight counts as zero rather than NaN", () => {
  const t = tallyBallots([{weight: "oops", picks: {0: "A"}}], "A", "B", 1);
  assert.strictEqual(t.totalWeight, 0);
  assert.deepStrictEqual(t.rounds, [{p1: 0, p2: 0}]);
});

// ---- funniestRound (the Funniest Rounds board signal) --------------------
check("funniestRound picks the most-marked round (weighted)", () => {
  const r = funniestRound([
    {funniestRound: 1, weight: 1},
    {funniestRound: 1, weight: 1},
    {funniestRound: 2, weight: 1},
    {funniestRound: 0, weight: 0.5},
  ]);
  assert.deepStrictEqual(r, {round: 1, votes: 2});
});

check("funniestRound is null when nobody marked one", () => {
  assert.strictEqual(funniestRound([{picks: {0: "A"}}, {}]), null);
  assert.strictEqual(funniestRound([]), null);
  assert.strictEqual(funniestRound(null), null);
});

check("funniestRound ignores junk indices", () => {
  const r = funniestRound([
    {funniestRound: -1, weight: 1},
    {funniestRound: "x", weight: 1},
    {funniestRound: 2, weight: 1},
  ]);
  assert.deepStrictEqual(r, {round: 2, votes: 1});
});

console.log(`\n${passed} checks passed.`);
