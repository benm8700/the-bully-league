const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");

/**
 * The Main Stage FINALE celebration - the "glory" moment when the weekly finals
 * crown a champion.
 *
 * When a Main Stage tournament completes, both finalists earn a one-shot popup
 * the next time they open the app: a gold "you won the tournament" moment for
 * the champion, and a distinct silver "second place" moment for the runner-up
 * (the loser of the final). The runner-up also gets a permanent `Runner-Up`
 * award badge, via the server-only `tournamentRunnerUps` counter - the mirror
 * of the champion's `tournamentWins` (see belt.js).
 *
 * Scoped to `format === "mainstage"`: the nightly gauntlet already has the belt
 * and the champion badge, but "a final with two named finalists" is a clean,
 * meaningful second-place concept only the bracketed finals have. Other formats
 * (swiss/climb) crown a champion with no single opposite number.
 *
 * The finale is a DISCRETE event, not a crossing, so unlike the fame-milestone
 * popup (a "seen marker") this writes a `pendingTournamentFinale` payload that
 * getPendingTournamentFinale returns once and DELETES - fire-and-clear.
 */

/**
 * PURE. The runner-up of a completed Main Stage bracket = the loser of the
 * final. Tolerant of both bracket storage shapes: the lifecycle stores each
 * round as `{matches:[...]}` (Firestore cannot hold an array directly inside an
 * array), while the pure core returns a raw `[...]`. Returns null if the final
 * is not a clean two-finalist match won by `winnerId`.
 */
function runnerUpOf(after) {
  const b = after && after.bracket;
  const champion = after && after.winnerId;
  if (!b || !champion || !Array.isArray(b.rounds) || b.rounds.length === 0) {
    return null;
  }
  const lastRound = b.rounds[b.rounds.length - 1];
  const matches = Array.isArray(lastRound) ? lastRound :
    (lastRound && Array.isArray(lastRound.matches) ? lastRound.matches : null);
  const fm = matches && matches[0];
  if (!fm || fm.a == null || fm.b == null) return null;
  if (fm.a !== champion && fm.b !== champion) return null; // champion not in it
  return fm.a === champion ? fm.b : fm.a;
}

/**
 * Record the finale for a just-completed Main Stage tournament: stamp the
 * pending celebration on both finalists and bump the runner-up's lifetime
 * counter. Best-effort and idempotent via a `finaleRecorded` flag on the
 * tournament doc, claimed in the same transaction (the re-fire the flag write
 * causes returns early because the flag is already set).
 */
async function recordMainStageFinale(db, tournamentId, after, nowMs = Date.now()) {
  if (!after || after.format !== "mainstage") {
    return {recorded: false, reason: "not-mainstage"};
  }
  const champion = after.winnerId;
  if (!champion) return {recorded: false, reason: "no-winner"};
  const runnerUp = runnerUpOf(after);
  const name = after.name || "the Main Stage";

  const tRef = db.collection("tournaments").doc(tournamentId);
  const champRef = db.collection("users").doc(champion);
  const runnerRef = runnerUp ? db.collection("users").doc(runnerUp) : null;

  return db.runTransaction(async (tx) => {
    const tSnap = await tx.get(tRef);
    if (!tSnap.exists) return {recorded: false, reason: "gone"};
    if (tSnap.data().finaleRecorded === true) {
      return {recorded: false, reason: "already"};
    }
    // All reads before any writes (Firestore transaction rule).
    const champSnap = await tx.get(champRef);
    const runnerSnap = runnerRef ? await tx.get(runnerRef) : null;

    if (champSnap.exists) {
      tx.update(champRef, {
        pendingTournamentFinale: {place: 1, tournamentId, name, at: nowMs},
      });
    }
    if (runnerRef && runnerSnap && runnerSnap.exists) {
      tx.update(runnerRef, {
        pendingTournamentFinale: {place: 2, tournamentId, name, at: nowMs},
        tournamentRunnerUps: FieldValue.increment(1),
      });
    }
    tx.update(tRef, {finaleRecorded: true});
    return {recorded: true, champion, runnerUp: runnerUp || null};
  });
}

/**
 * The pending finale celebration for the caller, cleared on read so it fires
 * exactly once. Returns {finale: null} when there is nothing to show.
 */
async function getPendingTournamentFinale(auth) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const db = getFirestore();
  const ref = db.collection("users").doc(auth.uid);
  const snap = await ref.get();
  const p = (snap.data() || {}).pendingTournamentFinale;
  if (!p || (p.place !== 1 && p.place !== 2)) return {finale: null};
  // Clear BEFORE returning so a celebration never replays on every launch.
  await ref.update({pendingTournamentFinale: FieldValue.delete()});
  return {
    finale: {
      place: p.place,
      name: p.name || null,
      tournamentId: p.tournamentId || null,
    },
  };
}

module.exports = {
  runnerUpOf,
  recordMainStageFinale,
  getPendingTournamentFinale,
};
