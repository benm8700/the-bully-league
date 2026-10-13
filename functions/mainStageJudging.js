/**
 * Main Stage judging - the pure verdict core for the lean judging model.
 *
 * The 5-seat panel decides the finals by casting OPEN live votes (each judge
 * picks the battle's winner; the running tally is visible to the crowd). This
 * tallies those votes into a verdict. The head judge (the founder) breaks a
 * tie, which is why an even panel is survivable. The wiring
 * (mainStageJudgingPlay.js) persists votes, backfills a live no-show from the
 * standby list, and on a decided verdict calls
 * mainStageTournament.recordBattleResult to advance the bracket.
 *
 * Pure and deterministic - no Firestore, no clock. Only votes from SEATED panel
 * members count (a promoted standby is added to the panel before tallying).
 */

/**
 * Tally open judge votes.
 *   votes      - {judgeUid: winnerUid} (the candidate each judge picked).
 *   panel      - the seated judge uids (authoritative; standby promotions are
 *                already folded in by the caller).
 *   headJudge  - the founder's uid; breaks a tie. Optional.
 * Returns {counts, cast, remaining, winner, tie, decided}:
 *   winner   - the candidate with the most panel votes (head-judge tiebreak), or
 *              null if genuinely tied / no votes.
 *   decided  - true once the result is final: every seat has voted, OR the lead
 *              is bigger than the seats still out (an early, decisive close). A
 *              decided verdict with a null winner means "tied, no winner" (the
 *              caller applies the tie rule). There is NO deadline/force-close -
 *              a debate settles when the panel decides, not on a clock.
 */
function tallyJudgeVotes(votes, panel, {headJudge = null} = {}) {
  const seated = new Set((panel || []).filter((u) => typeof u === "string" && u));
  const counts = {};
  let cast = 0;
  for (const [judge, cand] of Object.entries(votes || {})) {
    if (!seated.has(judge) || !cand) continue; // only seated judges count
    counts[cand] = (counts[cand] || 0) + 1;
    cast++;
  }
  const remaining = Math.max(0, seated.size - cast);

  // Rank candidates by votes.
  const ranked = Object.keys(counts).sort((a, b) => counts[b] - counts[a]);
  const top = ranked.length ? counts[ranked[0]] : 0;
  const leaders = ranked.filter((c) => counts[c] === top);
  const second = ranked.length > 1 ? counts[ranked[1]] : 0;

  let winner = null;
  let tie = false;
  if (leaders.length === 1) {
    winner = leaders[0];
  } else if (leaders.length > 1) {
    tie = true;
    const hv = headJudge ? votes[headJudge] : null; // head judge breaks it
    if (hv && leaders.includes(hv)) {
      winner = hv;
      tie = false;
    }
  }

  // Final when: every seat voted; or the lead can no longer be overturned by
  // the seats still out (an early, decisive close - the "2 more votes and this
  // is decided" idea, without waiting on a slow judge). No deadline.
  const insurmountable =
    leaders.length === 1 && top - second > remaining;
  const decided = remaining === 0 || insurmountable;

  // A decided-but-bare-tie yields no winner (the caller's tie rule).
  return {counts, cast, remaining, winner: decided ? winner : null, tie, decided};
}

module.exports = {tallyJudgeVotes};
