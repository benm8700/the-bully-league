const {getFirestore, FieldValue} = require("firebase-admin/firestore");

/**
 * The points economy: a second currency that ONLY ever increases.
 *
 * Deliberately separate from rating, and the separation is the whole point.
 * Rating goes up and down and decides your rank; points only accumulate.
 * Someone on a five-match losing streak has a rating falling and a balance
 * still climbing, so there is always something going right - which is the
 * retention reason this currency exists at all.
 *
 * SERVER-AUTHORITATIVE. Same class of write as rating and wins: a client
 * able to set its own balance could buy every cosmetic in the store, so
 * firestore.rules denies the field entirely and every award goes through
 * here.
 *
 * VALUES LIVE IN CONFIG, not in this file. CLAUDE.md is explicit that the
 * numbers "need real playtesting to balance", and an economy whose rates
 * require a new app release to tune will simply never be tuned. They are
 * read from `config/pointsSettings` and bounds-checked per field, the same
 * way match settings are, because that document is hand-edited in a console
 * with no validation in between.
 */

/**
 * Starting rates. PLACEHOLDERS in the same sense as the rank thresholds -
 * chosen so the ratios feel right rather than the absolute numbers:
 * judging someone else's battle is worth a meaningful fraction of playing
 * one, because votes are the scarce resource the whole ladder runs on.
 */
const DEFAULTS = {
  matchPlayed: 10,
  matchWon: 25,
  voteCast: 5,
  dailyStreak: 15,
  referral: 100,
  /** Multiplier applied during the prime-time window. A POINTS multiplier
   * only - never rating, which would give high-rated players a reason to
   * sit out the very hour it exists to fill. */
  eventWindowMultiplier: 2,
};

const LIMITS = {
  matchPlayed: {min: 0, max: 10000},
  matchWon: {min: 0, max: 10000},
  voteCast: {min: 0, max: 10000},
  dailyStreak: {min: 0, max: 10000},
  referral: {min: 0, max: 100000},
  eventWindowMultiplier: {min: 1, max: 10},
};

function readPointsSettings(data) {
  const out = {...DEFAULTS};
  if (!data) return out;
  for (const [key, limit] of Object.entries(LIMITS)) {
    const value = data[key];
    // Per-field fallback, so one bad value never discards a whole good
    // configuration - the same rule match settings follow.
    if (typeof value === "number" && Number.isFinite(value) &&
        value >= limit.min && value <= limit.max) {
      out[key] = value;
    }
  }
  return out;
}

async function pointsSettings() {
  try {
    const snap = await getFirestore().collection("config").doc("pointsSettings").get();
    return readPointsSettings(snap.data());
  } catch (e) {
    console.error("pointsSettings read failed, using defaults:", e.message);
    return {...DEFAULTS};
  }
}

/**
 * How much an award is worth, given the rate and whether it happened
 * inside the prime-time window.
 *
 * Pure, so the arithmetic is testable without Firestore.
 */
function awardAmount(base, {multiplier = 1} = {}) {
  const amount = Math.round((Number(base) || 0) * (Number(multiplier) || 1));
  // Never negative: this currency only goes up, and a negative award would
  // quietly turn it into a second rating.
  return Math.max(0, amount);
}

/**
 * Credits points once, and only once, for a given source.
 *
 * IDEMPOTENCE IS THE WHOLE DESIGN HERE. Every caller is a retryable path -
 * a vote that got a network error and was resent, a match settled twice by
 * two devices racing, a scheduled sweep re-examining the same match. Naive
 * increments would inflate balances quietly and there would be no way to
 * tell a farmed balance from an earned one afterwards.
 *
 * So each award writes a LEDGER ENTRY at a deterministic id, created
 * inside a transaction with the balance increment. A repeat finds the
 * entry already there and does nothing. The ledger doubles as the audit
 * trail - "where did these points come from" has an answer.
 */
async function awardPoints(uid, {reason, sourceId, amount}) {
  if (!uid || !reason || !sourceId) return {awarded: 0, reason: "invalid"};
  const points = awardAmount(amount);
  if (points === 0) return {awarded: 0, reason: "zero"};

  const db = getFirestore();
  const userRef = db.collection("users").doc(uid);
  // Deterministic: the same event can only ever produce this one id.
  const entryRef = userRef.collection("pointsLedger").doc(`${reason}_${sourceId}`);

  try {
    return await db.runTransaction(async (tx) => {
      const [existing, userSnap] = await Promise.all([
        tx.get(entryRef), tx.get(userRef),
      ]);
      if (existing.exists) return {awarded: 0, reason: "duplicate"};
      tx.set(entryRef, {
        reason,
        sourceId,
        amount: points,
        createdAt: FieldValue.serverTimestamp(),
      });
      // TWO NUMBERS. `points` is the CAREER total and only ever rises -
      // that is the progression ladder this file exists to guarantee, and
      // spending must never be able to pull it back down into a second
      // rating. `pointsBalance` is what is left to spend.
      //
      // The balance is written absolutely rather than incremented, because
      // an account that predates spending has no balance field at all and
      // has, by definition, spent nothing - so its balance is its career
      // total. Incrementing from a missing field would start it at zero
      // and quietly confiscate everything earned so far, the same
      // missing-field trap as accountStatus and createdAt before it.
      const user = userSnap.data() ?? {};
      const balance = Number.isFinite(Number(user.pointsBalance)) ?
        Number(user.pointsBalance) : (Number(user.points) || 0);
      tx.set(userRef, {
        points: FieldValue.increment(points),
        pointsBalance: Math.max(0, balance) + points,
      }, {merge: true});
      return {awarded: points, reason};
    });
  } catch (e) {
    // Points are a reward, never a precondition. A failed award must not
    // fail the vote or the match that earned it.
    console.error(`awardPoints ${reason}/${sourceId} for ${uid} failed:`, e.message);
    return {awarded: 0, reason: "error"};
  }
}

module.exports = {
  awardPoints,
  awardAmount,
  readPointsSettings,
  pointsSettings,
  DEFAULTS,
  LIMITS,
};
