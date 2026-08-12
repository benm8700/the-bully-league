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
    matchups.push({
      player1Id: winners[i],
      player2Id: winners[i + 1],
      winnerId: null,
      isBye: false,
    });
  }
  return {roundNumber, matchups};
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

  const firstRound = {roundNumber: 1, matchups: buildFirstRound(entrantIds)};
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

module.exports = {generateBracket, debugAdvanceRound, DEFAULT_MIN_ENTRANTS};
