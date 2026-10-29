const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {pacificNow} = require("./eventWindow");
const {sendToUsers} = require("./notifications");

/**
 * The morning clip reminder - the nudge that makes the daily "post last night's
 * roast" ritual stick (Phase 1 of the clip flywheel).
 *
 * Fires ONCE per Pacific day, in the MORNING, and ONLY to ADMINS (the founder),
 * and ONLY when there is actually a clip ready to post. It is a founder tool,
 * not a user notification - the whole point is "open the Post Studio and post
 * today's top pick" without having to remember.
 *
 * Note the timing truth: a regular match finalizes ~24h after it is played, so
 * a clip becomes POSTABLE the day after the battle. The reminder therefore says
 * "fresh roasts are ready" (clips that finished judging), not "last night's" -
 * and it nudges only when at least one really is ready, so a quiet stretch never
 * nags.
 *
 * Conservative like the other reminders (fatigue is the only real risk): at most
 * one per admin per day, claimed before sending, a mutable `clip_reminder`
 * category, and it stands down when there is nothing to post.
 */

// Recorded, postable modes - mirrors the Post Studio's RECORDED_MODES.
const RECORDED_MODES = new Set([
  "ranked", "tournament", "friend", "elite", "improv", "mainstage",
]);

// At or after this Pacific hour, once a day. Not load-bearing - just "morning".
const TARGET_HOUR_PACIFIC = 9; // 9am Pacific
const MAX_RECIPIENTS = 20; // admins only - a handful

/**
 * Pure: should a reminder go out now? True only once we are at/after the target
 * hour AND one has not already gone out today. Exposed for testing.
 */
function reminderDue({minutes, dayKey, sentDayKey, targetHour = TARGET_HOUR_PACIFIC}) {
  if (minutes < targetHour * 60) return false; // too early
  if (sentDayKey === dayKey) return false; // already sent today
  return true;
}

/**
 * Pure: is this match a clip that's ready to post? Finished, a recorded mode,
 * judged, with a rendered reel, not already posted/set-aside, and not pulled by
 * a battler. Mirrors the Post Studio candidate filter. Exposed for testing.
 */
function isPostable(x) {
  if (!x || x.status !== "completed") return false;
  if (!RECORDED_MODES.has(String(x.mode))) return false;
  if (x.voteFinalized !== true) return false;
  const h = x.highlight || {};
  const rends = h.renditions || {};
  if (Object.keys(rends).length === 0) return false;
  const ps = x.postStudio || {};
  if (ps.status === "posted" || ps.status === "dismissed") return false;
  const mc = x.marketingConsent || {};
  const m1 = (mc[String(x.player1Id || "")] || {}).mode;
  const m2 = (mc[String(x.player2Id || "")] || {}).mode;
  if (m1 === "out" || m2 === "out") return false; // a battler pulled it
  return true;
}

async function sendMorningClipReminder(now = new Date()) {
  const db = getFirestore();
  const {dayKey, minutes} = pacificNow(now);
  const stateRef = db.collection("stats").doc("morningClipReminder");
  const state = (await stateRef.get()).data() ?? {};

  if (!reminderDue({minutes, dayKey, sentDayKey: state.dayKey})) {
    return {skipped: "nothing-due", dayKey, minutes};
  }

  // Nudge only if there is something to do. Scan recent matches (bounded) and
  // count the postable ones.
  const recent = await db.collection("matches")
      .orderBy("completedAt", "desc").limit(60).get();
  let ready = 0;
  for (const d of recent.docs) if (isPostable(d.data())) ready++;
  if (ready === 0) return {skipped: "nothing-to-post", dayKey};

  // Claim BEFORE sending - a duplicate push is worse than a missed one.
  await stateRef.set(
      {dayKey, lastAttemptAt: FieldValue.serverTimestamp()}, {merge: true});

  // Admins only. isAdmin is set false at signup and true only by a console
  // edit, so `== true` returns exactly the founder/admins (no missing-field
  // trap - we WANT only the explicit-true accounts here).
  const admins = await db.collection("users")
      .where("isAdmin", "==", true).limit(MAX_RECIPIENTS).get();
  const recipients = admins.docs;

  const result = recipients.length === 0
    ? {sent: 0, failed: 0, recipients: 0}
    : await sendToUsers(recipients, {
      title: "\u{1F3C6} Fresh roasts ready to post",
      body: `${ready} clip${ready === 1 ? "" : "s"} waiting in the Post Studio - ` +
            "share today's top pick.",
      category: "clip_reminder",
      data: {kind: "clip_reminder"},
    });

  // Recorded so a scheduled send's outcome is inspectable without log access.
  await stateRef.set({lastResult: {...result, ready}}, {merge: true});
  return {dayKey, ready, ...result};
}

module.exports = {
  sendMorningClipReminder,
  reminderDue,
  isPostable,
  TARGET_HOUR_PACIFIC,
  MAX_RECIPIENTS,
};
