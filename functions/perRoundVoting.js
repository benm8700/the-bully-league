/**
 * Per-round vote tallying (PURE - no Firestore, no clock).
 *
 * The match winner is whoever won the MOST ROUNDS, not one overall vote
 * (developer's call, 2026-09-17): the ballot carries a per-round pick map, and
 * whoever won more rounds wins the match. (In the current feed the judge taps
 * ONE overall winner, which is stored as that player winning every round - the
 * per-round machinery still tallies it correctly.)
 *
 * A round whose weighted tallies are equal is a TIE and counts for neither
 * player. An equal number of rounds won is an overall tie (no winner), which
 * preserves the existing match-level tie rule (no rating change).
 *
 * Weights carry through from castVote (e.g. a <24h-old account votes at 0.5),
 * so these operate on weighted sums, never raw counts.
 */

/**
 * Decide one round from its weighted tallies.
 * @returns {1|2|0} 1 = player1 won the round, 2 = player2, 0 = tie.
 */
function roundOutcome(p1Weight, p2Weight) {
  const a = Number(p1Weight) || 0;
  const b = Number(p2Weight) || 0;
  if (a > b) return 1;
  if (b > a) return 2;
  return 0;
}

/**
 * Aggregate per-round weighted tallies into a match result.
 *
 * @param {Array<{p1:number,p2:number}>} rounds weighted tally per round.
 * @param {string} player1Id
 * @param {string} player2Id
 * @returns {{winnerId:(string|null), roundsWonP1:number,
 *            roundsWonP2:number, roundsTied:number}}
 *   winnerId is null on an overall tie.
 */
function matchResultFromRounds(rounds, player1Id, player2Id) {
  let p1 = 0;
  let p2 = 0;
  let tied = 0;
  for (const r of Array.isArray(rounds) ? rounds : []) {
    const o = roundOutcome(r && r.p1, r && r.p2);
    if (o === 1) p1 += 1;
    else if (o === 2) p2 += 1;
    else tied += 1;
  }
  let winnerId = null;
  if (p1 > p2) winnerId = player1Id;
  else if (p2 > p1) winnerId = player2Id;
  return {winnerId, roundsWonP1: p1, roundsWonP2: p2, roundsTied: tied};
}

/**
 * Build per-round weighted tallies from a list of ballots.
 *
 * Each ballot picks a winner per round: {weight, picks: {"0": uid, ...}}.
 * A round a ballot did not pick is simply not counted for that ballot -
 * a voter who skipped a round should not tip it either way.
 *
 * @param {Array<{weight:number, picks:Object}>} ballots
 * @param {string} player1Id
 * @param {string} player2Id
 * @param {number} roundCount
 * @returns {{rounds:Array<{p1:number,p2:number}>, ballotCount:number,
 *            totalWeight:number}}
 */
function tallyBallots(ballots, player1Id, player2Id, roundCount) {
  const n = Math.max(0, Math.trunc(Number(roundCount) || 0));
  const rounds = Array.from({length: n}, () => ({p1: 0, p2: 0}));
  let totalWeight = 0;
  const list = Array.isArray(ballots) ? ballots : [];
  for (const b of list) {
    const w = Number(b && b.weight);
    const weight = Number.isFinite(w) && w > 0 ? w : 0;
    totalWeight += weight;
    const picks = (b && b.picks) || {};
    for (let i = 0; i < n; i++) {
      const pick = picks[String(i)] ?? picks[i];
      if (pick === player1Id) rounds[i].p1 += weight;
      else if (pick === player2Id) rounds[i].p2 += weight;
    }
  }
  return {rounds, ballotCount: list.length, totalWeight};
}

module.exports = {
  roundOutcome, matchResultFromRounds, tallyBallots,
};
