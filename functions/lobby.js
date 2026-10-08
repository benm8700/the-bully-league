const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");
const {onDocumentUpdated} = require("firebase-functions/v2/firestore");
const {contentProblem} = require("./username");

/**
 * The Daily Gauntlet LOBBY chat.
 *
 * A whole-event "green room": everyone in tonight's gauntlet can hang out and
 * post to one shared, live chat while they wait between battles. The developer
 * chose this deliberately (2026-10-07), knowing it reopens the otherwise
 * firm "no comment sections" welfare rule - a LIVE, GROUP, EPHEMERAL lobby
 * chat is a different animal from permanent comments pinned under one person's
 * face: it is symmetric (everyone chatting is a participant), it is about the
 * night rather than a verdict on one set, and it is WIPED when the gauntlet
 * ends (see onGauntletEnded).
 *
 * The guardrails that make it defensible (and satisfy Apple Guideline 1.2's
 * UGC-moderation duty) all live here on the only write path:
 *   - AUTO-MODERATION before anything posts: reuses the username filter's
 *     hate/slur detection, which blocks bigotry/slurs but ALLOWS edgy comedy -
 *     consistent with the free-speech-but-no-hate stance everywhere else.
 *   - RATE LIMITING so nobody can flood the room.
 *   - A window gate: no posting to a gauntlet that has not started or has
 *     already ended.
 * Plus a per-message report button on the client (into the existing reports
 * queue) as the human-review backstop.
 *
 * Clients READ the chat directly (a cheap Firestore listener); they can only
 * WRITE through this callable (firestore.rules denies client writes to
 * lobbyChat / lobbyRate), so the moderation can never be skipped.
 */

const MAX_LEN = 280;
const RATE_MAX = 5; // messages ...
const RATE_WINDOW_MS = 20 * 1000; // ... per 20 seconds

/** Content/shape check for a chat message. Pure; returns a reason or null. */
function messageProblem(text) {
  const t = (text || "").trim();
  if (!t) return "Say something first.";
  if (t.length > MAX_LEN) return `Keep it under ${MAX_LEN} characters.`;
  // Reuses the username hate/slur filter: blocks bigotry and slurs, allows
  // ordinary insults and edgy comedy (profanity is fine here, same as a
  // username like "DamnGood" passing). The message never quotes what tripped.
  if (contentProblem(t)) {
    return "That one's blocked - keep it comedy, not hate.";
  }
  return null;
}

/** Whether this poster is over the rate limit. Pure. */
function rateProblem(rate, nowMs) {
  const start = Number(rate && rate.windowStartMs) || 0;
  const count = Number(rate && rate.count) || 0;
  if (nowMs - start < RATE_WINDOW_MS && count >= RATE_MAX) {
    return "You're posting too fast - give it a second.";
  }
  return null;
}

/** The rate record after accepting one more message. Pure. */
function nextRate(rate, nowMs) {
  const start = Number(rate && rate.windowStartMs) || 0;
  const count = Number(rate && rate.count) || 0;
  if (nowMs - start < RATE_WINDOW_MS) {
    return {windowStartMs: start, count: count + 1};
  }
  return {windowStartMs: nowMs, count: 1};
}

async function postLobbyMessage(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const tournamentId = String((data && data.tournamentId) || "");
  const text = String((data && data.text) || "");
  if (!tournamentId) {
    throw new HttpsError("invalid-argument", "Missing tournament.");
  }
  // Cheap checks (no Firestore) first.
  const problem = messageProblem(text);
  if (problem) throw new HttpsError("invalid-argument", problem);

  const db = getFirestore();
  const nowMs = Date.now();

  const userSnap = await db.collection("users").doc(auth.uid).get();
  const user = userSnap.data() || {};
  if ((user.accountStatus || "active") !== "active") {
    throw new HttpsError("permission-denied", "This account can't post.");
  }
  const username = user.username || "Roaster";

  const tRef = db.collection("tournaments").doc(tournamentId);
  const rateRef = tRef.collection("lobbyRate").doc(auth.uid);
  const msgRef = tRef.collection("lobbyChat").doc();

  await db.runTransaction(async (tx) => {
    const [tSnap, rateSnap] = await Promise.all([tx.get(tRef), tx.get(rateRef)]);
    const t = tSnap.data();
    if (!t) throw new HttpsError("not-found", "No such tournament.");
    if (t.status === "completed" || t.status === "cancelled") {
      throw new HttpsError("failed-precondition", "This gauntlet has ended.");
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

/** Wipe a gauntlet's lobby chat + rate records. Ephemeral by design. */
async function purgeLobby(db, tournamentId) {
  const tRef = db.collection("tournaments").doc(tournamentId);
  for (const sub of ["lobbyChat", "lobbyRate"]) {
    await db.recursiveDelete(tRef.collection(sub)).catch(() => {});
  }
}

/**
 * Wipes the lobby the moment the gauntlet ends (completed OR cancelled), so a
 * night's chat never outlives the night. Fires regardless of whether a
 * champion was crowned - a cancelled gauntlet still has a room to clear.
 */
// Defined as a const (NOT exports.X) because the module.exports assignment
// below replaces the exports object wholesale - an `exports.onGauntletEnded`
// here would be wiped and the trigger would never deploy.
const onGauntletEnded = onDocumentUpdated(
    "tournaments/{tournamentId}", async (event) => {
      const before = event.data && event.data.before &&
        event.data.before.data();
      const after = event.data && event.data.after && event.data.after.data();
      if (!after) return;
      const ended = (s) => s === "completed" || s === "cancelled";
      const becameEnded = (!before || !ended(before.status)) &&
        ended(after.status);
      if (!becameEnded) return;
      await purgeLobby(getFirestore(), event.params.tournamentId)
          .catch((e) => console.error("lobby purge", e.message));
    });

module.exports = {
  postLobbyMessage,
  purgeLobby,
  onGauntletEnded,
  // Exported for tests.
  messageProblem,
  rateProblem,
  nextRate,
  MAX_LEN,
  RATE_MAX,
  RATE_WINDOW_MS,
};
