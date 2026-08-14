const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {getDatabase} = require("firebase-admin/database");
const {acceptanceExpired, releaseOutcome} = require("./standingChallenge");
const {MODES} = require("./matchmaking");

/**
 * Frees players left waiting on a standing challenge nobody answered.
 *
 * Without this the whole mechanism has a trapdoor: pairing against someone
 * who is asleep creates a real match document, and if they never open the
 * app it sits pending forever. The live player who took up the challenge
 * would be stuck holding a match that can never start, and their queue
 * entry would stay flagged matched - so they could not be paired with
 * anyone else either. One unanswered challenge would quietly remove a
 * willing player from the pool.
 *
 * WHO IS PENALISED: nobody. The challenger is not forfeited for failing to
 * wake up - a forfeit is for accepting and then not turning up, which is a
 * promise broken rather than one never made. Their challenge simply
 * returns to the pool, because being briefly away should not cost someone
 * their place; and the player who did show is put straight back into the
 * queue rather than punished for someone else's absence.
 */
async function releaseUnansweredChallenges(nowMs = Date.now()) {
  const db = getFirestore();
  const rtdb = getDatabase();

  // Only pending matches can be waiting on an acceptance, and there are
  // few of them - anything settled is irrelevant here.
  const snap = await db.collection("matches")
      .where("status", "==", "pending")
      .limit(100)
      .get();

  const released = [];
  for (const doc of snap.docs) {
    const match = doc.data();
    if (!acceptanceExpired(match, nowMs)) continue;

    const {requeue, noShow} = releaseOutcome(match);

    // Settle the match first. Marking it abandoned before touching the
    // queue means a failure part-way through leaves a dead match rather
    // than two players holding a match that no longer exists.
    await doc.ref.update({
      status: "abandoned",
      voteFinalized: true,
      winnerId: null,
      abandonReason: "challenge-unanswered",
    });

    for (const mode of MODES) {
      const queue = rtdb.ref(`matchmakingQueue/${mode}`);
      // The challenger goes back to standing rather than being deleted -
      // one missed push should not cost them their place in the pool.
      if (noShow) {
        const ref = queue.child(noShow);
        const entry = (await ref.get()).val();
        if (entry?.matchId === doc.id) {
          await ref.update({
            status: "standing",
            matchId: null,
            channelName: null,
            opponentId: null,
          });
        }
      }
      // Whoever actually showed up goes back to searching, so they can be
      // paired with someone else immediately.
      if (requeue) {
        const ref = queue.child(requeue);
        const entry = (await ref.get()).val();
        if (entry?.matchId === doc.id) {
          await ref.update({
            status: "waiting",
            joinedAt: nowMs,
            matchId: null,
            channelName: null,
            opponentId: null,
          });
        }
      }
    }

    // Tell the player who was left waiting, so the outcome is visible even
    // if they closed the app. Best-effort.
    try {
      const {sendToUsers} = require("./notifications");
      if (requeue) {
        const user = await db.collection("users").doc(requeue).get();
        if (user.exists) {
          await sendToUsers([user], {
            title: "They didn't answer",
            body: "Your opponent never picked up. You're back in the queue.",
            category: "match_found",
            data: {kind: "challenge_released"},
          });
        }
      }
    } catch (e) {
      console.error(`release notification failed for ${doc.id}:`, e.message);
    }

    released.push(doc.id);
  }

  if (released.length > 0) {
    await db.collection("stats").doc("challenges").set({
      lastReleaseAt: FieldValue.serverTimestamp(),
      lastReleasedCount: released.length,
    }, {merge: true});
  }
  return {released};
}

module.exports = {releaseUnansweredChallenges};
