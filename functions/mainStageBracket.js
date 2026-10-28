/**
 * Main Stage bracket - the pure core for the weekly finals.
 *
 * Four finalists, single elimination, with the signature mechanic: the #1
 * qualifier (top seed by weekly Elo gain) CALLS OUT the opponent they want in
 * their semifinal; the other two are auto-paired; the two semi winners meet in
 * the final. See the Tournament model decision record in CLAUDE.md.
 *
 * Pure and deterministic - no Firestore, no clock. The live flow drives it:
 * seed the four confirmed finalists, record the #1's pick, then feed in each
 * battle's winner. Kept separate from the old async `tournament.js` bracket
 * (which handles arbitrary sizes + byes); this is the fixed 4-player callout
 * format and nothing else.
 */

/**
 * Build the bracket from the four finalists (in SEED ORDER - seeds[0] is #1 by
 * weekly Elo gain) and the opponent #1 called out.
 *
 * The callout is #1 vs their pick; the remaining two seeds auto-pair. Throws on
 * a malformed field or an illegal pick, because a live show must never start
 * from a bad bracket.
 */
function createBracket(seeds, pickUid) {
  if (!Array.isArray(seeds) || seeds.length !== 4) {
    throw new Error("Main Stage bracket needs exactly 4 finalists");
  }
  if (new Set(seeds).size !== 4 || seeds.some((u) => !u)) {
    throw new Error("finalists must be 4 distinct players");
  }
  const [top, ...rest] = seeds;
  if (pickUid === top) {
    throw new Error("#1 cannot call out themselves");
  }
  if (!rest.includes(pickUid)) {
    throw new Error("#1 can only call out another finalist");
  }
  const others = rest.filter((u) => u !== pickUid);
  return {
    seeds,
    pick: pickUid,
    // Round 0 = the two semifinals; round 1 = the final.
    rounds: [
      [
        {a: top, b: pickUid, winner: null}, // the callout semi
        {a: others[0], b: others[1], winner: null},
      ],
      [{a: null, b: null, winner: null}], // the final, filled as semis settle
    ],
    champion: null,
    status: "semis", // semis -> final -> done
  };
}

function clone(bracket) {
  return {
    ...bracket,
    rounds: bracket.rounds.map((r) => r.map((m) => ({...m}))),
  };
}

/**
 * Record the winner of one matchup and advance. Returns a new bracket.
 * - The winner must be one of that matchup's two (known) players.
 * - The final cannot be decided until both semis have winners.
 * - Idempotent: re-applying the SAME winner to a settled matchup is a no-op;
 *   a DIFFERENT winner to an already-settled matchup is rejected (ignored).
 */
function applyResult(bracket, roundIdx, matchIdx, winnerUid) {
  const b = clone(bracket);
  const m = b.rounds[roundIdx] && b.rounds[roundIdx][matchIdx];
  if (!m) return b; // no such matchup
  if (m.a == null || m.b == null) return b; // not ready (final before semis)
  if (winnerUid !== m.a && winnerUid !== m.b) return b; // not in this matchup
  if (m.winner != null) return b; // already settled - idempotent

  m.winner = winnerUid;

  if (roundIdx === 0) {
    const [semiA, semiB] = b.rounds[0];
    if (semiA.winner != null && semiB.winner != null) {
      b.rounds[1][0].a = semiA.winner;
      b.rounds[1][0].b = semiB.winner;
      b.status = "final";
    }
  } else if (roundIdx === 1) {
    b.champion = winnerUid;
    b.status = "done";
  }
  return b;
}

/**
 * The matchups ready to play right now: both players known, no winner yet.
 * Each as {roundIdx, matchIdx, a, b}. Drives "what's on the Main Stage now".
 */
function nextMatches(bracket) {
  const out = [];
  bracket.rounds.forEach((round, roundIdx) => {
    round.forEach((m, matchIdx) => {
      if (m.a != null && m.b != null && m.winner == null) {
        out.push({roundIdx, matchIdx, a: m.a, b: m.b});
      }
    });
  });
  return out;
}

function isComplete(bracket) {
  return bracket.status === "done";
}

/**
 * Stamp `openedMs` on every matchup that is ready to play (both players known,
 * no winner) and not already stamped - this is the clock the stuck-matchup
 * backstop keys off, so a no-show can't halt the show forever. Pure: the caller
 * passes `now` and stores the result. Already-stamped and already-settled
 * matchups are left untouched.
 */
function stampOpened(bracket, now) {
  const b = clone(bracket);
  for (const round of b.rounds) {
    for (const m of round) {
      if (m.a != null && m.b != null && m.winner == null && m.openedMs == null) {
        m.openedMs = now;
      }
    }
  }
  return b;
}

/**
 * Who advances when a matchup is force-resolved for a no-show / abandon. The
 * player who actually SHOWED (started the battle) beats the one who didn't; if
 * nobody started (or it's unknown), the higher seed - the 'a' slot - advances,
 * since a bracket must have exactly one winner. Never a draw (unlike a gauntlet).
 */
function forfeitWinner(m, startedBy) {
  if (startedBy === m.a || startedBy === m.b) return startedBy;
  return m.a;
}

/**
 * PURE. Should a ready-but-unresolved matchup be force-advanced for a no-show?
 *
 * `matchInfo` is null when no battle was ever started (no matchId), else
 * {status, judgeWinnerId, startedBy, createdMs} read from the match doc. Returns
 * {winner} to force-advance, or null to leave it alone. A matchup whose battle
 * actually FINISHED (status completed, or a verdict landed) is left to the
 * judging-stall sweeps; this only catches a battle nobody ever started, or one
 * started and then abandoned before it could complete.
 */
function stuckMatchupOutcome(m, matchInfo, now, noShowMs) {
  if (!m || m.a == null || m.b == null || m.winner != null) return null;
  // A clock is only valid once we have a real (positive, finite) timestamp;
  // a missing / zero value means "no clock yet", never "opened at epoch".
  const aged = (ts) => {
    const t = Number(ts);
    return Number.isFinite(t) && t > 0 && now - t >= noShowMs;
  };
  if (matchInfo) {
    // A started battle: leave it alone once it finished (judging owns it) or
    // while it is still plausibly live.
    if (matchInfo.status === "completed" || matchInfo.judgeWinnerId) return null;
    if (!aged(matchInfo.createdMs)) return null;
    return {winner: forfeitWinner(m, matchInfo.startedBy)};
  }
  // Nobody ever started this matchup.
  if (!aged(m.openedMs)) return null;
  return {winner: forfeitWinner(m, null)};
}

module.exports = {
  createBracket,
  applyResult,
  nextMatches,
  isComplete,
  stampOpened,
  forfeitWinner,
  stuckMatchupOutcome,
};
