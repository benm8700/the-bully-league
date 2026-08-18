const {getFirestore} = require("firebase-admin/firestore");

const DEFAULT_MIN_ENTRANTS = 4;

function shuffle(array) {
  const arr = [...array];
  for (let i = arr.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [arr[i], arr[j]] = [arr[j], arr[i]];
  }
  return arr;
}

function nextPowerOfTwo(n) {
  let p = 1;
  while (p < n) p *= 2;
  return p;
}

/**
 * Random seeding (CLAUDE.md's Bracket seeding decision) with byes for
 * non-power-of-2 entrant counts (CLAUDE.md's Bracket size decision - any
 * entrant count is allowed, not just 8/16/32).
 *
 * Byes and real entrants are NOT simply shuffled together into one slot
 * list and paired sequentially - that can randomly place two bye slots
 * in the same matchup (both players null), which has no one to advance.
 * byeCount is always < bracketSize / 2 (since entrantCount is always
 * more than half of the next power of two), so it's always POSSIBLE to
 * give every bye its own matchup - this just does that explicitly:
 * shuffle entrants, peel off the first `byeCount` as auto-advancing bye
 * matchups, pair the rest normally, then shuffle the matchup order so
 * byes aren't all clustered together in the bracket display.
 */
function buildFirstRound(entrantIds) {
  const shuffled = shuffle(entrantIds);
  const bracketSize = nextPowerOfTwo(shuffled.length);
  const byeCount = bracketSize - shuffled.length;

  const byePlayers = shuffled.slice(0, byeCount);
  const pairedPlayers = shuffled.slice(byeCount);

  const matchups = byePlayers.map((playerId) => ({
    player1Id: playerId,
    player2Id: null,
    winnerId: playerId,
    isBye: true,
  }));
  for (let i = 0; i < pairedPlayers.length; i += 2) {
    matchups.push({
      player1Id: pairedPlayers[i],
      player2Id: pairedPlayers[i + 1],
      winnerId: null,
      isBye: false,
    });
  }
  return shuffle(matchups);
}

/**
 * Every round after the first always has an even winner count, since the
 * bracket size is a power of 2 by construction - byes only ever matter in
 * round 1 to reach that power of 2.
 */
function buildNextRound(previousRoundMatchups, roundNumber) {
  const winners = previousRoundMatchups.map((m) => m.winnerId);
  const matchups = [];
  for (let i = 0; i < winners.length; i += 2) {
    const p1 = winners[i] ?? null;
    const p2 = winners[i + 1] ?? null;

    // A null arrives when BOTH players in the feeding matchup no-showed
    // and were eliminated together, so nobody came out of that slot.
    // Whoever faces an empty slot advances unopposed, exactly like a
    // round-1 bye - making them play nobody would strand the bracket.
    if (p1 && !p2) {
      matchups.push({player1Id: p1, player2Id: null, winnerId: p1, isBye: true});
    } else if (!p1 && p2) {
      matchups.push({player1Id: p2, player2Id: null, winnerId: p2, isBye: true});
    } else if (!p1 && !p2) {
      // Two empty slots meet. Nobody can ever win this, so it is marked
      // dead rather than left open - an unsettleable matchup would block
      // its round from ever advancing.
      matchups.push({player1Id: null, player2Id: null, winnerId: null,
        isBye: false, isDead: true});
    } else {
      matchups.push({player1Id: p1, player2Id: p2, winnerId: null, isBye: false});
    }
  }
  return {roundNumber, matchups};
}

/** A matchup nobody is waiting on: decided, or impossible to decide. */
function isSettled(matchup) {
  return Boolean(matchup.winnerId) || matchup.isDead === true;
}

/**
 * Closes entry and generates round 1. If entrants haven't met the
 * tournament's minimum, cancels instead (CLAUDE.md's "golden parachute"
 * decision) - no refund logic needed since V1 tournaments don't collect
 * real entry fees yet (see CLAUDE.md's step 8 status note).
 */
async function generateBracket(tournamentId) {
  const db = getFirestore();
  const tournamentRef = db.collection("tournaments").doc(tournamentId);
  const tournamentSnap = await tournamentRef.get();
  if (!tournamentSnap.exists) {
    return {error: "not-found"};
  }
  const tournament = tournamentSnap.data();
  if (tournament.status !== "open") {
    return {error: "not-open", status: tournament.status};
  }

  const entrantsSnap = await tournamentRef.collection("entrants").get();
  const entrantIds = entrantsSnap.docs.map((d) => d.id);
  // A bracket needs at least 2 entrants regardless of the tournament's
  // configured minimum - buildFirstRound has no meaningful matchup to
  // build for 0 or 1 entrants.
  const minEntrants = Math.max(tournament.minEntrants ?? DEFAULT_MIN_ENTRANTS, 2);

  if (entrantIds.length < minEntrants) {
    await tournamentRef.update({status: "cancelled"});
    return {status: "cancelled", entrantCount: entrantIds.length, minEntrants};
  }

  // Round 1 gets its window here, and every later round gets one as it is
  // built. Without a window nothing is ever forfeitable and a bracket
  // stalls the first time somebody loses interest.
  const {roundWindow} = require("./tournamentPlay");
  const firstRound = Object.assign(
      {roundNumber: 1, matchups: buildFirstRound(entrantIds)},
      roundWindow(Date.now(), tournament.roundWindowHours));
  await tournamentRef.update({
    status: "in_progress",
    bracket: {rounds: [firstRound]},
  });
  return {status: "in_progress", entrantCount: entrantIds.length};
}

/**
 * Resolves any still-open matchups in the current round and either
 * advances to the next round or, if only one winner remains, completes
 * the tournament. Winner selection here is a coin flip - this function
 * only exists to prove the bracket-advancement mechanics work end to end
 * (see CLAUDE.md's step 8 status note); real tournament matches (once
 * wired to the actual match+vote pipeline) would resolve winnerId from a
 * finalized match instead of guessing.
 */
async function debugAdvanceRound(tournamentId) {
  const db = getFirestore();
  const tournamentRef = db.collection("tournaments").doc(tournamentId);
  const tournamentSnap = await tournamentRef.get();
  if (!tournamentSnap.exists) {
    return {error: "not-found"};
  }
  const tournament = tournamentSnap.data();
  if (tournament.status !== "in_progress") {
    return {error: "not-in-progress", status: tournament.status};
  }

  const rounds = tournament.bracket?.rounds ?? [];
  if (rounds.length === 0) {
    return {error: "no-bracket"};
  }

  const currentRound = rounds[rounds.length - 1];
  const resolvedMatchups = currentRound.matchups.map((m) => {
    if (m.winnerId) return m;
    return {...m, winnerId: Math.random() < 0.5 ? m.player1Id : m.player2Id};
  });
  rounds[rounds.length - 1] = {...currentRound, matchups: resolvedMatchups};

  const winners = resolvedMatchups.map((m) => m.winnerId);
  if (winners.length === 1) {
    await tournamentRef.update({
      status: "completed",
      winnerId: winners[0],
      bracket: {rounds},
    });
    return {status: "completed", winnerId: winners[0]};
  }

  rounds.push(buildNextRound(resolvedMatchups, currentRound.roundNumber + 1));
  await tournamentRef.update({bracket: {rounds}});
  return {status: "in_progress", roundNumber: currentRound.roundNumber + 1};
}

/**
 * Applies a real match result to a bracket, and advances the round once
 * every matchup in it is settled.
 *
 * THIS IS THE PIECE THAT MAKES BRACKETS REAL. Until now the only way a
 * round advanced was `debugAdvanceRound`, which picks winners with
 * Math.random() - it exists to prove the advancement mechanics, not to
 * decide anything. A tournament whose results are coin flips is a bracket
 * simulator, not a competition, and prizes eventually ride on this.
 *
 * PURE, taking and returning the rounds array, so the whole advancement
 * can be exercised without Firestore - the same approach that caught the
 * bye-collision bug before it reached a device.
 *
 * Idempotent: a matchup that already has a winner is left alone. Match
 * finalization can be retried, and a second application must not
 * overwrite a settled result or push a duplicate round.
 */
function applyResultToBracket(rounds, {roundNumber, matchupIndex, winnerId,
  nowMs = Date.now(), roundWindowHours} = {}) {
  if (!Array.isArray(rounds) || rounds.length === 0) {
    return {rounds, changed: false, reason: "no-bracket"};
  }
  const roundPos = rounds.findIndex((r) => r.roundNumber === roundNumber);
  if (roundPos < 0) return {rounds, changed: false, reason: "no-such-round"};

  const round = rounds[roundPos];
  const matchup = round.matchups?.[matchupIndex];
  if (!matchup) return {rounds, changed: false, reason: "no-such-matchup"};
  if (matchup.winnerId) return {rounds, changed: false, reason: "already-settled"};

  // The winner must be one of the two players in THIS matchup. Without
  // this a mis-stamped match could advance someone who was never in the
  // tournament, and a bracket is exactly the place that must not happen.
  if (winnerId !== matchup.player1Id && winnerId !== matchup.player2Id) {
    return {rounds, changed: false, reason: "winner-not-in-matchup"};
  }

  const next = rounds.map((r) => ({...r, matchups: [...r.matchups]}));
  next[roundPos].matchups[matchupIndex] = {...matchup, winnerId};

  // Only the LATEST round can advance. A late result for an earlier round
  // fills its gap without rebuilding rounds that already exist.
  if (roundPos !== next.length - 1) {
    return {rounds: next, changed: true, advanced: false};
  }

  const settled = next[roundPos].matchups.every(isSettled);
  if (!settled) return {rounds: next, changed: true, advanced: false};

  // Dead slots are excluded: they carry nobody forward, so counting them
  // would make a one-real-winner round look unfinished.
  const winners = next[roundPos].matchups.map((m) => m.winnerId).filter(Boolean);
  if (winners.length === 1) {
    return {rounds: next, changed: true, advanced: true,
      completed: true, tournamentWinnerId: winners[0]};
  }
  const {roundWindow} = require("./tournamentPlay");
  next.push(Object.assign(
      buildNextRound(next[roundPos].matchups, roundNumber + 1),
      roundWindow(nowMs, roundWindowHours)));
  return {rounds: next, changed: true, advanced: true, completed: false};
}

/**
 * Records a finalized tournament match against its bracket.
 *
 * Best-effort by design: a bracket that fails to advance is recoverable
 * by an admin, whereas throwing here would fail the finalization that
 * already applied real rating changes.
 */
async function recordTournamentResult(match, winnerId) {
  const link = match?.tournament;
  if (!link?.tournamentId || !winnerId) return {applied: false};
  // A tie leaves the matchup open rather than advancing nobody - the
  // no-rating-change tie rule makes sense for ranked, but a bracket needs
  // somebody to progress, so this is left for an admin to settle.
  const db = getFirestore();
  const ref = db.collection("tournaments").doc(link.tournamentId);

  try {
    return await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) return {applied: false, reason: "not-found"};
      const tournament = snap.data();
      if (tournament.status !== "in_progress") {
        return {applied: false, reason: "not-in-progress"};
      }
      const result = applyResultToBracket(tournament.bracket?.rounds ?? [], {
        roundNumber: link.roundNumber,
        matchupIndex: link.matchupIndex,
        winnerId,
        roundWindowHours: tournament.roundWindowHours,
      });
      if (!result.changed) return {applied: false, reason: result.reason};

      const update = {bracket: {rounds: result.rounds}};
      if (result.completed) {
        update.status = "completed";
        update.winnerId = result.tournamentWinnerId;
      }
      tx.update(ref, update);
      return {applied: true, advanced: result.advanced === true,
        completed: result.completed === true};
    });
  } catch (e) {
    console.error(`tournament result for ${link.tournamentId} failed:`, e.message);
    return {applied: false, reason: "error"};
  }
}

module.exports = {
  generateBracket, debugAdvanceRound, recordTournamentResult,
  applyResultToBracket, buildNextRound, isSettled, DEFAULT_MIN_ENTRANTS,
  buildFirstRound,
};
