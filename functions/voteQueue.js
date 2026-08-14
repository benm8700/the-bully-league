const {getFirestore} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");
const {VOTE_WINDOW_MS} = require("./matchFinalization");

/**
 * Serves the matches that most need a vote.
 *
 * This is the liquidity half of the voting-guardrails work. Weighting
 * rating by vote confidence (see rating.js) is only fair if votes are
 * actually gettable - otherwise thin results stop mattering and the ladder
 * simply stops moving, which is the same failure the confidence curve was
 * designed to avoid.
 *
 * ORDERED BY FEWEST VOTES, not by recency. A recency feed sends everyone
 * to the same newest match while older ones close unjudged; ordering by
 * need sends each ballot where it changes an outcome most. It also means
 * one ballot on a zero-vote match is worth far more to the ladder than the
 * eleventh ballot on a popular one.
 *
 * SERVER-SIDE because the "have I already voted on this" check reads the
 * ballots subcollection, which firestore.rules blocks clients from
 * reading - deliberately, since exposing who voted for whom would make
 * vote-brigading trivial to coordinate.
 */

/** How many candidates to examine. Kept modest because each one costs a
 * ballot lookup; the aim is a handful of good suggestions, not a feed. */
const CANDIDATE_LIMIT = 25;
const DEFAULT_RETURN = 3;

/**
 * Whether this user can vote on this match, mirroring castVote's own
 * rules so the queue never offers something that would be refused.
 *
 * Pure and exported so the rules can be tested without Firestore.
 */
function isVotableBy(match, userId, nowMs) {
  if (!match) return false;
  if (match.status !== "completed") return false;
  if (match.voteFinalized === true) return false;
  // Participants can't judge their own match.
  if (userId === match.player1Id || userId === match.player2Id) return false;
  const createdAtMs = match.createdAtMs ?? 0;
  if (nowMs - createdAtMs > VOTE_WINDOW_MS) return false;
  return true;
}

/** Milliseconds left before this match stops accepting votes. */
function msRemaining(match, nowMs) {
  return Math.max(0, (match.createdAtMs ?? 0) + VOTE_WINDOW_MS - nowMs);
}

async function getMatchesNeedingVotes(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const limit = Math.min(10, Math.max(1, Number(data?.limit) || DEFAULT_RETURN));
  const db = getFirestore();
  const nowMs = Date.now();

  const snap = await db
      .collection("matches")
      .where("status", "==", "completed")
      .where("voteFinalized", "==", false)
      .orderBy("voteCount", "asc")
      .limit(CANDIDATE_LIMIT)
      .get();

  const candidates = [];
  for (const doc of snap.docs) {
    const raw = doc.data();
    const match = {...raw, createdAtMs: raw.createdAt?.toMillis?.() ?? 0};
    if (!isVotableBy(match, auth.uid, nowMs)) continue;
    candidates.push({doc, match});
  }

  const results = [];
  for (const {doc, match} of candidates) {
    if (results.length >= limit) break;
    // Only now pay for the ballot lookup, and only for matches that
    // passed every cheaper filter.
    const ballot = await db
        .collection("votes").doc(doc.id)
        .collection("ballots").doc(auth.uid)
        .get();
    if (ballot.exists) continue;

    const [p1, p2] = await Promise.all([
      db.collection("users").doc(match.player1Id).get(),
      db.collection("users").doc(match.player2Id).get(),
    ]);
    results.push({
      matchId: doc.id,
      player1Id: match.player1Id,
      player2Id: match.player2Id,
      // An unresolvable player renders as "Unknown" rather than breaking,
      // which is what happens after an account deletion.
      player1Username: p1.data()?.username ?? "Unknown",
      player2Username: p2.data()?.username ?? "Unknown",
      mode: match.mode ?? "ranked",
      voteCount: match.voteCount ?? 0,
      msRemaining: msRemaining(match, nowMs),
    });
  }

  return {matches: results};
}

module.exports = {getMatchesNeedingVotes, isVotableBy, msRemaining, CANDIDATE_LIMIT};
