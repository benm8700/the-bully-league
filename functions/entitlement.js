const {getFirestore} = require("firebase-admin/firestore");
const {isWithinWindow} = require("./eventWindow");

/**
 * Who is allowed to battle, in which mode, right now.
 *
 * CLAUDE.md's Monetization Model in one function:
 *
 *   "Free to watch. Free to battle ranked at 6pm. Subscribe to battle
 *    whenever."
 *
 * Three states a player can be in:
 *   - IN TRIAL   - the first 14 days after signup. Everything unlocked.
 *   - SUBSCRIBER - everything unlocked, indefinitely.
 *   - LAPSED     - spectating stays free forever, and they may still play
 *                  RANKED during Sixes and Sevens. Nothing else.
 *
 * Plus one rule that applies to EVERYONE regardless of tier: during the
 * window, Practice is closed and everyone plays Ranked. The window exists
 * to make one crowd at one time, and a second queue running alongside it
 * splits the pool during the single hour designed to unsplit it.
 *
 * PURE, so the whole policy can be tested without Firestore, an emulator
 * or a clock - the same approach that caught the tournament bye bug and
 * the standing-challenge ghost-entry bug before either reached a device.
 */

/** Defaults, mirrored in config/monetization so they can be retuned from
 * the console without shipping an app version - same reasoning as the
 * match settings and the event window. */
const DEFAULTS = {
  /** Full access for this many days after signup. 14 gives two weekends
   * and ~14 Sixes and Sevens windows, which is enough for a rank to
   * stabilise and start meaning something. */
  trialDays: 14,
  /** Master switch. OFF means every check passes, so the enforcement can
   * ship and be verified in place long before anyone is charged - there
   * is no payment processor yet, and a half-built paywall that locks
   * real players out is far worse than no paywall at all. */
  enabled: false,
};

const DAY_MS = 24 * 60 * 60 * 1000;

/** Reasons a battle can be refused. Returned as codes rather than only
 * prose so the client can react differently - a paywall prompt is a very
 * different screen from "practice is closed right now". */
const DENY = {
  subscriptionRequired: "subscription-required",
  practiceClosedDuringWindow: "practice-closed-during-window",
};

/**
 * Reads config/monetization, bounds-checked per field.
 *
 * Hand-edited in the Firebase console against a live app with no
 * validation in between, so a bad value must never take the rest of a
 * good config down with it - same per-field fallback rule the match
 * settings and event window use. A trialDays of 0 would end every
 * trial instantly; 3650 would make the paywall theoretical.
 */
async function readMonetizationConfig(db = getFirestore()) {
  try {
    const snap = await db.collection("config").doc("monetization").get();
    const raw = snap.exists ? snap.data() : {};
    const days = Number(raw?.trialDays);
    return {
      trialDays: Number.isFinite(days) && days >= 1 && days <= 365 ?
        days : DEFAULTS.trialDays,
      enabled: raw?.enabled === true,
    };
  } catch (e) {
    // An unreadable config must never stop people playing.
    console.error("could not read config/monetization:", e.message);
    return {...DEFAULTS};
  }
}

/**
 * Is this account currently a subscriber?
 *
 * An explicit `active: true` is required - anything absent or ambiguous
 * reads as not subscribed, which is the safe direction here because the
 * enforcement itself fails open elsewhere.
 */
function isSubscriber(user, nowMs) {
  const sub = user?.subscription;
  if (sub?.active !== true) return false;
  const expires = Number(sub.expiresAtMs);
  // No expiry recorded means an open-ended entitlement (e.g. one granted
  // by hand for a beta tester), not a lapsed one.
  if (!Number.isFinite(expires) || expires <= 0) return true;
  return nowMs < expires;
}

/**
 * Is this account still inside its free trial?
 *
 * FAILS OPEN when createdAt is missing. Every account created before
 * this feature existed has no usable signup date, and treating an
 * unknown date as "trial long expired" would lock the entire existing
 * userbase out of battling the moment enforcement was switched on. That
 * is precisely the missing-accountStatus bug this project already hit
 * once, and the missing-field rules bug it hit before that.
 */
function isInTrial(user, nowMs, trialDays) {
  const createdMs = toMillis(user?.createdAt);
  if (createdMs === null) return true;
  return nowMs < createdMs + trialDays * DAY_MS;
}

/** Firestore Timestamp, Date, or epoch millis - whatever the doc holds. */
function toMillis(value) {
  if (value == null) return null;
  if (typeof value.toMillis === "function") return value.toMillis();
  if (value instanceof Date) return value.getTime();
  // Number(null) is 0 and finite, which is exactly how a missing queue
  // time once won a Math.min as an epoch timestamp. Check the type.
  if (typeof value === "number" && value > 0) return value;
  return null;
}

/**
 * The whole policy. Pure - give it a user document and a moment, get a
 * decision.
 *
 * @param {object} args.user           the caller's user document
 * @param {string} args.mode           "ranked" | "exhibition" | "tournament"
 * @param {number} args.nowMs          the moment being judged
 * @param {object} args.windowConfig   config/eventWindow
 * @param {object} args.config         config/monetization
 * @return {{allowed: boolean, reason: ?string, message: ?string,
 *           state: string, inWindow: boolean}}
 */
function battleEntitlement({user, mode, nowMs, windowConfig, config}) {
  const inWindow = windowConfig?.enabled === true &&
    isWithinWindow(new Date(nowMs), windowConfig);
  const subscriber = isSubscriber(user, nowMs);
  const trial = !subscriber && isInTrial(user, nowMs, config.trialDays);
  const state = subscriber ? "subscriber" : trial ? "trial" : "lapsed";

  const allow = (extra = {}) =>
    ({allowed: true, reason: null, message: null, state, inWindow, ...extra});

  // Enforcement off: the model is documented and deployed, but nothing is
  // being sold yet. Everything passes.
  if (config.enabled !== true) return allow();

  // Tournament entry is governed by its own fee and bracket rules, not by
  // this. Someone who paid to enter must always be able to play their
  // match, whatever their subscription state or the hour.
  if (mode === "tournament") return allow();

  const isPractice = mode !== "ranked";

  // Rule that binds everyone, subscribers included: the window is
  // ranked-only.
  if (inWindow && isPractice) {
    // Carve-out, and it is load-bearing rather than a nicety. The daily
    // push fires as the window opens, so this hour brings the most fresh
    // installs of the day - a brand-new player must never find every mode
    // closed on their first ever session, at the busiest moment there is.
    const neverRanked = (user?.rankedMatchesPlayed ?? 0) === 0;
    if (neverRanked) return allow();
    return {
      allowed: false,
      reason: DENY.practiceClosedDuringWindow,
      message: "Everyone's battling ranked right now. Jump in.",
      state,
      inWindow,
    };
  }

  if (subscriber || trial) return allow();

  // Lapsed. Ranked inside the window is theirs forever; nothing else is.
  if (mode === "ranked" && inWindow) return allow();

  return {
    allowed: false,
    reason: DENY.subscriptionRequired,
    message: inWindow ?
      "Practice is for subscribers. Ranked is free right now - go." :
      "Free battles happen during the daily window. " +
      "Subscribe to battle any time.",
    state,
    inWindow,
  };
}

module.exports = {
  DEFAULTS,
  DENY,
  DAY_MS,
  readMonetizationConfig,
  battleEntitlement,
  isSubscriber,
  isInTrial,
  toMillis,
};
