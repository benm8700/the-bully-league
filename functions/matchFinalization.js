const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {
  STARTING_RATING,
  GOAT_TITLE,
  GOAT_POOL_SIZE,
  GOAT_ELIGIBLE_MIN_MATCHES,
  applyEloChange,
  computeBaseRankTitle,
  voteConfidence,
} = require("./rating");

const VOTE_WINDOW_MS = 24 * 60 * 60 * 1000;

/**
 * When a match's 24-hour voting window starts.
 *
 * Completion, not pairing. Match documents are created at PAIRING time
 * (functions/matchmaking.js), and the gap between pairing and the final
 * verdict is real - a bio reveal of up to a minute, then several rounds.
 * Measuring from creation silently shortened every match's voting window
 * by however long the match itself took, and a match that sat pending
 * while players sorted out a camera permission could lose a large slice of
 * it. Nobody would see an error; the match would just close early with
 * fewer ballots, which under confidence weighting now also means it moves
 * rating less. A quiet unfairness is the worst kind.
 *
 * Falls back to createdAt when there is no completedAt, which is exactly
 * the abandoned-match case: nothing ever completed it, so pairing time is
 * the only sensible clock, and that preserves the hourly sweep's existing
 * behaviour of settling long-dead pending matches.
 */
function voteWindowStartMs(match) {
  return match?.completedAt?.toMillis?.() ?? match?.createdAt?.toMillis?.() ?? 0;
}

/** When voting closes. Single source of truth - the client shows this
 * countdown, castVote enforces it, and finalizeMatch acts on it, so they
 * must not drift apart. */
function voteWindowEndMs(match) {
  return voteWindowStartMs(match) + VOTE_WINDOW_MS;
}

/**
 * Tallies a match's ballots, determines the winner (or tie), and applies
 * Elo rating changes - see CLAUDE.md's Ranking System + Judging sections.
 * `force` bypasses the 24h window check, for the debugFinalizeMatch test
 * trigger only (see index.js) - production finalization always waits for
 * the real window via the scheduled trigger.
 */
async function finalizeMatch(matchId, {force = false} = {}) {
  const db = getFirestore();
  const matchRef = db.collection("matches").doc(matchId);
  const matchSnap = await matchRef.get();
  if (!matchSnap.exists) {
    return {error: "not-found"};
  }
  const match = matchSnap.data();
  if (match.voteFinalized) {
    return {skipped: "already-finalized"};
  }

  // Match documents are created at pairing time now (functions/
  // matchmaking.js), so the hourly sweep also turns up matches that were
  // never played to a verdict - a client crash, a force-quit, a
  // content-violation auto-end. The sweep only looks at documents older
  // than the full 24h vote window, so anything still "pending" by then is
  // genuinely abandoned rather than in progress. Settle it with no winner
  // and no rating change so it stops being reconsidered every hour.
  if (match.status !== "completed") {
    await matchRef.update({voteFinalized: true, winnerId: null, status: "abandoned"});
    return {skipped: "not-completed"};
  }

  if (match.mode === "exhibition") {
    // Exhibition matches never affect rating (see CLAUDE.md's Match
    // structure notes) - mark finalized so the scheduled sweep stops
    // reconsidering it, but there's nothing to tally.
    await matchRef.update({voteFinalized: true, winnerId: null});
    return {skipped: "exhibition"};
  }

  const windowClosed = Date.now() > voteWindowEndMs(match);
  if (!windowClosed && !force) {
    return {skipped: "window-open"};
  }

  const ballotsSnap = await db.collection("votes").doc(matchId).collection("ballots").get();
  let player1Weight = 0;
  let player2Weight = 0;
  for (const doc of ballotsSnap.docs) {
    const data = doc.data();
    const weight = data.weight ?? 1;
    if (data.votedForPlayerId === match.player1Id) player1Weight += weight;
    else if (data.votedForPlayerId === match.player2Id) player2Weight += weight;
  }

  let winnerId = null;
  if (player1Weight > player2Weight) winnerId = match.player1Id;
  else if (player2Weight > player1Weight) winnerId = match.player2Id;
  // else: tie - winnerId stays null, no rating change for either player
  // (CLAUDE.md's Tie votes decision - NOT the standard Elo 0.5/0.5 treatment).

  // A FRIEND BATTLE GETS A REAL VERDICT AND NOTHING ELSE.
  //
  // It is voted on and recorded like any other battle, because external
  // judgement is the entire reason to use this app instead of a video
  // call - but it moves no rating and pays no points, and both of those
  // omissions are deliberate rather than unfinished.
  //
  // Rating: CLAUDE.md's explicit constraint. You choose your opponent, so
  // counting it would open the collusion door the whole ranked design
  // works to keep shut - two friends trading wins is a ladder.
  //
  // Points: the same argument, one step along. Ranked participation pays
  // because you cannot choose who you meet and a cooldown stops you
  // meeting them twice. Here you can pick the same person all evening, so
  // paying per match would be a straight farm. What you get instead is the
  // clip and the crowd's verdict, which is what the feature is for.
  if (match.mode === "friend") {
    await matchRef.update({
      voteFinalized: true,
      winnerId,
      voteConfidence: voteConfidence(
          player1Weight + player2Weight, match.settings?.fullConfidenceVotes),
      player1FinalWeight: player1Weight,
      player2FinalWeight: player2Weight,
    });
    return {skipped: "friend", winnerId};
  }

  const player1Ref = db.collection("users").doc(match.player1Id);
  const player2Ref = db.collection("users").doc(match.player2Id);

  await db.runTransaction(async (tx) => {
    const [p1Snap, p2Snap] = await Promise.all([tx.get(player1Ref), tx.get(player2Ref)]);
    if (!p1Snap.exists || !p2Snap.exists) {
      throw new Error(`Missing user doc for match ${matchId}'s players.`);
    }
    const p1 = p1Snap.data();
    const p2 = p2Snap.data();
    const p1Rating = p1.rating ?? STARTING_RATING;
    const p2Rating = p2.rating ?? STARTING_RATING;

    let p1NewRating = p1Rating;
    let p2NewRating = p2Rating;
    let p1Wins = p1.wins ?? 0;
    let p1Losses = p1.losses ?? 0;
    let p2Wins = p2.wins ?? 0;
    let p2Losses = p2.losses ?? 0;

    // How much this result should move rating, given how many people
    // actually judged it. A match decided by one friendly vote barely
    // moves anything; a well-judged one moves the full amount. See
    // voteConfidence in rating.js for why this is scaled rather than
    // gated behind a minimum vote count.
    // Read from the settings stamped on this match at pairing time, so a
    // match is judged by the rules that were in force when it was played
    // rather than by whatever the config says a day later. Falls back to
    // the default for matches recorded before this was configurable.
    const confidence = voteConfidence(
        player1Weight + player2Weight,
        match.settings?.fullConfidenceVotes,
    );

    if (winnerId === match.player1Id) {
      p1NewRating = applyEloChange(p1Rating, p2Rating, 1, confidence);
      p2NewRating = applyEloChange(p2Rating, p1Rating, 0, confidence);
      p1Wins += 1;
      p2Losses += 1;
    } else if (winnerId === match.player2Id) {
      p2NewRating = applyEloChange(p2Rating, p1Rating, 1, confidence);
      p1NewRating = applyEloChange(p1Rating, p2Rating, 0, confidence);
      p2Wins += 1;
      p1Losses += 1;
    }

    const p1Matches = (p1.rankedMatchesPlayed ?? 0) + 1;
    const p2Matches = (p2.rankedMatchesPlayed ?? 0) + 1;

    tx.update(player1Ref, {
      rating: p1NewRating,
      wins: p1Wins,
      losses: p1Losses,
      rankedMatchesPlayed: p1Matches,
      rankTitle: computeBaseRankTitle(p1NewRating, p1Matches),
    });
    tx.update(player2Ref, {
      rating: p2NewRating,
      wins: p2Wins,
      losses: p2Losses,
      rankedMatchesPlayed: p2Matches,
      rankTitle: computeBaseRankTitle(p2NewRating, p2Matches),
    });
    // RECORDED HERE, INSIDE THE SAME TRANSACTION, and this is the only
    // chance to do it. A rating update overwrites the previous value, so
    // any history not written at this moment is gone permanently - it can
    // never be backfilled from anything, because nothing else remembers
    // what the rating was before this match.
    //
    // A SUBCOLLECTION rather than an array on the user document: the user
    // doc is read constantly (every entitlement check, every Home load,
    // every matchmaking entry), and an unbounded array of every match a
    // player has ever played would bloat all of them. This is written
    // once and read only when someone actually looks at their history.
    //
    // Keyed by matchId so a retried finalization overwrites rather than
    // duplicating, matching how the points ledger stays idempotent.
    const historyEntry = (before, after, opponentId, won) => ({
      matchId,
      opponentId,
      ratingBefore: before,
      ratingAfter: after,
      delta: after - before,
      won,
      // Stored so a flat result is explicable later - "why did that win
      // barely move me" has an answer in the record itself.
      voteConfidence: confidence,
      mode: match.mode ?? "ranked",
      at: FieldValue.serverTimestamp(),
    });
    tx.set(player1Ref.collection("ratingHistory").doc(matchId),
        historyEntry(p1Rating, p1NewRating, match.player2Id,
            winnerId === match.player1Id));
    tx.set(player2Ref.collection("ratingHistory").doc(matchId),
        historyEntry(p2Rating, p2NewRating, match.player1Id,
            winnerId === match.player2Id));

    tx.update(matchRef, {
      voteFinalized: true,
      winnerId,
      player1FinalWeight: player1Weight,
      player2FinalWeight: player2Weight,
      // Recorded so a thin result is explicable after the fact - "why did
      // that win only move me two points" has an answer on the document.
      voteConfidence: confidence,
    });
  });

  // The win bonus, paid once the crowd has actually decided. Keyed by
  // match, so the hourly sweep re-examining a finalized match cannot pay
  // twice. A tie pays nobody - there is no winner to reward - but both
  // players already collected the participation award on completion, so a
  // drawn battle is never worth nothing.
  if (winnerId) {
    try {
      const {awardPoints, pointsSettings, awardAmount} = require("./points");
      const rates = await pointsSettings();
      const multiplier = match.eventWindow?.qualified === true ?
        rates.eventWindowMultiplier : 1;
      await awardPoints(winnerId, {
        reason: "match_won",
        sourceId: matchId,
        amount: awardAmount(rates.matchWon, {multiplier}),
      });
    } catch (e) {
      console.error(`win points for ${matchId} failed:`, e.message);
    }
    try {
      const {recordQuestEvent} = require("./quests");
      await recordQuestEvent(winnerId, "wins");
    } catch (e) {
      console.error(`quest win event for ${matchId} failed:`, e.message);
    }
  }

  // A tournament match's result belongs to its bracket, not just to the
  // two players' ratings. Without this the only thing that ever advanced
  // a round was debugAdvanceRound's coin flip.
  if (match.mode === "tournament" && winnerId) {
    try {
      const {recordTournamentResult} = require("./tournament");
      const applied = await recordTournamentResult(match, winnerId);
      if (applied.applied) {
        console.log(`tournament advance for ${matchId}:`, JSON.stringify(applied));
      }
    } catch (e) {
      // A bracket an admin can fix beats a finalization that failed after
      // already applying rating changes.
      console.error(`tournament result for ${matchId} failed:`, e.message);
    }
  }

  const goat = await syncGoatTier();

  // Announced AFTER the GOAT sync, so a player who moved up a tier and
  // then into the top five is told about the one promotion they actually
  // experienced rather than being pushed twice.
  //
  // Includes anyone the sync DISPLACED, who may not be in this match at
  // all: a sixth player rising pushes someone out of the top five without
  // them losing anything, and they deserve to hear that honestly.
  try {
    const {notifyRankChanges} = require("./rankChange");
    await notifyRankChanges(
        [match.player1Id, match.player2Id, ...(goat?.displaced ?? [])],
        {displacedFromGoat: goat?.displaced ?? []});
  } catch (e) {
    // Never fail a finalization over an announcement - the rating change
    // is the thing that matters and it has already happened.
    console.error(`rank change notifications for ${matchId} failed:`, e.message);
  }

  return {winnerId, player1Weight, player2Weight};
}

/**
 * GOAT (rank 10) is a live top-5-by-rating leaderboard position, not a
 * fixed threshold - the ONE deliberate exception in CLAUDE.md's tier
 * design. Promoting someone into the top 5 can demote whoever just fell
 * out of it, even though THEY didn't lose - that's intentional per
 * CLAUDE.md ("someone else got better", not "you got worse").
 */
async function syncGoatTier() {
  const db = getFirestore();
  const usersRef = db.collection("users");

  // Firestore can't combine a range filter on one field with orderBy on a
  // different field without a composite index, so fetch a generous top-N
  // by rating and filter for match-count eligibility in memory - fine at
  // V1's user volume.
  const topRatedSnap = await usersRef.orderBy("rating", "desc").limit(50).get();
  const eligible = topRatedSnap.docs
      .filter((d) => (d.data().rankedMatchesPlayed ?? 0) >= GOAT_ELIGIBLE_MIN_MATCHES)
      .slice(0, GOAT_POOL_SIZE);
  const newGoatIds = new Set(eligible.map((d) => d.id));

  const currentGoatSnap = await usersRef.where("rankTitle", "==", GOAT_TITLE).get();

  const batch = db.batch();
  let dirty = false;

  for (const doc of eligible) {
    if (doc.data().rankTitle !== GOAT_TITLE) {
      batch.update(doc.ref, {rankTitle: GOAT_TITLE});
      dirty = true;
    }
  }
  // Collected so the notifier can tell these players the truth - that
  // somebody else got better rather than that they got worse. Without
  // this the only honest message in the whole rank-change set could never
  // actually fire.
  const displaced = [];
  for (const doc of currentGoatSnap.docs) {
    if (!newGoatIds.has(doc.id)) {
      const data = doc.data();
      batch.update(doc.ref, {
        rankTitle: computeBaseRankTitle(data.rating ?? STARTING_RATING, data.rankedMatchesPlayed ?? 0),
      });
      displaced.push(doc.id);
      dirty = true;
    }
  }

  if (dirty) await batch.commit();
  return {displaced};
}

module.exports = {
  finalizeMatch,
  syncGoatTier,
  VOTE_WINDOW_MS,
  voteWindowStartMs,
  voteWindowEndMs,
};
