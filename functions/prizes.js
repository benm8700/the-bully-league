const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");
const {championOf} = require("./belt");

/**
 * Tournament PRIZES - points (auto-awarded) and non-cash items (recorded for
 * the admin to fulfill by hand). Cash is deliberately NOT auto-processed - it
 * waits on the payment-processor + entity + legal step (see the Prize &
 * Tournament Legal Structure section). Hooked into the same format-agnostic
 * tournament-completion trigger the Belt uses (belt.js), so every format and
 * any future one is covered in one place.
 *
 * Non-cash fulfillment flow: on a win we create a `prizeFulfillments` record
 * (with wonAtMs, so the admin dashboard can show how long a prize has been
 * outstanding), push the winner a "claim it" notification, and ping the
 * admins. The winner submits their shipping details via `submitPrizeClaim`;
 * the admin ships and marks it fulfilled from the dashboard.
 */

/**
 * PURE. What a completed tournament's prize means.
 * Returns {kind}: "points" (+points), "item"/"cash" (+description), or "none".
 */
function prizePlan(t) {
  if (!t) return {kind: "none"};
  const value = Number(t.prizeValue);
  const description = String(t.prizeDescription || t.prizeLabel || "").trim();
  if (t.prizeType === "points") {
    return value > 0 ? {kind: "points", points: value} : {kind: "none"};
  }
  if (t.prizeType === "cash") {
    return {kind: "cash", description: description || `$${value || "?"}`};
  }
  // Any non-cash item / experiential prize is identified by a description.
  if (description) return {kind: "item", description};
  return {kind: "none"};
}

async function notify(uids, payload) {
  try {
    const {sendToUsers} = require("./notifications");
    await sendToUsers(uids, payload);
  } catch (e) {
    console.error("prize notify failed:", e.message);
  }
}

async function notifyAdmins(db, body) {
  try {
    const snap = await db.collection("users")
        .where("isAdmin", "==", true).get();
    const uids = snap.docs.map((d) => d.id);
    if (uids.length) {
      await notify(uids, {
        title: "Prize to fulfill",
        body,
        category: "prize_won",
        data: {type: "admin_prize"},
      });
    }
  } catch (e) {
    console.error("notifyAdmins failed:", e.message);
  }
}

/**
 * Award/record the prize for a just-completed tournament. Idempotent via a
 * `prizeAwarded` flag on the tournament doc (claimed in a transaction, like
 * the belt's `championRecorded`). Best-effort: a failure never blocks the
 * belt or the win record.
 */
async function awardPrizeForTournament(db, tournamentId, t, nowMs = Date.now()) {
  const plan = prizePlan(t);
  if (plan.kind === "none") return {done: false, reason: "no-prize"};
  const winnerUid = championOf(t);
  if (!winnerUid) return {done: false, reason: "no-winner"};

  const tRef = db.collection("tournaments").doc(tournamentId);
  const claimed = await db.runTransaction(async (tx) => {
    const snap = await tx.get(tRef);
    if (!snap.exists || snap.data().prizeAwarded === true) return false;
    tx.update(tRef, {prizeAwarded: true});
    return true;
  });
  if (!claimed) return {done: false, reason: "already"};

  let username = null;
  try {
    const u = await db.collection("users").doc(winnerUid).get();
    username = u.exists ? (u.data().username || null) : null;
  } catch (_) { /* name is a convenience */ }

  if (plan.kind === "points") {
    const {awardPoints} = require("./points");
    await awardPoints(winnerUid, {
      reason: "tournament_prize",
      sourceId: `prize_${tournamentId}`,
      amount: plan.points,
    }).catch((e) => console.error("prize points:", e.message));
    await notify([winnerUid], {
      title: "🏆 Tournament prize",
      body: `You won ${plan.points} points!`,
      category: "prize_won",
      data: {type: "prize_points"},
    });
    return {done: true, kind: "points", points: plan.points};
  }

  // cash or item: a fulfillment record the admin dashboard surfaces. Cash is
  // recorded but flagged - it is NOT auto-paid.
  const ref = await db.collection("prizeFulfillments").add({
    tournamentId,
    tournamentName: t.name || null,
    winnerUid,
    winnerUsername: username,
    prize: plan.description,
    prizeType: plan.kind,
    status: "owed",
    wonAtMs: nowMs,
    createdAt: FieldValue.serverTimestamp(),
  });

  if (plan.kind === "item") {
    await notify([winnerUid], {
      title: "🎉 You won a prize!",
      body: `${plan.description} — tap to claim and tell us where to send it.`,
      category: "prize_won",
      data: {type: "prize_won", fulfillmentId: ref.id},
    });
  }
  await notifyAdmins(db,
      `${plan.kind === "cash" ? "CASH " : ""}${plan.description} → ` +
      `${username || winnerUid}`);
  return {done: true, kind: plan.kind, fulfillmentId: ref.id};
}

const MAX_FIELD = 300;

/**
 * The winner submits their shipping/contact details for a non-cash prize.
 * Only the winner of that fulfillment may claim it; the PII is written
 * server-side (the record is server-only in firestore.rules) and read by the
 * admin from the dashboard.
 */
async function submitPrizeClaim(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Sign in to claim.");
  const id = String(data?.fulfillmentId || "");
  const name = String(data?.name || "").trim().slice(0, MAX_FIELD);
  const address = String(data?.address || "").trim().slice(0, MAX_FIELD);
  const phone = String(data?.phone || "").trim().slice(0, MAX_FIELD);
  if (!id) throw new HttpsError("invalid-argument", "Missing prize.");
  if (!name || !address) {
    throw new HttpsError("invalid-argument", "Name and address are required.");
  }
  const db = getFirestore();
  const ref = db.collection("prizeFulfillments").doc(id);
  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError("not-found", "Prize not found.");
  if (snap.data().winnerUid !== auth.uid) {
    throw new HttpsError("permission-denied", "That isn't your prize.");
  }
  await ref.set({
    shipping: {name, address, phone},
    status: "claimed",
    claimedAtMs: Date.now(),
  }, {merge: true});
  return {ok: true};
}

module.exports = {
  prizePlan,
  awardPrizeForTournament,
  submitPrizeClaim,
};
