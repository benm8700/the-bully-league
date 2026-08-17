const assert = require("assert");
const {applyResultToBracket, buildNextRound} = require("../tournament");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

const round = (roundNumber, matchups) => ({roundNumber, matchups});
const m = (p1, p2, winnerId = null) =>
  ({player1Id: p1, player2Id: p2, winnerId, isBye: false});

console.log("tournament results");

check("a real result settles its matchup", () => {
  const rounds = [round(1, [m("a", "b"), m("c", "d")])];
  const r = applyResultToBracket(rounds,
      {roundNumber: 1, matchupIndex: 0, winnerId: "a"});
  assert.strictEqual(r.changed, true);
  assert.strictEqual(r.rounds[0].matchups[0].winnerId, "a");
  // The other matchup is untouched, and the round has not advanced.
  assert.strictEqual(r.rounds[0].matchups[1].winnerId, null);
  assert.strictEqual(r.advanced, false);
});

check("THE ROUND ADVANCES only once every matchup is settled", () => {
  let rounds = [round(1, [m("a", "b"), m("c", "d")])];
  rounds = applyResultToBracket(rounds,
      {roundNumber: 1, matchupIndex: 0, winnerId: "a"}).rounds;
  const r = applyResultToBracket(rounds,
      {roundNumber: 1, matchupIndex: 1, winnerId: "d"});
  assert.strictEqual(r.advanced, true);
  assert.strictEqual(r.rounds.length, 2);
  assert.deepStrictEqual(
      [r.rounds[1].matchups[0].player1Id, r.rounds[1].matchups[0].player2Id],
      ["a", "d"]);
});

check("the final matchup completes the tournament", () => {
  const rounds = [round(1, [m("a", "b", "a"), m("c", "d", "d")]),
    round(2, [m("a", "d")])];
  const r = applyResultToBracket(rounds,
      {roundNumber: 2, matchupIndex: 0, winnerId: "d"});
  assert.strictEqual(r.completed, true);
  assert.strictEqual(r.tournamentWinnerId, "d");
  // No phantom round after the winner is decided.
  assert.strictEqual(r.rounds.length, 2);
});

check("IDEMPOTENT: re-applying a settled matchup changes nothing", () => {
  // Finalization is retryable, so a second application must not overwrite
  // a result or push a duplicate round.
  const rounds = [round(1, [m("a", "b", "a"), m("c", "d")])];
  const r = applyResultToBracket(rounds,
      {roundNumber: 1, matchupIndex: 0, winnerId: "b"});
  assert.strictEqual(r.changed, false);
  assert.strictEqual(r.reason, "already-settled");
  assert.strictEqual(r.rounds[0].matchups[0].winnerId, "a");
});

check("a re-applied FINAL result does not append a duplicate round", () => {
  let rounds = [round(1, [m("a", "b"), m("c", "d")])];
  rounds = applyResultToBracket(rounds,
      {roundNumber: 1, matchupIndex: 0, winnerId: "a"}).rounds;
  const first = applyResultToBracket(rounds,
      {roundNumber: 1, matchupIndex: 1, winnerId: "d"});
  const again = applyResultToBracket(first.rounds,
      {roundNumber: 1, matchupIndex: 1, winnerId: "d"});
  assert.strictEqual(again.changed, false);
  assert.strictEqual(again.rounds.length, 2, "must not add a third round");
});

check("SAFETY: a winner who is not in the matchup is refused", () => {
  // A mis-stamped match must never advance somebody who was not even in
  // the tournament - a bracket is exactly where that cannot be allowed.
  const rounds = [round(1, [m("a", "b")])];
  const r = applyResultToBracket(rounds,
      {roundNumber: 1, matchupIndex: 0, winnerId: "stranger"});
  assert.strictEqual(r.changed, false);
  assert.strictEqual(r.reason, "winner-not-in-matchup");
});

check("an unknown round or matchup is refused rather than guessed at", () => {
  const rounds = [round(1, [m("a", "b")])];
  assert.strictEqual(applyResultToBracket(rounds,
      {roundNumber: 9, matchupIndex: 0, winnerId: "a"}).reason, "no-such-round");
  assert.strictEqual(applyResultToBracket(rounds,
      {roundNumber: 1, matchupIndex: 7, winnerId: "a"}).reason, "no-such-matchup");
});

check("an empty bracket is refused", () => {
  assert.strictEqual(applyResultToBracket([],
      {roundNumber: 1, matchupIndex: 0, winnerId: "a"}).reason, "no-bracket");
});

check("a LATE result for an earlier round fills its gap, adding no round", () => {
  // Round 2 already exists. Settling a straggler in round 1 must not
  // rebuild rounds that are already under way.
  const rounds = [round(1, [m("a", "b", "a"), m("c", "d")]),
    round(2, [m("a", null)])];
  const r = applyResultToBracket(rounds,
      {roundNumber: 1, matchupIndex: 1, winnerId: "c"});
  assert.strictEqual(r.changed, true);
  assert.strictEqual(r.advanced, false);
  assert.strictEqual(r.rounds.length, 2);
  assert.strictEqual(r.rounds[0].matchups[1].winnerId, "c");
});

check("the input is not mutated - the caller decides what to persist", () => {
  const rounds = [round(1, [m("a", "b")])];
  applyResultToBracket(rounds, {roundNumber: 1, matchupIndex: 0, winnerId: "a"});
  assert.strictEqual(rounds[0].matchups[0].winnerId, null,
      "applyResultToBracket must not mutate its argument");
});

check("byes carry through to the next round like any other winner", () => {
  const rounds = [round(1, [
    {player1Id: "a", player2Id: null, winnerId: "a", isBye: true},
    m("c", "d"),
  ])];
  const r = applyResultToBracket(rounds,
      {roundNumber: 1, matchupIndex: 1, winnerId: "c"});
  assert.strictEqual(r.advanced, true);
  assert.deepStrictEqual(
      [r.rounds[1].matchups[0].player1Id, r.rounds[1].matchups[0].player2Id],
      ["a", "c"]);
});

check("a full 8-entrant bracket plays out to exactly one winner", () => {
  let rounds = [round(1, buildNextRound(
      [1, 2, 3, 4, 5, 6, 7, 8].map((n) => ({winnerId: `p${n}`})), 1).matchups)];
  let guard = 0;
  let winner = null;
  while (!winner && guard++ < 10) {
    const current = rounds[rounds.length - 1];
    for (let i = 0; i < current.matchups.length; i++) {
      if (rounds[rounds.length - 1].matchups[i].winnerId) continue;
      const r = applyResultToBracket(rounds, {
        roundNumber: current.roundNumber,
        matchupIndex: i,
        winnerId: rounds[rounds.length - 1].matchups[i].player1Id,
      });
      rounds = r.rounds;
      if (r.completed) winner = r.tournamentWinnerId;
    }
  }
  assert.strictEqual(winner, "p1");
  assert.strictEqual(rounds.length, 3, "8 entrants is three rounds");
});

console.log(`\n${passed} checks passed.`);
