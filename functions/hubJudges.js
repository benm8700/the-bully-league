const {getFirestore} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");
const {qualifyingWeek} = require("./weeklyQualifier");

/**
 * JUDGE VOLUNTEERING - the "I'll judge the Main Stage" opt-in.
 *
 * Today the Main Stage panel autofills from "whoever judged most last week",
 * whether or not that person wants to sit on a panel and be watched. That is
 * backwards: judging live on a broadcast is a role you should CHOOSE. So a seat
 * now takes two things - you VOLUNTEER (here), and you've judged enough battles
 * that week to qualify (the ballot-count metric the pool already uses). The
 * founder still hand-picks celebrity/guest seats; the rest autofill from
 * QUALIFIED VOLUNTEERS, ranked by how much they judged.
 *
 * Volunteering is stored per-week at
 *   judgeVolunteers/{weekKey}/volunteers/{uid}
 * where weekKey is the qualifying week's Thursday (cutoffDayKey). Keying by week
 * means the opt-in auto-resets every week - you say "I'm in" for THIS week's
 * show, not forever. The weekKey is derived SERVER-SIDE from the clock, so a
 * client can't volunteer for some other week.
 *
 * The roster the Judges tab shows (stats/weeklyJudges) and the panel autofill
 * (the snapshot's judgePool) are both built from this collection by the weekly
 * sweep - see weeklyTournament.js. This file owns the pure ranking rule + the
 * opt-in callable; the sweep owns the publishing.
 */

/** The ballots-judged-this-week bar to be AUTO-PICKED, bounds-checked from
 * config/tournament. A placeholder like the rest of the economy numbers. */
function resolveJudgeMinToQualify(cfg) {
  const n = Number(cfg && cfg.judgeMinToQualify);
  if (Number.isFinite(n) && n >= 0 && n <= 1000) return Math.floor(n);
  return 10;
}

/**
 * Rank this week's volunteers by how much they've judged. Pure.
 *
 * - `volunteerUids`: the uids who opted in this week.
 * - `judgeStandings`: [{uid, judged}] from computeJudgeStandings (all judges).
 * - `minToQualify`: the auto-pick bar.
 *
 * Returns [{uid, judged, qualified}] sorted most-judged first (then uid, so a
 * tie never ranks arbitrarily). A volunteer who hasn't judged yet appears with
 * judged:0, qualified:false - they're on the list (they raised their hand) but
 * not yet eligible for a seat, which is exactly the progress the UI shows.
 */
function rankVolunteers(volunteerUids, judgeStandings, minToQualify) {
  const counts = new Map(
      (judgeStandings || []).map((j) => [j.uid, Number(j.judged) || 0]));
  const seen = new Set();
  const rows = [];
  for (const uid of volunteerUids || []) {
    if (typeof uid !== "string" || !uid || seen.has(uid)) continue;
    seen.add(uid);
    const judged = counts.get(uid) || 0;
    rows.push({uid, judged, qualified: judged >= minToQualify});
  }
  return rows.sort((a, b) =>
    b.judged - a.judged ||
    (a.uid < b.uid ? -1 : a.uid > b.uid ? 1 : 0));
}

/**
 * The qualified-volunteer uids that may autofill the panel, ranked, with
 * finalists (who can't judge) removed. Pure - the sweep hands it the frozen
 * week's volunteers, judge standings, bar and finalist uids.
 */
function qualifiedPool(volunteerUids, judgeStandings, minToQualify, exclude) {
  const ex = new Set(exclude || []);
  return rankVolunteers(volunteerUids, judgeStandings, minToQualify)
      .filter((r) => r.qualified && !ex.has(r.uid))
      .map((r) => r.uid);
}

/** All volunteer uids for a given week key. */
async function collectVolunteers(db, weekKey) {
  const snap = await db.collection("judgeVolunteers").doc(weekKey)
      .collection("volunteers").get();
  const uids = [];
  snap.forEach((d) => uids.push(d.id));
  return uids;
}

/**
 * Opt in or out of judging THIS week's Main Stage. The week is resolved from
 * the clock here, so the client only sends whether it wants in.
 */
async function volunteerToJudge(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const opt = !(data && data.opt === false); // default to opting IN
  const db = getFirestore();

  const userSnap = await db.collection("users").doc(auth.uid).get();
  const user = userSnap.data() || {};
  if ((user.accountStatus || "active") !== "active") {
    throw new HttpsError("permission-denied", "This account can't judge.");
  }

  const weekKey = qualifyingWeek(Date.now()).cutoffDayKey;
  const ref = db.collection("judgeVolunteers").doc(weekKey)
      .collection("volunteers").doc(auth.uid);
  if (opt) {
    await ref.set({uid: auth.uid, at: Date.now()});
  } else {
    await ref.delete().catch(() => {});
  }
  return {ok: true, volunteered: opt, weekKey};
}

module.exports = {
  volunteerToJudge,
  collectVolunteers,
  // Pure, exported for the sweep + tests.
  rankVolunteers,
  qualifiedPool,
  resolveJudgeMinToQualify,
};
