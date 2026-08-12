const {getFirestore} = require("firebase-admin/firestore");
const {
  STARTING_RATING,
  GOAT_TITLE,
  GOAT_POOL_SIZE,
  GOAT_ELIGIBLE_MIN_MATCHES,
  applyEloChange,
  computeBaseRankTitle,
} = require("./rating");

const VOTE_WINDOW_MS = 24 * 60 * 60 * 1000;

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

  if (match.mode === "exhibition") {
    // Exhibition matches never affect rating (see CLAUDE.md's Match
    // structure notes) - mark finalized so the scheduled sweep stops
    // reconsidering it, but there's nothing to tally.
    await matchRef.update({voteFinalized: true, winnerId: null});
    return {skipped: "exhibition"};
  }

  const createdAtMs = match.createdAt?.toMillis?.() ?? 0;
  const windowClosed = Date.now() - createdAtMs > VOTE_WINDOW_MS;
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

    if (winnerId === match.player1Id) {
      p1NewRating = applyEloChange(p1Rating, p2Rating, 1);
      p2NewRating = applyEloChange(p2Rating, p1Rating, 0);
      p1Wins += 1;
      p2Losses += 1;
    } else if (winnerId === match.player2Id) {
      p2NewRating = applyEloChange(p2Rating, p1Rating, 1);
      p1NewRating = applyEloChange(p1Rating, p2Rating, 0);
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
    tx.update(matchRef, {
      voteFinalized: true,
      winnerId,
      player1FinalWeight: player1Weight,
      player2FinalWeight: player2Weight,
    });
  });

  await syncGoatTier();
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
  for (const doc of currentGoatSnap.docs) {
    if (!newGoatIds.has(doc.id)) {
      const data = doc.data();
      batch.update(doc.ref, {
        rankTitle: computeBaseRankTitle(data.rating ?? STARTING_RATING, data.rankedMatchesPlayed ?? 0),
      });
      dirty = true;
    }
  }

  if (dirty) await batch.commit();
}

module.exports = {finalizeMatch, syncGoatTier, VOTE_WINDOW_MS};
