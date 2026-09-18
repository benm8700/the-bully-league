const {getFirestore} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");

/**
 * The Funniest Rounds board: completed battles ranked by how many judges
 * marked one of their rounds the funniest.
 *
 * A CONTENT board - a hall of fame for moments - NOT a second skill ladder.
 * It never touches rating or the rank titles (that would break the
 * one-status-ladder rule). The signal is the optional per-ballot "funniest
 * round" mark, aggregated at finalize into `funniestRoundVotes` on the match,
 * and is deliberately separate from who WON a round.
 *
 * Ordered by `funniestRoundVotes` (a single-field range+order, no composite
 * index needed). voteFinalized is filtered in code to avoid a composite.
 */
async function getFunniestRounds(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const {clipUrl} = require("./watchFeed");
  const db = getFirestore();
  const limit = Math.min(30, Math.max(1, Number(data && data.limit) || 20));

  const snap = await db.collection("matches")
      .where("funniestRoundVotes", ">", 0)
      .orderBy("funniestRoundVotes", "desc")
      .limit(limit)
      .get();

  const rounds = [];
  for (const doc of snap.docs) {
    const m = doc.data();
    // Only finalized, watchable battles reach the board.
    if (m.voteFinalized !== true) continue;
    const url = await clipUrl(m);
    const [p1, p2] = await Promise.all([
      db.collection("users").doc(m.player1Id).get(),
      db.collection("users").doc(m.player2Id).get(),
    ]);
    // The clip window for the winning round, when the match recorded its
    // per-round boundaries (host-captured at match time). Lets the client
    // play ONLY that round rather than the whole battle. Null for matches
    // played before boundaries existed - the client then falls back to the
    // full clip, which is the honest degradation.
    const roundIdx = Number.isInteger(m.funniestRound) ? m.funniestRound : null;
    const b = (roundIdx !== null && Array.isArray(m.roundBoundaries)) ?
      m.roundBoundaries.find((x) => x && x.round === roundIdx) : null;
    rounds.push({
      matchId: doc.id,
      round: roundIdx,
      votes: m.funniestRoundVotes || 0,
      player1Username: (p1.data() && p1.data().username) || "Unknown",
      player2Username: (p2.data() && p2.data().username) || "Unknown",
      videoUrl: url,
      roundCount: (m.settings && m.settings.roundCount) || 3,
      startMs: b ? b.startMs : null,
      endMs: b ? b.endMs : null,
    });
  }
  return {rounds};
}

module.exports = {getFunniestRounds};
