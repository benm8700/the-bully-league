const {getFirestore, FieldValue, Timestamp} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");

/**
 * Actually PLAYING a tournament match.
 *
 * THE GAP THIS FILLS: ordinary matchmaking pairs two people out of a
 * queue, but a bracket matchup is two NAMED players who must face each
 * other. So none of the queue machinery applies - the pairing is already
 * decided, and what is needed instead is a way for those two specific
 * people to meet in the same match document.
 *
 * HOW THEY MEET: the match id is DERIVED from the bracket slot rather
 * than generated. Two players tapping "start" at the same moment would
 * otherwise create two match documents for one matchup and each sit alone
 * in a different channel. A deterministic id makes that impossible by
 * construction: whoever gets there first creates it, the second finds it,
 * and a transaction settles any tie.
 *
 * ASYNC, per CLAUDE.md's tournament format decision: each round has a
 * window rather than a scheduled kickoff, and players complete their
 * match whenever suits them inside it. Missing the window forfeits.
 */

/** How long a round stays open, unless a tournament overrides it. Long
 * enough to cross a working day and an evening, since the whole point of
 * the async format is not needing both people free at one moment. */
const DEFAULT_ROUND_WINDOW_HOURS = 24;
const ROUND_WINDOW_LIMITS = {min: 1, max: 168};

/** A deterministic match id for a bracket slot. */
function tournamentMatchId(tournamentId, roundNumber, matchupIndex) {
  return `t_${tournamentId}_r${roundNumber}_m${matchupIndex}`;
}

/**
 * The window for a round, given when it started.
 *
 * Pure. Returned as millis so callers can store whatever shape they like.
 */
function roundWindow(startMs, hours = DEFAULT_ROUND_WINDOW_HOURS) {
  const h = Number(hours);
  const safe = Number.isFinite(h) && h >= ROUND_WINDOW_LIMITS.min &&
    h <= ROUND_WINDOW_LIMITS.max ? h : DEFAULT_ROUND_WINDOW_HOURS;
  return {windowStartMs: startMs, windowEndMs: startMs + safe * 3600 * 1000};
}

/**
 * How an unplayed matchup should be settled once its window has closed.
 *
 * CLAUDE.md's rule, and the reasoning matters: a no-show is an auto-loss
 * and the opponent advances, because otherwise entering and never playing
 * would be a risk-free way to get an entry fee back. If BOTH miss it,
 * both are eliminated and nobody advances - the slot goes empty rather
 * than handing a free pass to someone who also did not turn up.
 *
 * A matchup where somebody actually PLAYED is never touched here; that is
 * the result pipeline's business.
 *
 * Pure, so the whole rule is testable without Firestore or a clock.
 */
function forfeitOutcome(matchup, {player1Arrived, player2Arrived}) {
  if (!matchup || matchup.winnerId) return null;
  // A bye already has its winner, so it never reaches this.
  if (player1Arrived && player2Arrived) return null;

  if (player1Arrived) {
    return {winnerId: matchup.player1Id, reason: "opponent-no-show"};
  }
  if (player2Arrived) {
    return {winnerId: matchup.player2Id, reason: "opponent-no-show"};
  }
  // Nobody turned up. Eliminated together, no refund - and crucially no
  // winner, so nothing advances out of this slot.
  return {winnerId: null, reason: "both-no-show", eliminated: true};
}

/**
 * Finds the caller's live matchup in a tournament.
 *
 * Only the LATEST round is playable: earlier rounds are either finished
 * or being swept for forfeits.
 *
 * Pure.
 */
function currentMatchupFor(tournament, uid) {
  const rounds = tournament?.bracket?.rounds ?? [];
  if (rounds.length === 0) return null;
  const round = rounds[rounds.length - 1];
  const index = round.matchups.findIndex(
      (m) => m.player1Id === uid || m.player2Id === uid);
  if (index < 0) return null;
  const matchup = round.matchups[index];
  return {
    roundNumber: round.roundNumber,
    matchupIndex: index,
    matchup,
    opponentId: matchup.player1Id === uid ? matchup.player2Id : matchup.player1Id,
    windowStartMs: round.windowStartMs ?? null,
    windowEndMs: round.windowEndMs ?? null,
  };
}

/**
 * Whether a matchup can be started right now, and why not if it cannot.
 *
 * Pure.
 */
function playability(slot, nowMs) {
  if (!slot) return {playable: false, reason: "not-in-this-round"};
  // Checked BEFORE winnerId, because a bye carries both - and "you have a
  // bye, you're already through" tells someone something useful where
  // "already decided" just reads as an error.
  if (slot.matchup.isBye || !slot.opponentId) {
    return {playable: false, reason: "bye"};
  }
  if (slot.matchup.winnerId) return {playable: false, reason: "already-decided"};
  if (slot.windowEndMs && nowMs > slot.windowEndMs) {
    return {playable: false, reason: "window-closed"};
  }
  if (slot.windowStartMs && nowMs < slot.windowStartMs) {
    return {playable: false, reason: "window-not-open"};
  }
  return {playable: true, reason: null};
}

/**
 * Starts (or joins) the caller's tournament match.
 *
 * Returns the same pairing shape the matchmaking flow hands back, so the
 * client can reuse the whole existing match path rather than growing a
 * second one.
 */
async function startTournamentMatch(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const {tournamentId} = data || {};
  if (!tournamentId) {
    throw new HttpsError("invalid-argument", "tournamentId is required.");
  }

  const db = getFirestore();
  const uid = auth.uid;
  const nowMs = Date.now();

  const tSnap = await db.collection("tournaments").doc(tournamentId).get();
  if (!tSnap.exists) throw new HttpsError("not-found", "Tournament not found.");
  const tournament = tSnap.data();
  if (tournament.status !== "in_progress") {
    throw new HttpsError("failed-precondition",
        "This tournament isn't running.");
  }

  const slot = currentMatchupFor(tournament, uid);
  const verdict = playability(slot, nowMs);
  if (!verdict.playable) {
    const messages = {
      "not-in-this-round": "You're not in the current round.",
      "already-decided": "Your match this round is already decided.",
      "bye": "You have a bye this round - you're already through.",
      "window-closed": "This round's window has closed.",
      "window-not-open": "This round hasn't opened yet.",
    };
    throw new HttpsError("failed-precondition",
        messages[verdict.reason] ?? "You can't play right now.",
        {reason: verdict.reason});
  }

  const {getMatchSettings} = require("./matchSettings");
  const settings = await getMatchSettings("tournament");
  const matchId = tournamentMatchId(
      tournamentId, slot.roundNumber, slot.matchupIndex);
  const matchRef = db.collection("matches").doc(matchId);

  // Created inside a transaction on a DERIVED id, so two players tapping
  // start at the same instant cannot produce two documents for one
  // matchup - which would leave each of them alone in a different
  // channel, waiting for someone who is never coming.
  await db.runTransaction(async (tx) => {
    const existing = await tx.get(matchRef);
    if (existing.exists) return;
    tx.set(matchRef, {
      // Bracket order decides who is player1, so both clients agree on
      // the fixed Agora uids without negotiating.
      player1Id: slot.matchup.player1Id,
      player2Id: slot.matchup.player2Id,
      mode: "tournament",
      settings,
      // Entry was already bought; this never counts toward the daily
      // window bonus, which is about turning up to Sixes and Sevens.
      eventWindow: {qualified: false, name: null},
      origin: "tournament",
      tournament: {
        tournamentId,
        roundNumber: slot.roundNumber,
        matchupIndex: slot.matchupIndex,
      },
      status: "pending",
      channelName: `match_${matchId}`,
      createdAt: FieldValue.serverTimestamp(),
      completedAt: null,
      voteFinalized: false,
      winnerId: null,
      voteCount: 0,
      readyPlayerIds: [],
    });
  });

  // Recorded so the forfeit sweep can tell "turned up and played" from
  // "never came". Written outside the transaction because arriving is not
  // the thing being made atomic - the document is.
  await matchRef.set({
    arrivedAt: {[uid]: nowMs},
  }, {merge: true});

  const match = (await matchRef.get()).data();
  return {
    matchId,
    channelName: match.channelName,
    opponentId: slot.opponentId,
    mode: "tournament",
    settings: match.settings,
    agoraUid: match.player1Id === uid ? 1 : 2,
    roundNumber: slot.roundNumber,
    windowEndMs: slot.windowEndMs,
    opponentArrived: Object.keys(match.arrivedAt ?? {})
        .some((id) => id === slot.opponentId),
  };
}

/**
 * Closes rounds whose window has expired, settling anything unplayed.
 *
 * WITHOUT THIS THE WINDOW IS DECORATION. An async bracket where nobody is
 * ever forfeited simply stalls the first time one person loses interest,
 * and every other entrant is stuck behind them indefinitely.
 *
 * Arrival is judged by whether a player actually opened their match, not
 * by whether it finished - somebody who turned up and whose opponent
 * never did should not be punished for the match being unplayable.
 */
async function sweepTournamentForfeits(nowMs = Date.now()) {
  const db = getFirestore();
  const {applyResultToBracket, buildNextRound, isSettled} = require("./tournament");

  const snap = await db.collection("tournaments")
      .where("status", "==", "in_progress").get();

  const results = [];
  for (const doc of snap.docs) {
    try {
      const tournament = doc.data();
      const rounds = tournament.bracket?.rounds;
      // Guarded rather than assumed. Brackets are hand-editable in the
      // Firebase console, which is the documented admin tool, so a
      // malformed one is a real possibility - and a sweep that throws on
      // one tournament must not be stopped from settling the others.
      if (!Array.isArray(rounds) || rounds.length === 0) continue;
      const roundPos = rounds.length - 1;
      const round = rounds[roundPos];
      if (!round || !Array.isArray(round.matchups)) continue;
      if (!round.windowEndMs || nowMs <= round.windowEndMs) continue;
      if (round.matchups.every(isSettled)) continue;

      // Who actually turned up, read from the real match documents.
      const arrivals = await Promise.all(round.matchups.map(async (m, i) => {
        if (isSettled(m)) return null;
        const matchSnap = await db.collection("matches")
            .doc(tournamentMatchId(doc.id, round.roundNumber, i)).get();
        const arrived = matchSnap.exists ? (matchSnap.data().arrivedAt ?? {}) : {};
        return {
          player1Arrived: Boolean(m.player1Id && arrived[m.player1Id]),
          player2Arrived: Boolean(m.player2Id && arrived[m.player2Id]),
        };
      }));

      let next = rounds;
      let settledAny = false;
      for (let i = 0; i < round.matchups.length; i++) {
        if (!arrivals[i]) continue;
        const outcome = forfeitOutcome(round.matchups[i], arrivals[i]);
        if (!outcome) continue;
        settledAny = true;

        if (outcome.winnerId) {
          // Routed through the same function real results use, so a
          // forfeit and a played win advance a bracket identically.
          const applied = applyResultToBracket(next, {
            roundNumber: round.roundNumber,
            matchupIndex: i,
            winnerId: outcome.winnerId,
          });
          if (applied.changed) next = applied.rounds;
        } else {
          // Both no-showed: nobody advances out of this slot. Marked dead
          // rather than left open, or the round could never complete.
          next = next.map((r) => ({...r, matchups: [...r.matchups]}));
          next[roundPos].matchups[i] = {
            ...next[roundPos].matchups[i], isDead: true,
            forfeitReason: outcome.reason,
          };
        }
      }
      if (!settledAny) continue;

      // The dead-slot path bypasses applyResultToBracket, so the round may
      // now be complete without anything having advanced it.
      const update = {bracket: {rounds: next}};
      const finalRound = next[next.length - 1];
      if (finalRound.roundNumber === round.roundNumber &&
          finalRound.matchups.every(isSettled)) {
        const winners = finalRound.matchups
            .map((m) => m.winnerId).filter(Boolean);
        if (winners.length === 1) {
          update.status = "completed";
          update.winnerId = winners[0];
        } else if (winners.length === 0) {
          // Everybody in the last round no-showed. Nothing can be
          // salvaged, so it is cancelled rather than left running
          // forever with no possible winner.
          update.status = "cancelled";
          update.cancelledReason = "no-entrants-remaining";
        } else {
          const built = buildNextRound(finalRound.matchups, round.roundNumber + 1);
          next.push(Object.assign(built, roundWindow(nowMs,
              tournament.roundWindowHours)));
        }
      }
      await doc.ref.update(update);
      results.push({tournamentId: doc.id, status: update.status ?? "in_progress"});
    } catch (e) {
      console.error(`forfeit sweep for ${doc.id} failed:`, e.message);
    }
  }
  return {swept: results.length, results};
}

module.exports = {
  startTournamentMatch,
  sweepTournamentForfeits,
  tournamentMatchId,
  roundWindow,
  forfeitOutcome,
  currentMatchupFor,
  playability,
  DEFAULT_ROUND_WINDOW_HOURS,
  ROUND_WINDOW_LIMITS,
};
