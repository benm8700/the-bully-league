const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {pacificNow} = require("./eventWindow");
const {sendToUsers} = require("./notifications");
const {readState, dailyRewardConfig} = require("./dailyReward");

/**
 * The daily-reward "last call" reminder (CLAUDE.md's Free Rewards note - the
 * one piece it flagged as NOT built: "any push/reminder that a reward is
 * waiting").
 *
 * Fires ONCE per Pacific day, in the EVENING, to people who have NOT claimed
 * today's reward. The evening slot is deliberate: the reward resets at Pacific
 * midnight, so "grab it before the day resets" is genuinely urgent then, and
 * anyone who came for the 6-7pm window has already claimed and is filtered
 * out - so the reminder only reaches people who did not engage all day, which
 * is exactly who it is for. It sits AFTER the event-window push so the two do
 * not cluster.
 *
 * Conservative by design (fatigue is the risk, not under-sending): at most one
 * per person per day, capped recipients so a bug shows at that size, and a
 * mutable `daily_reward` category so anyone can switch it off.
 */

// At or after this Pacific hour, once a day. Tunable - the hour is not
// load-bearing, only "evening, after the window, before midnight".
const TARGET_HOUR_PACIFIC = 20; // 8pm Pacific
const MAX_RECIPIENTS = 200;

/**
 * Pure: should a reminder go out now? True only once we are at/after the
 * target hour AND one has not already gone out today. Exposed for testing.
 */
function reminderDue({minutes, dayKey, sentDayKey, targetHour = TARGET_HOUR_PACIFIC}) {
  if (minutes < targetHour * 60) return false; // too early in the day
  if (sentDayKey === dayKey) return false; // already sent today
  return true;
}

async function sendDailyRewardReminder(now = new Date()) {
  const db = getFirestore();

  // If the whole reward is switched off in config, there is nothing to claim,
  // so nothing to remind about.
  const cfg = await dailyRewardConfig();
  if (cfg && cfg.enabled === false) return {skipped: "disabled"};

  const {dayKey, minutes} = pacificNow(now);
  const stateRef = db.collection("stats").doc("dailyRewardReminder");
  const state = (await stateRef.get()).data() ?? {};

  if (!reminderDue({minutes, dayKey, sentDayKey: state.dayKey})) {
    return {skipped: "nothing-due", dayKey, minutes};
  }

  // Claim BEFORE sending. A duplicate push is worse than a missed one - the
  // cost of missing is one un-nudged evening, the cost of duplicating is
  // someone muting the app permanently (which silences every category).
  await stateRef.set({
    dayKey,
    lastAttemptAt: FieldValue.serverTimestamp(),
  }, {merge: true});

  // Only people with a registered device - a push has nowhere else to go.
  // `fcmTokens != null` returns exactly the token-holders. The "claimed
  // today?" check is done IN CODE rather than as a Firestore query, because
  // dailyReward.lastClaimDay is absent for anyone who has never claimed, and a
  // `!=` query would silently exclude those never-claimed accounts - the exact
  // people the reminder exists for (the missing-field trap this project keeps
  // hitting). Preference filtering + dead-token pruning happen in sendToUsers.
  const tokenHolders = await db.collection("users")
      .where("fcmTokens", "!=", null).get();
  const recipients = [];
  for (const doc of tokenHolders.docs) {
    if (readState(doc.data()).lastClaimDay !== dayKey) recipients.push(doc);
    if (recipients.length >= MAX_RECIPIENTS) break;
  }

  const result = recipients.length === 0
    ? {sent: 0, failed: 0, recipients: 0}
    : await sendToUsers(recipients, {
      title: "Your daily reward is waiting \u{1F381}",
      body: "Grab it before midnight - the day is about to reset.",
      category: "daily_reward",
      data: {kind: "daily_reward"},
    });

  // Recorded so a scheduled send's outcome is inspectable without log access -
  // "silently sent to nobody" must not look like "worked".
  await stateRef.set({lastResult: result}, {merge: true});
  return {dayKey, ...result};
}

module.exports = {
  sendDailyRewardReminder,
  reminderDue,
  TARGET_HOUR_PACIFIC,
  MAX_RECIPIENTS,
};
