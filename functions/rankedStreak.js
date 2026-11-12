const {getFirestore} = require("firebase-admin/firestore");
const {pacificNow} = require("./eventWindow");

/**
 * THE WEEKLY RANKED STREAK (2026-11-11, developer's call).
 *
 * Consecutive Pacific weeks (Monday to Sunday) with at least one completed
 * RANKED battle. Weekly, not daily, on purpose: a ranked battle needs a
 * stranger online at the same moment, so a daily streak in a thin beta
 * would mostly break on an empty queue - the app's fault, felt as the
 * player's. One battle a week is always reachable during Happy Hour, and
 * it matches the weekly Main Stage rhythm.
 *
 * No points: ranked play already pays match XP. This is a habit marker.
 * Stored as users/{uid}.rankedStreak = {weeks, weekKey}; server-only in
 * firestore.rules.
 */

/** "YYYY-MM-DD" of the Monday starting the Pacific week containing dayKey. */
function weekKeyForDay(dayKey) {
  const [y, m, d] = dayKey.split("-").map(Number);
  // Pure calendar arithmetic on the Pacific date, in UTC so no local
  // timezone or daylight-saving shift can move it.
  const date = new Date(Date.UTC(y, m - 1, d));
  const sinceMonday = (date.getUTCDay() + 6) % 7;
  date.setUTCDate(date.getUTCDate() - sinceMonday);
  return date.toISOString().slice(0, 10);
}

/** This week's and last week's keys, in Pacific time. */
function weekKeys(nowMs) {
  const thisWeek = weekKeyForDay(pacificNow(new Date(nowMs)).dayKey);
  const [y, m, d] = thisWeek.split("-").map(Number);
  const prev = new Date(Date.UTC(y, m - 1, d - 7)).toISOString().slice(0, 10);
  return {thisWeek, lastWeek: prev};
}

/** Pure: the streak after a ranked battle completes. */
function streakAfterRanked(current, thisWeek, lastWeek) {
  const weeks = Number(current?.weeks) || 0;
  if (current?.weekKey === thisWeek) {
    return {weeks: Math.max(weeks, 1), weekKey: thisWeek, changed: false};
  }
  if (current?.weekKey === lastWeek && weeks > 0) {
    return {weeks: weeks + 1, weekKey: thisWeek, changed: true};
  }
  return {weeks: 1, weekKey: thisWeek, changed: true};
}

/** Best-effort: a streak failure never fails the match that earned it. */
async function recordRankedForStreak(uid, {nowMs = Date.now()} = {}) {
  try {
    const db = getFirestore();
    const ref = db.collection("users").doc(uid);
    const {thisWeek, lastWeek} = weekKeys(nowMs);
    return await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const next = streakAfterRanked(
          snap.data()?.rankedStreak, thisWeek, lastWeek);
      if (next.changed) {
        tx.set(ref, {
          rankedStreak: {weeks: next.weeks, weekKey: next.weekKey},
        }, {merge: true});
      }
      return next;
    });
  } catch (e) {
    console.error(`ranked streak for ${uid} failed:`, e.message);
    return null;
  }
}

module.exports = {
  weekKeyForDay,
  weekKeys,
  streakAfterRanked,
  recordRankedForStreak,
};
