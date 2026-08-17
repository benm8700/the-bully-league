const assert = require("assert");
const {
  tournamentMatchId, roundWindow, forfeitOutcome, currentMatchupFor,
  playability, DEFAULT_ROUND_WINDOW_HOURS,
} = require("../tournamentPlay");
const {buildNextRound, isSettled} = require("../tournament");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

const NOW = 1_700_000_000_000;
const HOUR = 3600 * 1000;

const tournamentWith = (matchups, round = {}) => ({
  status: "in_progress",
  bracket: {rounds: [{roundNumber: 1, matchups,
    windowStartMs: NOW - HOUR, windowEndMs: NOW + HOUR, ...round}]},
});
const m = (p1, p2, extra = {}) =>
  ({player1Id: p1, player2Id: p2, winnerId: null, isBye: false, ...extra});

console.log("tournamentPlay");

// ---------------------------------------------------- deterministic id
check("THE MATCH ID IS DERIVED, so two players cannot make two matches", () => {
  // Both tapping start at the same instant would otherwise create two
  // documents for one matchup, leaving each alone in a different channel.
  const a = tournamentMatchId("t1", 2, 3);
  const b = tournamentMatchId("t1", 2, 3);
  assert.strictEqual(a, b);
  assert.notStrictEqual(a, tournamentMatchId("t1", 2, 4));
  assert.notStrictEqual(a, tournamentMatchId("t2", 2, 3));
  assert.notStrictEqual(a, tournamentMatchId("t1", 3, 3));
});

// --------------------------------------------------------- the window
check("a round window runs from its start for the configured hours", () => {
  const w = roundWindow(NOW, 6);
  assert.strictEqual(w.windowStartMs, NOW);
  assert.strictEqual(w.windowEndMs, NOW + 6 * HOUR);
});

check("a nonsense window length falls back rather than breaking a round", () => {
  for (const bad of [0, -5, 9999, "soon", null, undefined, NaN]) {
    const w = roundWindow(NOW, bad);
    assert.strictEqual(w.windowEndMs - NOW,
        DEFAULT_ROUND_WINDOW_HOURS * HOUR, `hours=${bad}`);
  }
});

// ------------------------------------------------------- who may play
check("a player in the current round may start their match", () => {
  const t = tournamentWith([m("a", "b")]);
  const slot = currentMatchupFor(t, "a");
  assert.strictEqual(slot.opponentId, "b");
  assert.strictEqual(playability(slot, NOW).playable, true);
});

check("someone not in this round is told so, not handed a match", () => {
  const t = tournamentWith([m("a", "b")]);
  assert.strictEqual(currentMatchupFor(t, "zz"), null);
  assert.strictEqual(playability(null, NOW).reason, "not-in-this-round");
});

check("a bye is not playable - there is nobody to play", () => {
  const t = tournamentWith([{player1Id: "a", player2Id: null,
    winnerId: "a", isBye: true}]);
  assert.strictEqual(playability(currentMatchupFor(t, "a"), NOW).reason, "bye");
});

check("an already-decided matchup cannot be replayed", () => {
  const t = tournamentWith([m("a", "b", {winnerId: "a"})]);
  assert.strictEqual(
      playability(currentMatchupFor(t, "a"), NOW).reason, "already-decided");
});

check("outside the window, play is refused at both ends", () => {
  const t = tournamentWith([m("a", "b")]);
  const slot = currentMatchupFor(t, "a");
  assert.strictEqual(playability(slot, NOW + 2 * HOUR).reason, "window-closed");
  assert.strictEqual(playability(slot, NOW - 2 * HOUR).reason, "window-not-open");
});

check("a round with no window recorded is still playable", () => {
  // Brackets created before windows existed must not become unplayable.
  const t = tournamentWith([m("a", "b")],
      {windowStartMs: undefined, windowEndMs: undefined});
  assert.strictEqual(playability(currentMatchupFor(t, "a"), NOW).playable, true);
});

// ------------------------------------------------------------ forfeits
check("THE RULE: a no-show forfeits and the opponent advances", () => {
  const o = forfeitOutcome(m("a", "b"),
      {player1Arrived: true, player2Arrived: false});
  assert.strictEqual(o.winnerId, "a");
  assert.strictEqual(o.reason, "opponent-no-show");
});

check("it works from either side", () => {
  const o = forfeitOutcome(m("a", "b"),
      {player1Arrived: false, player2Arrived: true});
  assert.strictEqual(o.winnerId, "b");
});

check("BOTH no-showing eliminates both - nobody gets a free pass", () => {
  const o = forfeitOutcome(m("a", "b"),
      {player1Arrived: false, player2Arrived: false});
  assert.strictEqual(o.winnerId, null);
  assert.strictEqual(o.eliminated, true);
});

check("a matchup both players turned up for is left alone", () => {
  // Judged on ARRIVAL, not completion: someone who turned up and whose
  // opponent quit mid-match is not a no-show.
  assert.strictEqual(forfeitOutcome(m("a", "b"),
      {player1Arrived: true, player2Arrived: true}), null);
});

check("a decided matchup is never forfeited over", () => {
  assert.strictEqual(forfeitOutcome(m("a", "b", {winnerId: "a"}),
      {player1Arrived: false, player2Arrived: false}), null);
});

// ----------------------------------------------- empty slots downstream
check("whoever faces an emptied slot advances unopposed", () => {
  // Both players in one feeding matchup no-showed, so nothing came out of
  // it. Making the survivor play nobody would strand the bracket.
  const next = buildNextRound(
      [{winnerId: "a"}, {winnerId: null}], 2);
  assert.strictEqual(next.matchups[0].isBye, true);
  assert.strictEqual(next.matchups[0].winnerId, "a");
});

check("two emptied slots meeting is marked DEAD, not left unsettleable", () => {
  // Nobody can ever win this, and an open matchup would block its round
  // from advancing forever.
  const next = buildNextRound([{winnerId: null}, {winnerId: null}], 2);
  assert.strictEqual(next.matchups[0].isDead, true);
  assert.strictEqual(isSettled(next.matchups[0]), true,
      "a dead matchup must count as settled");
});

check("a normal pair is unaffected by any of this", () => {
  const next = buildNextRound([{winnerId: "a"}, {winnerId: "b"}], 2);
  assert.strictEqual(next.matchups[0].player1Id, "a");
  assert.strictEqual(next.matchups[0].player2Id, "b");
  assert.strictEqual(isSettled(next.matchups[0]), false);
});

console.log(`\n${passed} checks passed.`);
