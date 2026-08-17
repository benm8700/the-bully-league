const {getFirestore} = require("firebase-admin/firestore");
const {pacificNow} = require("./eventWindow");

/**
 * The daily voting streak.
 *
 * DECIDED AND CONFIGURED BUT NEVER EARNABLE UNTIL NOW. `pointsSettings`
 * has carried a `dailyStreak` rate, bounds-checked and tunable from the
 * console, since the points economy was built - and nothing ever awarded
 * it. Only `match_played`, `match_won` and `vote_cast` were ever granted,
 * so a rate the config advertised could not be reached by any path.
 *
 * WHY THIS ONE IS WORTH BUILDING rather than any other unearned rate:
 * votes are the scarce resource the whole ladder runs on. Rating only
 * moves as far as a match is judged, and vote confidence discounts a
 * thinly-judged result - so an unjudged battle barely counted for the two
 * people who played it. A streak is loss-aversion pointed at exactly the
 * behaviour the app most needs and least rewards.
 *
 * ONE VOTE A DAY KEEPS IT ALIVE, per CLAUDE.md's decision ("consecutive
 * days with at least one vote cast"). Deliberately not a quota: a streak
 * that demands volume punishes someone with a busy day, and the point is
 * to build a habit rather than to extract labour.
 */

/**
 * The streak after a vote, given the streak before it.
 *
 * Pure, so the whole rule is testable without Firestore or a clock.
 *
 * Awards ONCE PER DAY - on the first vote of a day and never again, so a
 * judge who works through ten battles is rewarded for the habit rather
 * than paid per vote (which `vote_cast` already does).
 */
function streakAfterVote(current, todayKey, yesterdayKey) {
  const days = Number(current?.days) || 0;
  const lastKey = current?.dayKey;

  // Already counted today. The streak is unchanged and nothing is owed.
  if (lastKey === todayKey) {
    return {days: Math.max(days, 1), dayKey: todayKey, awarded: false};
  }
  // Voted yesterday, so the run continues.
  if (lastKey === yesterdayKey && days > 0) {
    return {days: days + 1, dayKey: todayKey, awarded: true, extended: true};
  }
  // A gap, or a first ever vote. Either way this is day one.
  return {days: 1, dayKey: todayKey, awarded: true, extended: false};
}

/** Pacific day keys for now and for the day before.
 *
 * Pacific rather than UTC because the app's whole rhythm is Pacific -
 * Sixes and Sevens, the daily push, the vote reminders. A streak that
 * rolled over at 5pm local would break for the very people the window
 * exists to gather. (The daily SKIP allowance still resets on UTC, which
 * CLAUDE.md already flags as worth revisiting.)
 */
function dayKeys(nowMs) {
  return {
    today: pacificNow(new Date(nowMs)).dayKey,
    // Twenty-four hours back always lands on the previous calendar day in
    // Pacific; a daylight-saving shift moves the clock by an hour, never
    // by a day.
    yesterday: pacificNow(new Date(nowMs - 24 * 60 * 60 * 1000)).dayKey,
  };
}

/**
 * Records a vote against the caller's streak and pays the bonus if this
 * was their first of the day.
 *
 * Best-effort: a streak failure must never fail the vote that earned it.
 * Returns what happened so the client can show the streak landing - a
 * reward nobody notices motivates nobody.
 */
async function recordVoteForStreak(uid, {multiplier = 1, nowMs = Date.now()} = {}) {
  try {
    const db = getFirestore();
    const ref = db.collection("users").doc(uid);
    const {today, yesterday} = dayKeys(nowMs);

    // A transaction because two votes cast in the same instant would
    // otherwise both read no-streak-today and both award the bonus.
    const outcome = await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const next = streakAfterVote(snap.data()?.voteStreak, today, yesterday);
      tx.set(ref, {
        voteStreak: {days: next.days, dayKey: next.dayKey},
      }, {merge: true});
      return next;
    });

    if (!outcome.awarded) {
      return {days: outcome.days, awarded: 0};
    }

    const {awardPoints, pointsSettings, awardAmount} = require("./points");
    const rates = await pointsSettings();
    const result = await awardPoints(uid, {
      reason: "vote_streak",
      // Keyed by the DAY, not by the match, so the ledger's idempotence
      // enforces once-per-day on its own even if this ran twice.
      sourceId: today,
      amount: awardAmount(rates.dailyStreak, {multiplier}),
    });
    return {days: outcome.days, awarded: result.awarded, extended: outcome.extended};
  } catch (e) {
    console.error(`vote streak for ${uid} failed:`, e.message);
    return {days: 0, awarded: 0};
  }
}

module.exports = {recordVoteForStreak, streakAfterVote, dayKeys};
