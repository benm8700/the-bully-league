/**
 * Reading back a player's rating history.
 *
 * THE RECORDING IS THE IRREPLACEABLE HALF. A rating update overwrites the
 * previous value, so an entry not written at finalization time can never
 * be recovered - nothing else in the system remembers what a rating was
 * before a match. Everything here is just a view over that.
 *
 * The summary is deliberately about FORM rather than totals. Wins and
 * losses are already on the profile; what a competitive player cannot see
 * anywhere is whether they are currently climbing or sliding, which is the
 * question the ladder actually provokes.
 */

const {getFirestore} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");

/** How many entries a summary looks back over. Enough to show a trend,
 * short enough that one bad night still registers. */
const FORM_WINDOW = 10;

/**
 * Condenses history into something worth showing.
 *
 * Pure, and takes entries NEWEST FIRST, which is the order a Firestore
 * query returns them in.
 */
function summarise(entries, {window = FORM_WINDOW} = {}) {
  if (!Array.isArray(entries) || entries.length === 0) {
    return {matches: 0, form: null, netChange: 0, best: null, streak: null};
  }
  const recent = entries.slice(0, window);
  const netChange = recent.reduce((sum, e) => sum + (Number(e.delta) || 0), 0);

  // The current run, counted from the most recent match backwards. Stops
  // at the first result that breaks it, so a 3-win streak after a loss
  // reads as 3 rather than being diluted by older history.
  let streak = null;
  for (const e of entries) {
    // A draw breaks a streak rather than extending either kind: neither
    // player won, so calling it part of a winning run would be a lie.
    if (typeof e.won !== "boolean") break;
    if (streak === null) {
      streak = {type: e.won ? "win" : "loss", count: 1};
    } else if ((streak.type === "win") === e.won) {
      streak.count += 1;
    } else {
      break;
    }
  }

  const best = entries.reduce((top, e) =>
    (Number(e.ratingAfter) || 0) > (Number(top?.ratingAfter) || 0) ? e : top,
  null);

  return {
    matches: entries.length,
    windowMatches: recent.length,
    netChange,
    // Only ever describes the recent window, never all time.
    form: netChange > 0 ? "climbing" : netChange < 0 ? "sliding" : "level",
    streak,
    peakRating: best ? Number(best.ratingAfter) || null : null,
  };
}

/**
 * A player's own rating history and its summary.
 *
 * Own history only. Someone else's form is competitive information, and
 * CLAUDE.md is explicit that opponent rating stays hidden - serving a
 * stranger's rating trend would walk straight around that.
 */
async function getMyRatingHistory(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const limit = Math.min(50, Math.max(1, Number(data?.limit) || 20));
  const snap = await getFirestore()
      .collection("users").doc(auth.uid)
      .collection("ratingHistory")
      .orderBy("at", "desc")
      .limit(limit)
      .get();

  const entries = snap.docs.map((d) => {
    const e = d.data();
    return {
      matchId: d.id,
      ratingBefore: e.ratingBefore ?? null,
      ratingAfter: e.ratingAfter ?? null,
      delta: e.delta ?? 0,
      won: e.won ?? null,
      voteConfidence: e.voteConfidence ?? null,
      atMs: e.at?.toMillis?.() ?? null,
    };
  });
  return {entries, summary: summarise(entries)};
}

module.exports = {getMyRatingHistory, summarise, FORM_WINDOW};
