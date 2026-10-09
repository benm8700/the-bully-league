const {getFirestore, FieldValue, Timestamp} =
  require("firebase-admin/firestore");
const {
  qualifyingWeek,
  mostRecentlyClosedWeek,
  computeStandings,
  computeJudgeStandings,
  topN,
} = require("./weeklyQualifier");

/**
 * Weekly tournament qualifier - the Firestore wiring around the pure core.
 *
 * Two jobs in one sweep, both reading the week's rating changes with a single
 * collection-group query over everyone's `ratingHistory` (cost scales with
 * matches that week, not total users) and feeding the pure `computeStandings`:
 *   1. LIVE BOARD - publish the current week's standings to
 *      `stats/weeklyQualifier`, which clients read through one cheap listener
 *      (the publishOnlineCount pattern: a fixed per-tick cost, not per-client).
 *   2. CUTOFF SNAPSHOT - when a week has just closed (Wed 11:59pm PST), freeze
 *      the final top-4 + 4 alternates to `stats/weeklyQualifierSnapshot`, once.
 *
 * THE FAILSAFE: everything here is gated on `config/tournament.enabled`, which
 * ships FALSE. Until the developer flips it, this sweep no-ops - the whole
 * tournament (board included) stays inert, so it can be built and deployed long
 * before launch without changing anything a user sees. Same discipline as the
 * monetization system.
 *
 * Both target documents sit under the existing `stats/{document}` and
 * `config/{document}` rules (client-read, server-write), so NO rules change is
 * needed.
 */

const FINALISTS = 4;
const ALTERNATES = 4;
const MIN_GAMES = 5; // matches the decision record's eligibility floor
const LIVE_BOARD_SIZE = 50; // enough to show a real board without bloat
// The most-judged-this-week pool frozen alongside the finalists: enough to
// autofill a 5-seat panel after excluding finalists, hand-picks and the
// ineligible, with comfortable margin. judgePanel.selectPanel consumes it.
const JUDGE_POOL_SIZE = 25;
// Only snapshot a cutoff that closed RECENTLY, so a job that was down for days
// and recovers doesn't freeze a stale week. Thu 00:00 -> comfortably before the
// Thu 6pm show; idempotency (below) stops a re-snapshot within the window.
const SNAPSHOT_GRACE_MS = 18 * 60 * 60 * 1000;

/** The launch flag, bounds-checked: only a literal `true` enables it, so a
 * missing/garbled config is treated as OFF (fail safe, never fail open). */
function readTournamentConfig(data) {
  return {enabled: !!(data && data.enabled === true)};
}

/**
 * All ratingHistory entries whose `at` falls in [startMs, endMs), across every
 * user, as {uid, delta, mode, at}. The uid is the grandparent doc id
 * (users/{uid}/ratingHistory/{matchId}). Admin SDK, so it reads across users
 * regardless of the per-user read rule.
 */
async function collectWeekEntries(db, startMs, endMs) {
  const snap = await db.collectionGroup("ratingHistory")
      .where("at", ">=", Timestamp.fromMillis(startMs))
      .where("at", "<", Timestamp.fromMillis(endMs))
      .get();
  const entries = [];
  snap.forEach((doc) => {
    const parent = doc.ref.parent.parent; // the users/{uid} doc
    const uid = parent && parent.id;
    if (!uid) return;
    const d = doc.data();
    entries.push({uid, delta: d.delta, mode: d.mode, at: d.at});
  });
  return entries;
}

/**
 * All ballots cast in [startMs, endMs), across every match, as {uid, at}. The
 * voter's uid is the ballot doc id (votes/{matchId}/ballots/{voterId}), and the
 * ballot's time is its `timestamp`. Feeds the most-judged-this-week pool.
 */
async function collectWeekBallots(db, startMs, endMs) {
  const snap = await db.collectionGroup("ballots")
      .where("timestamp", ">=", Timestamp.fromMillis(startMs))
      .where("timestamp", "<", Timestamp.fromMillis(endMs))
      .get();
  const ballots = [];
  snap.forEach((doc) => {
    ballots.push({uid: doc.id, at: doc.data().timestamp});
  });
  return ballots;
}

async function sweepWeeklyQualifier(now = Date.now()) {
  const db = getFirestore();
  const cfgSnap = await db.collection("config").doc("tournament").get();
  if (!readTournamentConfig(cfgSnap.data()).enabled) {
    return {skipped: "disabled"}; // THE FAILSAFE - nothing is live until flipped
  }

  // 1. LIVE BOARD - current week's running standings.
  const week = qualifyingWeek(now);
  const liveEntries = await collectWeekEntries(
      db, week.startMs, Math.min(now, week.cutoffMs));
  const live = computeStandings(liveEntries, {
    startMs: week.startMs, cutoffMs: week.cutoffMs, minGames: MIN_GAMES,
  });
  await db.collection("stats").doc("weeklyQualifier").set({
    tournamentDayKey: week.cutoffDayKey,
    startMs: week.startMs,
    cutoffMs: week.cutoffMs,
    standings: topN(live, LIVE_BOARD_SIZE),
    eligibleCount: live.length,
    updatedAt: FieldValue.serverTimestamp(),
  });

  // 2. CUTOFF SNAPSHOT - freeze the field once, when a week has just closed.
  const closed = mostRecentlyClosedWeek(now);
  const sincecutoff = now - closed.cutoffMs;
  let snapshot = null;
  if (sincecutoff >= 0 && sincecutoff <= SNAPSHOT_GRACE_MS) {
    const snapRef = db.collection("stats").doc("weeklyQualifierSnapshot");
    const existing = (await snapRef.get()).data();
    // Idempotent: the snapshot for a given tournament day is written once. A
    // later tick within the grace window sees the key already stored and
    // leaves it alone, so the field can never be re-frozen mid-acceptance.
    if (!existing || existing.tournamentDayKey !== closed.cutoffDayKey) {
      const entries = await collectWeekEntries(
          db, closed.startMs, closed.cutoffMs);
      const standings = computeStandings(entries, {
        startMs: closed.startMs, cutoffMs: closed.cutoffMs, minGames: MIN_GAMES,
      });
      const finalists = topN(standings, FINALISTS);
      const alternates = standings.slice(FINALISTS, FINALISTS + ALTERNATES);
      // The most-judged-this-week pool, frozen alongside the field, for the
      // panel autofill (judgePanel.selectPanel adds the founder's hand-picks
      // and excludes finalists). Finalists can't judge, so drop them here too.
      const ballots = await collectWeekBallots(
          db, closed.startMs, closed.cutoffMs);
      const finalistSet = new Set(finalists.map((f) => f.uid));
      const judgePool = computeJudgeStandings(ballots, {
        startMs: closed.startMs, cutoffMs: closed.cutoffMs,
      }).filter((j) => !finalistSet.has(j.uid)).slice(0, JUDGE_POOL_SIZE);
      await snapRef.set({
        tournamentDayKey: closed.cutoffDayKey,
        startMs: closed.startMs,
        cutoffMs: closed.cutoffMs,
        finalists,
        alternates,
        judgePool,
        snapshotAt: FieldValue.serverTimestamp(),
      });
      snapshot = {
        tournamentDayKey: closed.cutoffDayKey,
        finalists: finalists.length,
        alternates: alternates.length,
        judgePool: judgePool.length,
      };
    }
  }

  return {live: live.length, snapshot};
}

module.exports = {
  sweepWeeklyQualifier,
  collectWeekEntries,
  readTournamentConfig,
  FINALISTS,
  ALTERNATES,
  MIN_GAMES,
  SNAPSHOT_GRACE_MS,
};
