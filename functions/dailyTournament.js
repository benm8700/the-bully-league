const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {
  readEventWindowConfig, upcomingWindowDayKey, pacificWallClockToUtcMs,
} = require("./eventWindow");

/**
 * The daily auto-created live tournament that runs inside Sixes and Sevens.
 *
 * Sixes and Sevens IS the nightly tournament (CLAUDE.md): put the tournament
 * where the crowd already is (peak concurrency) and collapse two
 * appointments into one. This creates tonight's live tournament ahead of
 * time so check-in can open at the top of the window.
 *
 * Timing: the window opens at `startHourPacific` (6pm). Players get the first
 * 15 minutes to JOIN and check in, and the bracket KICKS OFF at 6:15. So the
 * tournament's `startsAtMs` is 6:15pm Pacific, and check-in (which opens
 * `checkInLeadMs` = 15 min before start) opens at 6:00 - the top of the
 * window. The live sweep (advanceLiveTournaments) builds the bracket at
 * 6:15 from whoever checked in.
 */

/** The bracket kicks off this many minutes into the window (the join window
 * is the first 15 minutes). */
const KICKOFF_MINUTE = 15;

/** Create tonight's tournament at most this long before check-in opens - no
 * point minting it at 3am, and creating it a few hours ahead is plenty. */
const CREATE_LEAD_MS = 3 * 60 * 60 * 1000;

/** Check-in opens this long before kickoff (mirrors liveTournament's
 * DEFAULT_CHECKIN_LEAD_MS - kept here so the plan is pure). */
const CHECKIN_LEAD_MS = 15 * 60 * 1000;

/**
 * FIRST-NIGHTS GRACE (developer's call): the bracket runs as soon as at
 * least this many people are checked in, rather than demanding a full field.
 * The golden parachute cancels + refunds below this. Set low for the beta so
 * a thin turnout still produces a real event; raise it once there is volume.
 */
const DEFAULT_MIN_ENTRANTS = 2;

/**
 * Pure: given the current time and the window config, decide whether to
 * (idempotently) create tonight's tournament, and with what start time.
 * Testable without Firestore or a live clock.
 */
function dailyTournamentPlan(nowMs, config) {
  if (!config || !config.enabled) {
    return {create: false, reason: "window-disabled"};
  }
  const dayKey = upcomingWindowDayKey(new Date(nowMs), config);
  const startsAtMs =
    pacificWallClockToUtcMs(dayKey, config.startHourPacific, KICKOFF_MINUTE);
  const checkInOpensAt = startsAtMs - CHECKIN_LEAD_MS;

  if (nowMs >= startsAtMs) {
    // Past kickoff - too late to create tonight's (creating it now would
    // start an event nobody could check into).
    return {create: false, reason: "already-started", dayKey, startsAtMs};
  }
  if (nowMs < checkInOpensAt - CREATE_LEAD_MS) {
    return {create: false, reason: "too-early", dayKey, startsAtMs};
  }
  return {
    create: true,
    dayKey,
    startsAtMs,
    name: (config.name && config.name.trim()) || "Sixes and Sevens",
  };
}

/**
 * Reads the window config, computes the plan, and creates tonight's live
 * tournament if it is time and one has not already been made. Idempotent via
 * a marker keyed by Pacific day (claimed inside a transaction), so repeated
 * polls never mint duplicates.
 */
async function ensureDailyTournament(nowMs = Date.now()) {
  const db = getFirestore();
  let configDoc = null;
  try {
    configDoc = (await db.collection("config").doc("eventWindow").get()).data();
  } catch (e) {
    return {created: false, reason: "config-read-failed", error: e.message};
  }
  const config = readEventWindowConfig(configDoc);
  const plan = dailyTournamentPlan(nowMs, config);
  if (!plan.create) return {created: false, reason: plan.reason, dayKey: plan.dayKey};

  const markerRef = db.collection("stats").doc("dailyTournament");
  // Claim the day BEFORE creating, so two overlapping polls cannot both
  // create tonight's tournament.
  const claimed = await db.runTransaction(async (tx) => {
    const snap = await tx.get(markerRef);
    if (snap.exists && snap.data().lastCreatedDayKey === plan.dayKey) {
      return false;
    }
    tx.set(markerRef, {
      lastCreatedDayKey: plan.dayKey,
      lastCreatedAtMs: nowMs,
    }, {merge: true});
    return true;
  });
  if (!claimed) {
    return {created: false, reason: "already-created", dayKey: plan.dayKey};
  }

  // The nightly event is a CLIMB (rolling single-elimination), not a
  // pre-seeded bracket - so there is no 6:15 lock. It runs for the whole
  // window: join any time between the start and end hours, climb by beating
  // same-tier winners, lose once and you're out. windowStartMs/windowEndMs
  // are the 6-7pm Pacific bounds joinClimb and sweepClimb gate on.
  const windowStartMs =
    pacificWallClockToUtcMs(plan.dayKey, config.startHourPacific, 0);
  const windowEndMs =
    pacificWallClockToUtcMs(plan.dayKey, config.endHourPacific, 0);
  const tournamentRef = db.collection("tournaments").doc();
  await tournamentRef.set({
    name: plan.name,
    format: "climb",
    status: "in_progress",
    windowStartMs,
    windowEndMs,
    createdBy: "auto",
    eventDayKey: plan.dayKey,
    // Points prize to start (the developer sets the value per night; 0 means
    // no prize). Cash is the future switch that turns on the geofencing/tax
    // machinery, so it stays points-only here.
    prizeType: "points",
    prizeValue: 0,
    climb: {climbers: []},
    // The tournament list orders by createdAt, so one without it is invisible
    // in the app even though it exists in Firestore.
    createdAt: FieldValue.serverTimestamp(),
    createdAtMs: nowMs,
  });

  return {
    created: true,
    dayKey: plan.dayKey,
    tournamentId: tournamentRef.id,
    startsAtMs: plan.startsAtMs,
  };
}

module.exports = {
  dailyTournamentPlan, ensureDailyTournament,
  KICKOFF_MINUTE, CHECKIN_LEAD_MS, CREATE_LEAD_MS, DEFAULT_MIN_ENTRANTS,
};
