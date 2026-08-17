const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");
const {pacificNow} = require("./eventWindow");

/**
 * A day pass: 24 hours of battling any time, bought with points.
 *
 * WHY THIS AND NOT MORE CLIPS. A clip is a TERMINAL sink - you want one,
 * you get it, and then you want nothing. Real demand looks like one or two
 * a week and only for wins, so points go dead the moment someone has
 * covered the win they cared about, and a currency you cannot spend stops
 * motivating anyone. Access is RECURRING: you want another pass next week
 * and the week after, so the grind never runs out of purpose.
 *
 * WHY IT HELPS CONVERSION RATHER THAN HURTING IT. Under the monetization
 * model a free player cannot battle outside Sixes and Sevens at all, which
 * makes "battle whenever, today" the single most desirable thing they
 * could have - and it is exactly what the subscription sells. Someone who
 * grinds two or three days for one day of it has just learned precisely
 * what they would be buying, and learned that grinding is a poor way to
 * get it. You cannot want what you have never had; this is the sample.
 *
 * THE HONEST RISK, recorded rather than hidden: this gives away the thing
 * being sold, and a committed grinder could in principle stay free. Two
 * things contain it - the effort ratio above, and the daily cap on vote
 * points, without which passes would be close to free. Both are single
 * config numbers, which makes this the ideal thing to tune during the beta
 * rather than argue about in advance.
 *
 * WHAT IT IS NOT. It does not touch rank, vote weight, matchmaking
 * fairness or anything between pairing and verdict. It buys convenience,
 * which CLAUDE.md establishes is the only shape that does not corrupt a
 * competitive ladder. It also does NOT open Practice during the window -
 * that rule binds subscribers too, because it is a liquidity rule rather
 * than a perk.
 */

const DAY_MS = 24 * 60 * 60 * 1000;

/**
 * Is a bought pass currently running?
 *
 * PURE. Only a finite future timestamp counts - a missing or malformed
 * field reads as no pass, which is the safe direction: the failure of this
 * check should be "you do not have access you did not buy", never "you
 * have access forever".
 */
function dayPassActive(user, nowMs) {
  const expires = Number(user?.dayPassExpiresAtMs);
  return Number.isFinite(expires) && expires > nowMs;
}

/**
 * Buy 24 hours of anytime battling.
 *
 * ONE PER PACIFIC DAY, enforced by the ledger id rather than by a check -
 * so a retried tap can never charge twice, and nobody can stockpile a
 * month of passes during a quiet week and then vanish. The day key matches
 * the streak, the quests and the event window, so "a day" means the same
 * thing everywhere in the app.
 */
async function buyDayPass(auth) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const db = getFirestore();
  const uid = auth.uid;
  const nowMs = Date.now();

  const {pointsSettings} = require("./points");
  const settings = await pointsSettings();
  const price = settings.dayPassPrice;

  // Checked server-side rather than only hidden in the UI: if this sink
  // ever has to be switched off, it must actually stop, including for a
  // client that still has the old screen.
  if (settings.dayPassEnabled === false) {
    throw new HttpsError("failed-precondition",
        "Day passes aren't available right now.",
        {reason: "disabled"});
  }

  const userRef = db.collection("users").doc(uid);
  const dayKey = pacificNow(new Date(nowMs)).dayKey;
  const entryRef = userRef.collection("pointsLedger").doc(`dayPass_${dayKey}`);

  const result = await db.runTransaction(async (tx) => {
    const [entry, snap] = await Promise.all([tx.get(entryRef), tx.get(userRef)]);
    const user = snap.data() ?? {};

    if (entry.exists) {
      return {bought: false, reason: "already-bought-today",
        expiresAtMs: Number(user.dayPassExpiresAtMs) || null};
    }
    if (dayPassActive(user, nowMs)) {
      // Refused rather than extended. Stacking would let someone buy their
      // way to a permanent free subscription in instalments, which is the
      // one outcome this must not allow.
      return {bought: false, reason: "already-active",
        expiresAtMs: Number(user.dayPassExpiresAtMs)};
    }

    // Mirrors spendableBalance in clipGrants.js: an account predating
    // spending has no balance field and has by definition spent nothing,
    // so its balance is its career total. Reading a missing balance as
    // zero would confiscate everything earned before this existed.
    const raw = Number(user.pointsBalance);
    const balance = Number.isFinite(raw) ?
      Math.max(0, raw) : Math.max(0, Number(user.points) || 0);
    if (balance < price) {
      return {bought: false, reason: "insufficient", balance, price};
    }

    const expiresAtMs = nowMs + DAY_MS;
    tx.set(entryRef, {
      reason: "dayPass", sourceId: dayKey, amount: -price,
      createdAt: FieldValue.serverTimestamp(),
    });
    // Absolute, not an increment, for the same reason every other spend
    // is: a legacy account with no balance field must inherit its career
    // total rather than being decremented from zero.
    tx.set(userRef, {
      pointsBalance: balance - price,
      dayPassExpiresAtMs: expiresAtMs,
    }, {merge: true});
    return {bought: true, expiresAtMs, spent: price, balance: balance - price};
  });

  if (!result.bought) {
    const messages = {
      "already-active": "Your day pass is still running.",
      "already-bought-today": "You have already bought a pass today.",
      "insufficient":
        `A day pass costs ${result.price} points - you have ${result.balance}.`,
    };
    throw new HttpsError("failed-precondition",
        messages[result.reason] ?? "Could not buy a day pass.",
        {reason: result.reason, price});
  }
  return result;
}

/** What the client needs to render the offer honestly. */
async function getDayPassState(auth) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const db = getFirestore();
  const nowMs = Date.now();
  const {pointsSettings} = require("./points");
  const [snap, settings] = await Promise.all([
    db.collection("users").doc(auth.uid).get(),
    pointsSettings(),
  ]);
  const user = snap.data() ?? {};
  const raw = Number(user.pointsBalance);
  const balance = Number.isFinite(raw) ?
    Math.max(0, raw) : Math.max(0, Number(user.points) || 0);
  const active = dayPassActive(user, nowMs);
  const dayKey = pacificNow(new Date(nowMs)).dayKey;
  const boughtToday = (await db.collection("users").doc(auth.uid)
      .collection("pointsLedger").doc(`dayPass_${dayKey}`).get()).exists;
  const enabled = settings.dayPassEnabled !== false;
  return {
    active,
    expiresAtMs: active ? Number(user.dayPassExpiresAtMs) : null,
    price: settings.dayPassPrice,
    balance,
    enabled,
    canBuy: enabled && !active && !boughtToday &&
      balance >= settings.dayPassPrice,
    boughtToday,
  };
}

module.exports = {
  buyDayPass,
  getDayPassState,
  dayPassActive,
  DAY_MS,
};
