const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");
const {qualifyingWeek} = require("./weeklyQualifier");
const {spendableBalance} = require("./clipGrants");
const {
  sanitiseJudgeSeatConfig, judgeSeatEligibility, seatsRemaining, maxPaidSeats,
} = require("./judgeSeat");

/**
 * The PAID JUDGE-PANEL SEAT - the Firestore wiring around the pure core
 * (judgeSeat.js). A fixed-price points buy for one of the (minority) bought
 * seats on the weekly Main Stage panel - the "panel seats" sink in the locked
 * economy model (2026-11-03).
 *
 *  - buyJudgeSeat: during the qualifying week, an eligible active judge pays the
 *    FIXED price and takes a seat. First-come: once the bought seats sell out,
 *    no more are sold. The claim and the charge are ONE transaction, so a seat
 *    can never be charged-without-granted or oversold.
 *  - at the LOCK (mainStageTournament.lockDueTournaments): the week's buyers are
 *    seated on the panel after the founder's hand-picks and before the pool,
 *    capped to a minority. A buyer who meanwhile QUALIFIED as a finalist, or was
 *    banned, is dropped (can't judge a tournament you're in) and refunded.
 *
 * Gated behind config/tournament.enabled AND a separate judgeSeatsEnabled flag,
 * so it deploys inert (no seats sold, panel unchanged) until BOTH are flipped -
 * the same failsafe as the wildcard auction and the rest of the tournament
 * system. Economy NUMBERS (price, seat count, the vote floor) are placeholders
 * in config/tournament, per the advisor-review record.
 */

/** Map config/tournament -> the pure judge-seat config. On sale only when the
 * whole tournament is enabled AND the seat flag is on. */
function readJudgeSeatConfig(cfgData) {
  return sanitiseJudgeSeatConfig({
    enabled: cfgData?.enabled === true && cfgData?.judgeSeatsEnabled === true,
    price: cfgData?.judgeSeatPrice,
    seats: cfgData?.judgeSeatCount,
    minVotes: cfgData?.judgeSeatMinVotes,
  });
}

async function readTournamentConfigData(db) {
  try {
    return (await db.collection("config").doc("tournament").get()).data();
  } catch (e) {
    console.error("tournament config read failed:", e.message);
    return null;
  }
}

const seatsRef = (db, weekKey) => db.collection("judgeSeats").doc(weekKey);
const ledgerRef = (db, uid, weekKey) => db.collection("users").doc(uid)
    .collection("pointsLedger").doc(`judgeSeat_${weekKey}`);

/**
 * Buy a seat on this week's panel. Fixed price, first-come. The claim (append
 * to the week's buyer list) and the charge (ledger entry + balance decrement)
 * are a SINGLE transaction, so two simultaneous buyers can't oversell the last
 * seat and a charge never lands without a seat.
 */
async function buyJudgeSeat(auth) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const db = getFirestore();
  const nowMs = Date.now();

  const config = readJudgeSeatConfig(await readTournamentConfigData(db));
  if (!config.enabled) {
    throw new HttpsError("failed-precondition",
        "Panel seats aren't on sale right now.");
  }
  const weekKey = qualifyingWeek(nowMs).cutoffDayKey;
  const cap = maxPaidSeats(config);

  const uid = auth.uid;
  const sRef = seatsRef(db, weekKey);
  const userRef = db.collection("users").doc(uid);
  const lRef = ledgerRef(db, uid, weekKey);

  return db.runTransaction(async (tx) => {
    const [lSnap, userSnap, sSnap] = await Promise.all([
      tx.get(lRef), tx.get(userRef), tx.get(sRef),
    ]);
    // Already bought (ledger is the idempotency anchor): a retried tap is a
    // no-op, never a second charge.
    if (lSnap.exists) return {ok: true, alreadyHeld: true, weekKey};

    const user = userSnap.data() ?? {};
    const elig = judgeSeatEligibility(user, config);
    if (!elig.eligible) {
      throw new HttpsError("failed-precondition", elig.message,
          {reason: elig.reason});
    }

    const buyers = (sSnap.exists && Array.isArray(sSnap.data().buyers)) ?
      sSnap.data().buyers : [];
    if (buyers.some((b) => b && b.uid === uid)) {
      return {ok: true, alreadyHeld: true, weekKey};
    }
    if (buyers.length >= cap) {
      throw new HttpsError("failed-precondition",
          "The panel's bought seats are sold out for this week.",
          {reason: "sold-out"});
    }
    const balance = spendableBalance(user);
    if (balance < config.price) {
      throw new HttpsError("failed-precondition",
          `A panel seat costs ${config.price} points - you have ${balance}.`,
          {reason: "insufficient"});
    }

    tx.set(lRef, {
      reason: "judgeSeat", sourceId: weekKey, amount: -config.price,
      createdAt: FieldValue.serverTimestamp(),
    });
    tx.set(userRef, {pointsBalance: balance - config.price}, {merge: true});
    tx.set(sRef, {
      weekKey,
      buyers: [...buyers, {uid, at: nowMs}],
      updatedAt: FieldValue.serverTimestamp(),
    }, {merge: true});

    return {ok: true, held: true, weekKey, price: config.price,
      seatsRemaining: Math.max(0, cap - (buyers.length + 1))};
  });
}

/** The caller's current seat state, for the buy UI. */
async function getJudgeSeatState(auth) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const db = getFirestore();
  const config = readJudgeSeatConfig(await readTournamentConfigData(db));
  const weekKey = qualifyingWeek(Date.now()).cutoffDayKey;
  if (!config.enabled) return {enabled: false, weekKey};

  const [userSnap, sSnap] = await Promise.all([
    db.collection("users").doc(auth.uid).get(),
    seatsRef(db, weekKey).get(),
  ]);
  const user = userSnap.data() ?? {};
  const buyers = (sSnap.exists && Array.isArray(sSnap.data().buyers)) ?
    sSnap.data().buyers : [];
  const elig = judgeSeatEligibility(user, config);
  return {
    enabled: true,
    weekKey,
    price: config.price,
    seatsTotal: maxPaidSeats(config),
    seatsSold: buyers.length,
    seatsRemaining: seatsRemaining(buyers.length, config),
    youHold: buyers.some((b) => b && b.uid === auth.uid),
    eligible: elig.eligible,
    reason: elig.reason,
    message: elig.message || null,
    balance: spendableBalance(user),
  };
}

/**
 * The week's seat buyers in PURCHASE ORDER (first-come), for the panel lock.
 * Read-modify-nothing; returns a plain uid array.
 */
async function paidSeatHoldersForWeek(db, weekKey) {
  if (!weekKey) return [];
  const snap = await seatsRef(db, weekKey).get();
  const buyers = (snap.exists && Array.isArray(snap.data().buyers)) ?
    snap.data().buyers : [];
  return [...buyers]
      .filter((b) => b && typeof b.uid === "string")
      .sort((a, b) => (Number(a.at) || 0) - (Number(b.at) || 0))
      .map((b) => b.uid);
}

/**
 * Refund a seat the buyer didn't get to use - they qualified as a finalist (so
 * can't judge), were banned, or the seat count was cut below their place. An
 * in-app points refund to the spendable balance, NEVER a store refund (the same
 * stance as clip refunds). Refunds exactly what was charged (read from the
 * ledger, so a later price change can't over- or under-pay). Idempotent on the
 * refund ledger id. Best-effort: a failure must never fail the lock.
 */
async function refundJudgeSeat(db, weekKey, uid) {
  const userRef = db.collection("users").doc(uid);
  const chargeRef = ledgerRef(db, uid, weekKey);
  const refundRef = userRef.collection("pointsLedger")
      .doc(`judgeSeatRefund_${weekKey}`);
  try {
    await db.runTransaction(async (tx) => {
      const [refundSnap, chargeSnap, userSnap] = await Promise.all([
        tx.get(refundRef), tx.get(chargeRef), tx.get(userRef),
      ]);
      if (refundSnap.exists) return; // already refunded
      if (!chargeSnap.exists) return; // nothing was charged
      const amount = -Number(chargeSnap.data().amount); // charge was negative
      if (!(amount > 0)) return;
      tx.set(refundRef, {
        reason: "judgeSeatRefund", sourceId: weekKey, amount,
        createdAt: FieldValue.serverTimestamp(),
      });
      tx.set(userRef, {
        pointsBalance: spendableBalance(userSnap.data() ?? {}) + amount,
      }, {merge: true});
    });
  } catch (e) {
    console.error(`judge-seat refund for ${uid} (${weekKey}) failed:`, e.message);
  }
}

module.exports = {
  readJudgeSeatConfig,
  buyJudgeSeat,
  getJudgeSeatState,
  paidSeatHoldersForWeek,
  refundJudgeSeat,
};
