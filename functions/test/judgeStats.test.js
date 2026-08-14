/**
 * Scoring a judge's calls against settled results.
 *
 * These counters feed a prestige ladder, so the rules that matter are the
 * ones stopping a record being inflated - by a replayed flush, by a match
 * that had no answer, or by a pick naming somebody who wasn't in the
 * battle.
 *
 * Run: node test/judgeStats.test.js
 */
const assert = require("assert");
const {scoreCalls, MAX_CALLS_PER_FLUSH} = require("../judgeStats");

let checks = 0;
function check(label, fn) {
  fn();
  checks += 1;
  console.log(`  ok  ${label}`);
}

const settled = (winnerId) => ({
  player1Id: "alice", player2Id: "bob",
  voteFinalized: true, winnerId,
});
const matches = (entries) => new Map(Object.entries(entries));

check("a correct call counts as correct", () => {
  const r = scoreCalls(
      [{matchId: "m1", chosenPlayerId: "alice"}],
      matches({m1: settled("alice")}));
  assert.deepStrictEqual(r, {total: 1, correct: 1});
});

check("a wrong call still counts as a call", () => {
  // Agreement rate is the signal, so being wrong has to be recorded - a
  // record of only correct calls would make everyone infallible.
  const r = scoreCalls(
      [{matchId: "m1", chosenPlayerId: "bob"}],
      matches({m1: settled("alice")}));
  assert.deepStrictEqual(r, {total: 1, correct: 0});
});

check("several calls accumulate", () => {
  const r = scoreCalls([
    {matchId: "m1", chosenPlayerId: "alice"},
    {matchId: "m2", chosenPlayerId: "bob"},
    {matchId: "m3", chosenPlayerId: "alice"},
  ], matches({m1: settled("alice"), m2: settled("alice"), m3: settled("alice")}));
  assert.deepStrictEqual(r, {total: 3, correct: 2});
});

check("a replayed flush cannot inflate the record", () => {
  // A client retrying a failed flush must not double-count, or a judge
  // record becomes a measure of network flakiness.
  const r = scoreCalls([
    {matchId: "m1", chosenPlayerId: "alice"},
    {matchId: "m1", chosenPlayerId: "alice"},
    {matchId: "m1", chosenPlayerId: "alice"},
  ], matches({m1: settled("alice")}));
  assert.deepStrictEqual(r, {total: 1, correct: 1});
});

check("a tie is dropped rather than marked wrong", () => {
  // There was no right answer, so a judge should not be marked down for it.
  const r = scoreCalls(
      [{matchId: "m1", chosenPlayerId: "alice"}],
      matches({m1: {...settled(null)}}));
  assert.deepStrictEqual(r, {total: 0, correct: 0});
});

check("an unsettled match is dropped", () => {
  // Its result is still moving; scoring against it would be scoring a
  // guess against another guess.
  const r = scoreCalls(
      [{matchId: "m1", chosenPlayerId: "alice"}],
      matches({m1: {...settled("alice"), voteFinalized: false}}));
  assert.deepStrictEqual(r, {total: 0, correct: 0});
});

check("a call naming someone not in the battle is dropped", () => {
  const r = scoreCalls(
      [{matchId: "m1", chosenPlayerId: "carol"}],
      matches({m1: settled("alice")}));
  assert.deepStrictEqual(r, {total: 0, correct: 0});
});

check("a call on a match that does not exist is dropped", () => {
  const r = scoreCalls(
      [{matchId: "ghost", chosenPlayerId: "alice"}], matches({}));
  assert.deepStrictEqual(r, {total: 0, correct: 0});
});

check("junk in the batch does not throw or count", () => {
  const r = scoreCalls(
      [null, undefined, {}, {matchId: "m1"}, {chosenPlayerId: "alice"}],
      matches({m1: settled("alice")}));
  assert.deepStrictEqual(r, {total: 0, correct: 0});
});

check("correct can never exceed total", () => {
  const r = scoreCalls([
    {matchId: "m1", chosenPlayerId: "alice"},
    {matchId: "m2", chosenPlayerId: "alice"},
  ], matches({m1: settled("alice"), m2: settled("alice")}));
  assert.ok(r.correct <= r.total);
});

check("an empty batch scores nothing", () => {
  assert.deepStrictEqual(scoreCalls([], matches({})), {total: 0, correct: 0});
});

check("the flush ceiling is small enough to bound one call's cost", () => {
  assert.ok(MAX_CALLS_PER_FLUSH <= 50, `too generous: ${MAX_CALLS_PER_FLUSH}`);
});

console.log(`\n${checks} checks passed.`);
