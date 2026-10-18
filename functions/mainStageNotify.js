const {getFirestore} = require("firebase-admin/firestore");

/**
 * Main Stage "carry them to the stage" pushes. The show is live and
 * time-sensitive, so the key people - finalists and judges - must be pulled in
 * even when the app is closed or they're on another screen (the in-app banner
 * only reaches an open app). Three moments:
 *   1. the show goes live        -> finalists + judges
 *   2. the final becomes ready   -> the two finalists ("you're in the final")
 *   3. a battle goes on stage    -> the judges ("cast your verdict")
 *
 * All best-effort (a failed push never breaks the lifecycle) and deduped via a
 * claimed `msNotified.<key>` flag on the tournament doc, so an at-least-once
 * trigger re-fire never double-pushes (which is how an app earns an OS mute).
 */

function judgesOf(doc) {
  const hp = Array.isArray(doc.handPickedJudges) ? doc.handPickedJudges : [];
  const jp = Array.isArray(doc.judgePool) ? doc.judgePool : [];
  return [...new Set([...hp, ...jp])];
}

function finalistsOf(doc) {
  const f = Array.isArray(doc.field) && doc.field.length ?
    doc.field : (Array.isArray(doc.finalists) ? doc.finalists : []);
  return [...new Set(f)].filter(Boolean);
}

/** Claim a dedup key on the tournament doc; true only if WE claimed it. */
async function claim(db, ref, key) {
  return db.runTransaction(async (tx) => {
    const d = (await tx.get(ref)).data();
    if (!d) return false;
    if ((d.msNotified || {})[key]) return false;
    tx.update(ref, {[`msNotified.${key}`]: true});
    return true;
  }).catch(() => false);
}

async function send(uids, title, body, tournamentId) {
  const recips = [...new Set(uids)].filter(Boolean);
  if (!recips.length) return;
  try {
    const {sendToUsers} = require("./notifications");
    await sendToUsers(recips, {
      category: "main_stage", title, body,
      data: {kind: "main_stage", tournamentId},
    });
  } catch (e) {
    console.error("main_stage push failed:", e.message);
  }
}

/** The show just went live (the #1's callout built the bracket). */
async function notifyShowLive(tournamentId, doc) {
  const db = getFirestore();
  const ref = db.collection("tournaments").doc(tournamentId);
  if (!(await claim(db, ref, "showLive"))) return;
  await send([...finalistsOf(doc), ...judgesOf(doc)],
      "The Main Stage is starting",
      "The finals are live now - get in.", tournamentId);
}

/** The FINAL matchup just became ready (both semis done): tell the finalists. */
async function notifyFinalReady(tournamentId, doc) {
  const rounds = doc?.bracket?.rounds;
  if (!Array.isArray(rounds) || rounds.length === 0) return;
  const finalMatch = rounds[rounds.length - 1]?.matches?.[0];
  if (!finalMatch) return;
  const {a, b, winner, matchId} = finalMatch;
  // Ready = both players known, not yet started, not yet decided.
  if (!a || !b || winner || (typeof matchId === "string" && matchId)) return;
  const db = getFirestore();
  const ref = db.collection("tournaments").doc(tournamentId);
  if (!(await claim(db, ref, "finalReady"))) return;
  await send([a, b], "You're in the FINAL",
      "Both semis are done - step on stage for the final.", tournamentId);
}

/** A battle went on stage: pull the judges in to judge it. */
async function notifyBattleOnStage(tournamentId, matchId) {
  if (!matchId) return;
  const db = getFirestore();
  const ref = db.collection("tournaments").doc(tournamentId);
  if (!(await claim(db, ref, `stage_${matchId}`))) return;
  const doc = (await ref.get()).data();
  if (!doc) return;
  await send(judgesOf(doc), "A Main Stage battle is live",
      "Watch and cast your verdict.", tournamentId);
}

module.exports = {
  notifyShowLive, notifyFinalReady, notifyBattleOnStage,
  judgesOf, finalistsOf,
};
