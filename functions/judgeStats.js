const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");

/**
 * "You agreed with the crowd on 34 of 40 battles."
 *
 * Recorded when someone CALLS a settled battle in the feed - a private
 * guess against a result already decided, not a ballot. Voting on a closed
 * match stays impossible; nothing here touches anyone's rating.
 *
 * WHY THIS IS WORTH STORING. It is the natural backbone for the Judge
 * progression track: agreement with the crowd over many battles is a far
 * better basis for judge ranking than raw vote count, which only measures
 * how much someone tapped. It is also earned passively, just by watching -
 * which is exactly the behaviour worth rewarding in an app whose scarce
 * resource is people willing to judge.
 *
 * SERVER-SIDE, and that matters. The counters feed a prestige ladder, so a
 * client able to write them directly could simply declare itself an
 * infallible judge. Every call is checked against the match's actual
 * recorded winner here, and firestore.rules denies the client any write to
 * the field.
 *
 * BATCHED, because a call happens on every archive clip someone scrolls
 * past. One invocation per clip would put a function call behind every
 * swipe; the client accumulates and flushes instead.
 */

/** Ceiling on one flush. Bounds the reads a single call can cost, and no
 * honest client accumulates more than this between flushes. */
const MAX_CALLS_PER_FLUSH = 25;

/**
 * Scores calls against the recorded results.
 *
 * Pure and exported so the scoring is testable without Firestore. Anything
 * unresolvable - a match that never settled, a tie, a pick naming neither
 * player - is DROPPED rather than counted as wrong: a judge should not be
 * marked down for a battle that had no answer.
 */
function scoreCalls(calls, matchesById) {
  let total = 0;
  let correct = 0;
  const seen = new Set();
  for (const call of calls) {
    const match = matchesById.get(call?.matchId);
    if (!match) continue;
    // One call per match, however many times a client sends it - otherwise
    // a replayed flush inflates the record.
    if (seen.has(call.matchId)) continue;
    if (match.voteFinalized !== true) continue;
    // A tie has no right answer, so calling it is neither right nor wrong.
    if (!match.winnerId) continue;
    if (call.chosenPlayerId !== match.player1Id &&
        call.chosenPlayerId !== match.player2Id) continue;
    seen.add(call.matchId);
    total += 1;
    if (call.chosenPlayerId === match.winnerId) correct += 1;
  }
  return {total, correct};
}

async function recordCalls(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const calls = Array.isArray(data?.calls) ? data.calls : [];
  if (calls.length === 0) return {recorded: 0};
  if (calls.length > MAX_CALLS_PER_FLUSH) {
    throw new HttpsError("invalid-argument",
        `At most ${MAX_CALLS_PER_FLUSH} calls per flush.`);
  }

  const db = getFirestore();
  const ids = [...new Set(calls.map((c) => c?.matchId).filter(Boolean))];
  const snaps = await db.getAll(
      ...ids.map((id) => db.collection("matches").doc(id)));
  const matchesById = new Map();
  for (const snap of snaps) {
    if (snap.exists) matchesById.set(snap.id, snap.data());
  }

  const {total, correct} = scoreCalls(calls, matchesById);
  if (total === 0) return {recorded: 0};

  await db.collection("users").doc(auth.uid).set({
    judgeCalls: {
      total: FieldValue.increment(total),
      correct: FieldValue.increment(correct),
    },
  }, {merge: true});

  return {recorded: total, correct};
}

module.exports = {recordCalls, scoreCalls, MAX_CALLS_PER_FLUSH};
