const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");
const {pacificNow, nextDayKey} = require("./eventWindow");

/**
 * Free Rewards: a daily login reward, claimed once per Pacific day.
 *
 * PURE CLAIM. Open the app, tap Claim - no battle, no vote, no activity
 * required. The whole job of this feature is a reason to OPEN the app every
 * day; asking for anything more would defeat that.
 *
 * ESCALATING 7-DAY CYCLE, resetting on a missed day. Day 1 pays a little,
 * day 7 is the climax, and the run resets to day 1 the moment you skip a
 * day - the same loss-aversion habit loop as the vote streak, applied to
 * simply showing up. The Pacific day key matches the streak, the quests,
 * the day pass and the event window, so "a day" means the same thing
 * everywhere in the app.
 *
 * SERVER-MINTED, and that is why it is a Cloud Function rather than a client
 * write: it grants points, so a client that could write its own claim state
 * would mint unlimited currency. Points flow through awardPoints (the single
 * XP/points chokepoint), and the claim is idempotent per Pacific day via a
 * ledger entry keyed by the day - so a retried tap, or two devices racing,
 * can never pay twice. The `dailyReward` bookkeeping field is protected in
 * firestore.rules exactly like the other economy fields.
 *
 * VALUES LIVE IN CONFIG. The schedule and the on/off switch are read from
 * `config/pointsSettings.dailyRewards`, bounds-checked per field, so the
 * amounts can be retuned from the console without a release. They are
 * PLACEHOLDERS pending the developer's advisor review of the whole
 * rewards/monetization/XP model - kept in config precisely so that review is
 * a console edit, not a rebuild.
 */

/**
 * Default 7-day escalating schedule. Day 7 is a big points climax rather
 * than a separate reward type (a clip token / day pass), to keep V1 to one
 * currency and far less integration surface - a trivial future upgrade.
 * ~430 points a week for just showing up: a real bonus, well under what
 * active play earns.
 */
const DEFAULTS = {
  schedule: [20, 30, 40, 50, 60, 80, 150],
  enabled: true,
};

const CYCLE_LENGTH = 7;
// Guards on hand-edited config: a schedule must be 7 finite, non-negative,
// not-absurd numbers or it is discarded wholesale in favour of the default
// (unlike the per-field points rates, because the schedule is one coherent
// curve - a single bad entry should not silently flatten one day of it).
const MAX_REWARD = 100000;

/**
 * Reads and validates the daily-reward config out of a pointsSettings
 * document. Pure, so it is testable without Firestore.
 */
function readDailyRewardConfig(data) {
  const out = {schedule: [...DEFAULTS.schedule], enabled: DEFAULTS.enabled};
  const cfg = data && data.dailyRewards;
  if (!cfg || typeof cfg !== "object") return out;
  if (cfg.enabled === false) out.enabled = false;
  const s = cfg.schedule;
  if (Array.isArray(s) && s.length === CYCLE_LENGTH &&
      s.every((v) => typeof v === "number" && Number.isFinite(v) &&
        v >= 0 && v <= MAX_REWARD)) {
    out.schedule = s.map((v) => Math.round(v));
  }
  return out;
}

async function dailyRewardConfig() {
  try {
    const snap = await getFirestore()
        .collection("config").doc("pointsSettings").get();
    return readDailyRewardConfig(snap.data());
  } catch (e) {
    console.error("dailyReward config read failed, using defaults:", e.message);
    return {schedule: [...DEFAULTS.schedule], enabled: DEFAULTS.enabled};
  }
}

/** The Pacific-day key one day before [dayKey]. Calendar arithmetic in UTC,
 * matching nextDayKey - a bare date has no timezone of its own. */
function prevDayKey(dayKey) {
  const [y, m, d] = dayKey.split("-").map(Number);
  const prev = new Date(Date.UTC(y, m - 1, d - 1));
  return `${prev.getUTCFullYear()}-` +
    `${String(prev.getUTCMonth() + 1).padStart(2, "0")}-` +
    `${String(prev.getUTCDate()).padStart(2, "0")}`;
}

/**
 * The stored cycle state, read defensively from a user document.
 * Returns {lastClaimDay, cycleDay} with a cycleDay clamped to 1..7 (or
 * null lastClaimDay for an account that has never claimed).
 */
function readState(user) {
  const dr = user && user.dailyReward;
  if (!dr || typeof dr !== "object") return {lastClaimDay: null, cycleDay: 0};
  const day = typeof dr.lastClaimDay === "string" ? dr.lastClaimDay : null;
  let cycleDay = Number(dr.cycleDay);
  if (!Number.isFinite(cycleDay) || cycleDay < 1) cycleDay = 0;
  if (cycleDay > CYCLE_LENGTH) cycleDay = CYCLE_LENGTH;
  return {lastClaimDay: day, cycleDay: Math.floor(cycleDay)};
}

/**
 * The core cycle rule. PURE - given today's and yesterday's Pacific day
 * keys and the stored state, decides whether today is claimable and which
 * cycle day it lands on.
 *
 *  - Already claimed today          -> alreadyClaimed, today's cycle day.
 *  - Claimed YESTERDAY (consecutive)-> advance, wrapping 7 -> 1.
 *  - Missed a day, or first ever     -> reset to day 1.
 */
function planClaim(state, todayKey, yesterdayKey) {
  if (state.lastClaimDay === todayKey) {
    return {claimable: false, cycleDay: state.cycleDay || 1};
  }
  let cycleDay;
  if (state.lastClaimDay === yesterdayKey && state.cycleDay >= 1) {
    cycleDay = state.cycleDay >= CYCLE_LENGTH ? 1 : state.cycleDay + 1;
  } else {
    cycleDay = 1; // first claim, or a broken streak
  }
  return {claimable: true, cycleDay};
}

/** The reward for a 1-based cycle day against a schedule. */
function rewardFor(schedule, cycleDay) {
  const idx = Math.max(1, Math.min(CYCLE_LENGTH, cycleDay)) - 1;
  return Number(schedule[idx]) || 0;
}

/**
 * Everything the client needs to render the reward calendar without
 * claiming: the schedule, which day today lands on, whether it is claimable
 * now, and whether the feature is on.
 */
async function getDailyRewardState(auth) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const db = getFirestore();
  const [snap, config] = await Promise.all([
    db.collection("users").doc(auth.uid).get(),
    dailyRewardConfig(),
  ]);
  const user = snap.data() ?? {};
  const {dayKey} = pacificNow(new Date());
  const yesterdayKey = prevDayKey(dayKey);
  const state = readState(user);
  const plan = planClaim(state, dayKey, yesterdayKey);
  return {
    enabled: config.enabled,
    schedule: config.schedule,
    cycleLength: CYCLE_LENGTH,
    // The cycle day today's claim WOULD be (or is, if already claimed).
    cycleDay: plan.cycleDay,
    todaysReward: rewardFor(config.schedule, plan.cycleDay),
    claimable: config.enabled && plan.claimable,
    claimedToday: !plan.claimable,
  };
}

/**
 * Claim today's reward. Idempotent per Pacific day via the points ledger.
 */
async function claimDailyReward(auth) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const db = getFirestore();
  const uid = auth.uid;
  const config = await dailyRewardConfig();

  if (!config.enabled) {
    throw new HttpsError("failed-precondition",
        "Daily rewards aren't available right now.", {reason: "disabled"});
  }

  const {dayKey} = pacificNow(new Date());
  const yesterdayKey = prevDayKey(dayKey);
  const userRef = db.collection("users").doc(uid);

  // Decide the cycle day and record the claim state in a transaction, so two
  // devices tapping at once cannot each advance the cycle. The ledger entry
  // (written by awardPoints, keyed by the day) is the true guard against a
  // double PAYMENT; this transaction guards the cycle bookkeeping.
  const decision = await db.runTransaction(async (tx) => {
    const snap = await tx.get(userRef);
    const state = readState(snap.data() ?? {});
    const plan = planClaim(state, dayKey, yesterdayKey);
    if (!plan.claimable) {
      return {claimed: false, reason: "already-claimed", cycleDay: plan.cycleDay};
    }
    tx.set(userRef, {
      dailyReward: {lastClaimDay: dayKey, cycleDay: plan.cycleDay},
    }, {merge: true});
    return {claimed: true, cycleDay: plan.cycleDay};
  });

  if (!decision.claimed) {
    return {
      claimed: false,
      reason: decision.reason,
      cycleDay: decision.cycleDay,
      cycleLength: CYCLE_LENGTH,
    };
  }

  const reward = rewardFor(config.schedule, decision.cycleDay);
  // Through the one points chokepoint, idempotent on the Pacific day: a
  // retried claim finds the ledger entry and pays nothing, even though the
  // cycle transaction above already committed.
  const {awardPoints} = require("./points");
  const award = await awardPoints(uid, {
    reason: "daily_reward",
    sourceId: dayKey,
    amount: reward,
  });

  return {
    claimed: true,
    cycleDay: decision.cycleDay,
    cycleLength: CYCLE_LENGTH,
    reward,
    awarded: award.awarded,
  };
}

module.exports = {
  claimDailyReward,
  getDailyRewardState,
  readDailyRewardConfig,
  dailyRewardConfig,
  planClaim,
  rewardFor,
  readState,
  prevDayKey,
  DEFAULTS,
  CYCLE_LENGTH,
};
