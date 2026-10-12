const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");
const {
  messageProblem,
  rateProblem,
  nextRate,
} = require("./lobby");
const {qualifyingWeek} = require("./weeklyQualifier");

/**
 * THE MAIN STAGE HUB chat - a weekly lobby for the tournament hub.
 *
 * This is the SAME welfare-bounded animal as the Daily Gauntlet lobby (see
 * lobby.js), reused deliberately: a LIVE, GROUP, MODERATED, RATE-LIMITED,
 * REPORTABLE room - never permanent comments pinned under one roaster's face.
 * It differs only in scope: the room is keyed by the QUALIFYING WEEK rather than
 * a single tournament doc, so it's a standing "this week's" green room that a
 * fresh week replaces automatically (last week's room is simply abandoned -
 * same ephemerality, a week at a time, no wipe job needed). All the guardrails
 * live here on the only write path (clients can't write lobbyRooms/**):
 *   - the hate/slur filter (reused via messageProblem) - blocks bigotry,
 *     allows edgy comedy;
 *   - rate limiting so nobody floods the room;
 *   - a per-message report button on the client as the human-review backstop.
 *
 * Plus ANNOUNCEMENTS: the founder can pin a message (postHubAnnouncement,
 * admin-only). Announcements carry pinned:true and surface above the chat.
 *
 * The room id = qualifyingWeek(now).cutoffDayKey, derived SERVER-SIDE, so the
 * client never chooses which room it writes to. getHubRoom hands the client the
 * current week key so it can read the room (and the judge opt-in's week).
 */

/** The current hub room key (this qualifying week's Thursday). */
function hubWeekKey(nowMs = Date.now()) {
  return qualifyingWeek(nowMs).cutoffDayKey;
}

/** Hand the client the current week key so it can read the chat + judge state.
 * Derived from the clock, independent of the tournament flag, so the hub works
 * before the whole tournament system is switched on. */
async function getHubRoom(auth) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  return {weekKey: hubWeekKey()};
}

async function writeHubMessage(auth, data, {announcement}) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const text = String((data && data.text) || "");
  const problem = messageProblem(text);
  if (problem) throw new HttpsError("invalid-argument", problem);

  const db = getFirestore();
  const nowMs = Date.now();
  const weekKey = hubWeekKey(nowMs);

  const userSnap = await db.collection("users").doc(auth.uid).get();
  const user = userSnap.data() || {};
  if ((user.accountStatus || "active") !== "active") {
    throw new HttpsError("permission-denied", "This account can't post.");
  }
  const username = user.username || "Roaster";

  const roomRef = db.collection("lobbyRooms").doc(weekKey);
  const rateRef = roomRef.collection("rate").doc(auth.uid);
  const msgRef = roomRef.collection("messages").doc();

  // Announcements skip the rate limit (admin-authored, already gated), and are
  // written outside a transaction since there's no rate record to guard.
  if (announcement) {
    await msgRef.set({
      uid: auth.uid,
      username,
      text: text.trim(),
      pinned: true,
      createdAt: FieldValue.serverTimestamp(),
    });
    return {ok: true, messageId: msgRef.id, weekKey};
  }

  await db.runTransaction(async (tx) => {
    const rateSnap = await tx.get(rateRef);
    const rp = rateProblem(rateSnap.data(), nowMs);
    if (rp) throw new HttpsError("resource-exhausted", rp);
    tx.set(rateRef, nextRate(rateSnap.data(), nowMs));
    tx.set(msgRef, {
      uid: auth.uid,
      username,
      text: text.trim(),
      pinned: false,
      createdAt: FieldValue.serverTimestamp(),
    });
  });
  return {ok: true, messageId: msgRef.id, weekKey};
}

/** Post an ordinary chat message to this week's hub lobby. */
function postHubMessage(auth, data) {
  return writeHubMessage(auth, data, {announcement: false});
}

/** Pin an announcement to this week's hub lobby. Admin-only - the caller is
 * checked in index.js (requireAdmin) before this runs. */
function postHubAnnouncement(auth, data) {
  return writeHubMessage(auth, data, {announcement: true});
}

module.exports = {
  getHubRoom,
  postHubMessage,
  postHubAnnouncement,
  hubWeekKey,
};
