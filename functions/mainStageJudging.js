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
 *   forceClose - true at the window deadline: decide on whatever was cast
 *                rather than waiting for every seat.
 * Returns {counts, cast, remaining, winner, tie, decided}:
 *   winner   - the candidate with the most panel votes (head-judge tiebreak), or
 *              null if genuinely tied / no votes.
 *   decided  - true once the result is final: every seat has voted, OR the lead
 *              is bigger than the seats still out, OR forceClose. A decided
 *              verdict with a null winner means "tied, no winner" (the caller
 *              applies the tie rule / crowd fallback).
 */
function tallyJudgeVotes(votes, panel, {headJudge = null, forceClose = false} = {}) {
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

  // Final when: every seat voted; or forced at the deadline; or the lead can no
  // longer be overturned by the seats still out (early, decisive close - the
  // "2 more votes and this is decided" idea, without waiting on a slow judge).
  const insurmountable =
    leaders.length === 1 && top - second > remaining;
  const decided = remaining === 0 || forceClose || insurmountable;

  // A forced close that's still a bare tie yields no winner (caller's tie rule).
  return {counts, cast, remaining, winner: decided ? winner : null, tie, decided};
}

/** 12 minutes from battle start covers a chess-clock battle (~a few minutes)
 * plus the judging debate, after which a stalled panel is force-closed so the
 * bracket can never halt. The stamped `match.judgeWindowMs` wins over this. */
const DEFAULT_JUDGE_WINDOW_MS = 12 * 60 * 1000;

/** Milliseconds from a Firestore Timestamp, a {_seconds}/{seconds} shape, or a
 * plain number - 0 when unknowable, so a missing start is never treated as
 * "long ago" (the missing-field trap that would force-close a fresh battle). */
function tsMs(v) {
  if (v == null) return 0;
  if (typeof v === "number") return v;
  if (typeof v.toMillis === "function") return v.toMillis();
  const s = v._seconds ?? v.seconds;
  return typeof s === "number" ? s * 1000 : 0;
}

/**
 * Decide an on-stage battle whose panel has STALLED past its judging deadline,
 * so a quiet or absent judge can never halt the whole finals with the audience
 * watching. Pure, so the deadline + tiebreak are pinned by tests rather than
 * discovered live.
 *
 *   match  - the battle doc: needs createdAt (ms-able), judgeWindowMs,
 *            player1Id/player2Id, and judgeWinnerId (already settled -> skip).
 *   votes  - {judgeUid: winnerUid}
 *   panel  - seated judge uids; headJudge breaks a bare tie (as in a live vote)
 *   field  - the tournament seed order (field[0] = #1). THE DETERMINISTIC
 *            TIEBREAK when the panel is dead-even or silent: the HIGHER SEED
 *            advances. A bracket must have exactly one winner, so a null verdict
 *            is never acceptable here - unlike a gauntlet tie, where both climb.
 *   now    - ms.
 *
 * @return {{stalled: boolean, winner?: string}} stalled only past the deadline
 *   with no winner yet; winner is always one of the two battlers when stalled.
 */
function stalledBattleVerdict(
    {match, votes, panel, headJudge = null, field = [], now}) {
  if (!match || match.judgeWinnerId) return {stalled: false};
  const startMs = tsMs(match.createdAt);
  if (!startMs) return {stalled: false}; // unknowable start - never force-close
  const stamped = Number(match.judgeWindowMs);
  const windowMs = stamped > 0 ? stamped : DEFAULT_JUDGE_WINDOW_MS;
  if (now < startMs + windowMs) return {stalled: false};

  const p1 = match.player1Id;
  const p2 = match.player2Id;
  const tally = tallyJudgeVotes(votes, panel, {headJudge, forceClose: true});
  let winner = tally.winner;
  if (winner !== p1 && winner !== p2) {
    // Dead tie or no votes at the deadline: the higher seed advances, so the
    // bracket always gets exactly one winner. An unknown seed sorts last.
    const rank = (u) => {
      const i = field.indexOf(u);
      return i === -1 ? Number.MAX_SAFE_INTEGER : i;
    };
    winner = rank(p1) <= rank(p2) ? p1 : p2;
  }
  return {stalled: true, winner};
}

module.exports = {tallyJudgeVotes, stalledBattleVerdict, DEFAULT_JUDGE_WINDOW_MS};
