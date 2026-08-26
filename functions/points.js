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
  /** The smaller SPECTATOR tier: paid when a referred friend casts their
   * first vote. Lower than the battler tier because battling is worth
   * more, but real, because votes are the scarce resource. */
  referralSpectator: 25,
  /** Multiplier applied during the prime-time window. A POINTS multiplier
   * only - never rating, which would give high-rated players a reason to
   * sit out the very hour it exists to fill. */
  eventWindowMultiplier: 2,
  /** How many votes a day actually PAY. Votes beyond this still count in
   * full - only the payment stops.
   *
   * Without a ceiling, judging is a farm: tap random winners as fast as
   * the feed loads and mint unbounded currency. The points are the lesser
   * problem. Careless votes are noise fed into the thing that decides
   * rating, and vote confidence scales rating change by total vote weight -
   * so a pile of thoughtless votes makes rating move MORE while meaning
   * LESS, which is worse than those matches going unjudged.
   *
   * 10 is a placeholder like every other number here. It should be
   * comfortably above what an honest judge does in a sitting and well
   * below what a farmer would want. */
  votePointsPerDay: 10,
  /** What a day pass costs. 300 as of 2026-08-26 (was 500).
   *
   * THE POINT OF THIS SINK, and why it beats the clip: a clip is
   * TERMINAL. You want one, you get it, and then you want nothing - so
   * points go dead the moment someone has covered the win they cared
   * about. Access is RECURRING. You want another one next week, and the
   * week after, so the grind never runs out of purpose.
   *
   * It is also the one thing a free player most wants and cannot
   * otherwise have, since free battling is confined to the daily window -
   * which makes it a taste of the subscription.
   *
   * PRICED FOR RETENTION FIRST (the developer's call): at ~1.5-2 days of
   * play it is a frequently-achievable reward that keeps people earning
   * and playing rather than a distant grind that frustrates them into
   * quitting - the right bias for launch, when the goal is proving the
   * loop, not squeezing revenue.
   *
   * WHY CHEAP IS SAFE HERE (verified in code): a day pass grants ONLY the
   * anytime-battling gate - it puts the account in state "daypass", which
   * is distinct from "subscriber"/"trial", and every OTHER subscription
   * perk (free clips in clipGrants.js, stats in FormCard, the player
   * directory) gates on subscriber/trial and so is NOT unlocked by a pass.
   * So a cheap pass only lets a free player buy the "battle anytime" slice
   * a la carte; it never approaches the full subscription, which still
   * bundles clips + stats + directory + (planned) a coin allowance and a
   * gift bonus. The residual risk is the narrow case of someone who wants
   * ONLY anytime-battling and would grind rather than pay - and
   * dayPassEnabled (the kill switch) plus this being live-config cover even
   * that, from the console without a release. */
  dayPassPrice: 300,
  /** Whether day passes can be bought at all.
   *
   * THE OFF SWITCH MATTERS MORE THAN THE PRICE. The whole worry about
   * this sink is that it might cannibalise subscriptions, and that cannot
   * be known until real money is on the table. A price is a guess; a
   * kill switch is insurance. If passes turn out to be eating
   * subscriptions, this is one console edit rather than a release - and
   * removing a feature people already rely on is exactly the move that
   * needs to be instant. */
  dayPassEnabled: true,
};

const LIMITS = {
  matchPlayed: {min: 0, max: 10000},
  matchWon: {min: 0, max: 10000},
  voteCast: {min: 0, max: 10000},
  dailyStreak: {min: 0, max: 10000},
  referral: {min: 0, max: 100000},
  referralSpectator: {min: 0, max: 100000},
  eventWindowMultiplier: {min: 1, max: 10},
  // 0 would mean judging pays nothing at all, which is the opposite of
  // what the cap is for - it exists to bound a farm, not to switch off
  // the incentive that gets matches judged in the first place.
  votePointsPerDay: {min: 1, max: 1000},
  dayPassPrice: {min: 1, max: 100000},
};

function readPointsSettings(data) {
  const out = {...DEFAULTS};
  if (!data) return out;
  // Booleans are not range-checked like the numbers below, and only an
  // explicit false switches this off - a typo must not silently disable a
  // live feature.
  if (data.dayPassEnabled === false) out.dayPassEnabled = false;
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
/**
 * Has this reason already paid out its daily allowance?
 *
 * PURE, and separated because it is the rule that stops judging being a
 * points farm. Without a ceiling, paying per vote means a determined
 * person can tap random winners as fast as the feed loads and mint an
 * unbounded currency - and the damage is worse than the points, because
 * careless votes are noise fed straight into the thing that decides
 * rating. Vote confidence scales rating change by total vote weight, so a
 * pile of thoughtless votes makes rating move MORE while meaning LESS.
 *
 * Votes over the cap still COUNT. Only the payment stops. Refusing the
 * vote itself would punish the app's most active judges for being active,
 * which is the opposite of what the incentive exists to encourage.
 */
function dailyAwardBlocked(user, reason, dayKey, max) {
  if (!Number.isFinite(max) || max <= 0) return false;
  const record = user?.dailyAwards?.[reason];
  // A different day - or no record at all - means the allowance is fresh.
  if (!record || record.day !== dayKey) return false;
  return (Number(record.count) || 0) >= max;
}

/**
 * @param {object} opts.dailyCap  optional {dayKey, max} - pays at most
 *   `max` awards of this reason on this day, counted on the user document
 *   inside the same transaction so two simultaneous votes cannot both
 *   slip past the ceiling.
 */
async function awardPoints(uid, {reason, sourceId, amount, dailyCap}) {
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

      const userDataForCap = userSnap.data() ?? {};
      if (dailyCap && dailyAwardBlocked(
          userDataForCap, reason, dailyCap.dayKey, dailyCap.max)) {
        // No ledger entry is written, so the same event can still pay
        // tomorrow if it is somehow retried then - and, more importantly,
        // nothing about the vote itself is undone.
        return {awarded: 0, reason: "daily-cap"};
      }

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
      const update = {
        points: FieldValue.increment(points),
        pointsBalance: Math.max(0, balance) + points,
      };

      // THE XP -> TITLE HOOK (decided 2026-08-25). Career points ARE the
      // XP that drives the visible title ladder, and awardPoints is the one
      // chokepoint every XP gain flows through, so the title is derived
      // here rather than being scattered across each earning site. Because
      // XP only rises, the title can only rise - there is no down
      // transition to handle among the earned ranks.
      //
      // A LIVE GOAT SLOT IS NEVER TOUCHED. GOAT is a top-5 HIDDEN-Elo
      // position owned by syncGoatTier, not an XP threshold, so earning
      // points must never demote a GOAT back to their earned title. Only
      // syncGoatTier moves anyone in or out of GOAT.
      const {computeTitleFromXp, GOAT_TITLE} = require("./rating");
      const newCareer = (Number(user.points) || 0) + points;
      const currentTitle = user.rankTitle;
      const nextTitle = currentTitle === GOAT_TITLE ?
        GOAT_TITLE : computeTitleFromXp(newCareer);
      if (nextTitle && nextTitle !== currentTitle) {
        update.rankTitle = nextTitle;
      }
      if (dailyCap) {
        const record = user.dailyAwards?.[reason];
        const sameDay = record?.day === dailyCap.dayKey;
        // Written ABSOLUTELY rather than incremented, so a new day resets
        // rather than carrying yesterday's count forward - the exact bug
        // the vote reminders hit with FieldValue.increment across a day
        // boundary, where being reminded once yesterday blocked you all
        // of today.
        update.dailyAwards = {
          ...(user.dailyAwards ?? {}),
          [reason]: {
            day: dailyCap.dayKey,
            count: (sameDay ? Number(record.count) || 0 : 0) + 1,
          },
        };
      }
      tx.set(userRef, update, {merge: true});
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
  dailyAwardBlocked,
  readPointsSettings,
  pointsSettings,
  DEFAULTS,
  LIMITS,
};
