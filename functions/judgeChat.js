const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");
const {messageProblem, rateProblem, nextRate} = require("./lobby");

/**
 * The Main Stage JUDGES' chat - the panel's private green room, before, during
 * and after the battle.
 *
 * It is a DELIBERATE, NARROW instance of the same exception the Daily Gauntlet
 * lobby chat opened to the otherwise-firm "no comment sections" welfare rule
 * (see CLAUDE.md App Store Compliance + the no-comments-protect-roasters
 * memory), and a safer one: it is GROUP (the ~5 seated judges only), PRIVATE
 * (firestore.rules lets only a seated judge of this tournament even READ it),
 * MODERATED (reuses the username hate/slur filter - blocks bigotry, allows edgy
 * comedy), RATE-LIMITED, and EPHEMERAL (wiped with the rest of the tournament's
 * chat rooms when it ends - see lobby.js purgeLobby). It is the panel
 * deliberating among themselves, NOT public text pinned on a roaster's face.
 *
 * Clients READ the chat directly (a cheap listener, judges-only per the rules);
 * they may only WRITE through this callable (rules deny client writes to
 * judgeChat / judgeRate), so the seated-judge gate + moderation can't be
 * skipped.
 */

async function postJudgeChatMessage(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const tournamentId = String((data && data.tournamentId) || "");
  const text = String((data && data.text) || "");
  if (!tournamentId) {
    throw new HttpsError("invalid-argument", "Missing tournament.");
  }
  // Cheap content/shape check (no Firestore) first - reuses the lobby filter.
  const problem = messageProblem(text);
  if (problem) throw new HttpsError("invalid-argument", problem);

  const db = getFirestore();
  const nowMs = Date.now();

  const userSnap = await db.collection("users").doc(auth.uid).get();
  const user = userSnap.data() || {};
  if ((user.accountStatus || "active") !== "active") {
    throw new HttpsError("permission-denied", "This account can't post.");
  }
  const username = user.username || "Judge";

  const tRef = db.collection("tournaments").doc(tournamentId);
  const rateRef = tRef.collection("judgeRate").doc(auth.uid);
  const msgRef = tRef.collection("judgeChat").doc();

  await db.runTransaction(async (tx) => {
    const [tSnap, rateSnap] = await Promise.all([tx.get(tRef), tx.get(rateRef)]);
    const t = tSnap.data();
    if (!t || t.format !== "mainstage") {
      throw new HttpsError("not-found", "No such Main Stage.");
    }
    // Only seated judges may post. The panel is a trusted handful, and keeping
    // the room to them is what makes it a private deliberation rather than a
    // comment section.
    const panel = Array.isArray(t.judges) ? t.judges : [];
    if (!panel.includes(auth.uid)) {
      throw new HttpsError("permission-denied", "Only seated judges can post here.");
    }
    if (t.status === "completed" || t.status === "cancelled") {
      throw new HttpsError("failed-precondition", "This Main Stage has ended.");
    }
    const rp = rateProblem(rateSnap.data(), nowMs);
    if (rp) throw new HttpsError("resource-exhausted", rp);
    tx.set(rateRef, nextRate(rateSnap.data(), nowMs));
    tx.set(msgRef, {
      uid: auth.uid,
      username,
      text: text.trim(),
      createdAt: FieldValue.serverTimestamp(),
    });
  });

  return {ok: true, messageId: msgRef.id};
}

module.exports = {postJudgeChatMessage};
