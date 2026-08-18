const {getFirestore} = require("firebase-admin/firestore");
const {finalizeMatch, VOTE_WINDOW_MS} = require("./matchFinalization");

/**
 * Settles every match whose voting window has closed.
 *
 * THIS IS THE PRODUCTION PATH THAT SETTLES EVERY RANKED MATCH - no
 * rating moves, no result is recorded and no voting window ever actually
 * closes without it.
 *
 * IT LIVED INLINE IN index.js AND WAS THEREFORE UNTESTABLE, which is not
 * a stylistic complaint. It threw on every single run for the entire life
 * of the project because its query needed a composite index that was
 * never declared; the error was swallowed by the scheduler's own
 * try/catch, so the deploy was green, the schedule fired, and nothing
 * happened. The scan built specifically to catch that class of failure
 * could not see this job, because a scan can only invoke something it can
 * require. Extracted so it can be RUN rather than merely deployed.
 */
async function sweepExpiredMatches({now = Date.now()} = {}) {
  const db = getFirestore();

  // Still queried on createdAt even though the window is measured from
  // completedAt. Deliberate and correct: completedAt is always >=
  // createdAt, so this is a strict SUPERSET of the matches whose window
  // has actually closed. finalizeMatch re-checks the real window itself
  // and returns "window-open" for anything caught early, which the next
  // run picks up again. Keeping the query on createdAt avoids a second
  // composite index and avoids missing abandoned matches entirely, which
  // never get a completedAt at all.
  const cutoff = new Date(now - VOTE_WINDOW_MS);
  const snap = await db
      .collection("matches")
      .where("createdAt", "<=", cutoff)
      .where("voteFinalized", "==", false)
      .get();

  const finalized = [];
  const stillOpen = [];
  const failed = [];

  for (const doc of snap.docs) {
    try {
      const result = await finalizeMatch(doc.id);
      if (result?.status === "window-open") stillOpen.push(doc.id);
      else finalized.push(doc.id);
    } catch (e) {
      // One bad match must never stop the others being settled.
      failed.push({matchId: doc.id, error: e.message});
      console.error(`sweepExpiredMatches: ${doc.id} failed`, e);
    }
  }

  return {
    examined: snap.size,
    finalized: finalized.length,
    stillOpen: stillOpen.length,
    failed,
  };
}

module.exports = {sweepExpiredMatches};
