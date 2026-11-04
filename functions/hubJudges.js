const {getFirestore} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");
const {qualifyingWeek} = require("./weeklyQualifier");
const {spendPoints} = require("./clipGrants");

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
 * THE APPLY FEE - the economy model's "panel seats" sink, done right.
 *
 * You don't BUY a seat (selection stays pure merit - founder hand-picks + the
 * most-judged applicants). You pay a fixed, NON-REFUNDABLE points fee just to
 * APPLY for the current qualifying PERIOD. An active judge earns points easily,
 * so the fee is a trivial unlock for them and a real one for a drive-by; and
 * because it's spent win-or-lose, it keeps people earning for the next one.
 * A pure points sink.
 *
 * CADENCE-NEUTRAL: the fee keys off qualifyingWeek().cutoffDayKey - the single
 * definition of "the current qualifying period" that the applicant collection
 * and the tournament snapshot also use. It is one fee PER PERIOD, whatever that
 * period is. If the cadence becomes monthly, that is changed in the one period
 * definition (+ the lock/show schedule) and the fee follows with NO change
 * here. Nothing about the fee assumes a week; "week" in names/ids is cosmetic.
 *
 * Gated on config/tournament.enabled AND judgeApplyFeeEnabled, both off by
 * default, so applying is FREE (today's behaviour) until the flag flips. The
 * price is a placeholder in config/tournament, per the advisor-review record.
 */
const APPLY_FEE_DEFAULT = 50;
function resolveApplyFee(cfg) {
  const enabled = !!(cfg && cfg.enabled === true &&
    cfg.judgeApplyFeeEnabled === true);
  let fee = Number(cfg && cfg.judgeApplyFee);
  if (!(Number.isFinite(fee) && fee >= 1 && fee <= 1_000_000)) {
    fee = APPLY_FEE_DEFAULT;
  }
  return {enabled, fee};
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
 * APPLY to judge (or withdraw) THIS week's Main Stage. The week is resolved from
 * the clock here, so the client only sends whether it wants in.
 *
 * Applying charges the fixed fee once per qualifying PERIOD (idempotent on the
 * ledger key, so withdrawing and re-applying in the same period never
 * double-charges). The fee is NON-REFUNDABLE: withdrawing deletes your
 * application but never returns the points - it's a sink, spent win-or-lose.
 * Selection remains pure merit.
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

  if (!opt) {
    // Withdraw. No refund - the apply fee is spent whether or not you got a
    // seat (that is the whole point of the sink).
    await ref.delete().catch(() => {});
    return {ok: true, volunteered: false, weekKey};
  }

  // Applying. Charge the fee first (the authoritative gate) so an unaffordable
  // application never lands in the pool; then record it.
  const cfg = (await db.collection("config").doc("tournament").get()).data();
  const {enabled: feeOn, fee} = resolveApplyFee(cfg);
  let feeCharged = false;
  if (feeOn && fee > 0) {
    const spend = await spendPoints(auth.uid, {
      reason: "judgeApply", sourceId: weekKey, amount: fee,
    });
    if (spend.spent === 0 && spend.reason === "insufficient") {
      throw new HttpsError("failed-precondition",
          `Applying to judge costs ${fee} points - you have ${spend.balance}.`,
          {reason: "insufficient"});
    }
    feeCharged = spend.spent > 0; // false when already applied this week
  }
  await ref.set({
    uid: auth.uid, at: Date.now(),
    ...(feeCharged ? {paidAt: Date.now()} : {}),
  }, {merge: true});
  return {ok: true, volunteered: true, weekKey, fee: feeOn ? fee : 0,
    feeCharged};
}

module.exports = {
  volunteerToJudge,
  collectVolunteers,
  // Pure, exported for the sweep + tests.
  rankVolunteers,
  qualifiedPool,
  resolveJudgeMinToQualify,
  resolveApplyFee,
};
