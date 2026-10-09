const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {pacificWallClockToUtcMs} = require("./eventWindow");
const {applyResult, isComplete} = require("./mainStageBracket");
const {
  buildMainStageDoc,
  lockOutcome,
  inviteResponse,
  calloutResult,
  storeBracket,
  loadBracket,
} = require("./mainStageLifecycle");

/**
 * Main Stage tournament - the Firestore wiring around the pure lifecycle core.
 *
 * Lifecycle, all driven off the frozen qualifier snapshot:
 *   1. CREATE  - once a week has closed and its snapshot is frozen, create the
 *      tournament doc in "accepting" and invite the finalists + alternates.
 *   2. RESPOND - each invited player confirms or declines (callable).
 *   3. LOCK    - at Thu 4pm Pacific, resolve the confirmed field + 5-seat panel
 *      and freeze them (or cancel for lack of players). No 6pm scramble.
 *   4. CALLOUT - live on stage, the #1 seed calls out their semifinal opponent,
 *      which builds the bracket (callable).
 *   5. RESULTS - each battle's winner advances the bracket; the champion
 *      completes the tournament, which fires the existing onTournamentCompleted
 *      trigger (belt + prizes), identical to every other format.
 *
 * THE FAILSAFE: creation and the lock sweep are gated on
 * config/tournament.enabled, which ships FALSE - so no Main Stage tournament
 * ever appears, and the callables have nothing to act on, until the developer
 * flips it. The whole thing deploys inert. Same discipline as the qualifier and
 * the monetization system.
 *
 * The real-time battle transport (chess-clock mic/floor sync, the judges' room,
 * the broadcast, live panel voting) is the mainStageBattle core plus a live
 * client, built separately - this file is the deterministic skeleton that drives.
 */

const LOCK_HOUR_PACIFIC = 16; // Thu 4pm - field + panel freeze
const SHOW_HOUR_PACIFIC = 18; // Thu 6pm - the stage opens

/** Launch flag, bounds-checked: only a literal `true` enables it. */
function tournamentEnabled(data) {
  return !!(data && data.enabled === true);
}

/** Lock (4pm) and show (6pm) instants for a cutoff day (the Thursday). */
function scheduleFor(cutoffDayKey) {
  return {
    lockAtMs: pacificWallClockToUtcMs(cutoffDayKey, LOCK_HOUR_PACIFIC, 0),
    showAtMs: pacificWallClockToUtcMs(cutoffDayKey, SHOW_HOUR_PACIFIC, 0),
  };
}

const docIdFor = (cutoffDayKey) => `mainstage_${cutoffDayKey}`;

/** uids that must never sit on the panel: banned or flagged accounts. */
async function excludedJudgeUids(db, candidateUids) {
  const out = [];
  await Promise.all(candidateUids.map(async (uid) => {
    const snap = await db.collection("users").doc(uid).get();
    const status = snap.exists ? snap.data().accountStatus : null;
    if (status === "banned" || status === "flagged") out.push(uid);
  }));
  return out;
}

/**
 * Create the tournament doc from the frozen snapshot, once. Idempotent by the
 * derived doc id (mainstage_<cutoffDayKey>), so a repeated sweep is a no-op.
 * Returns {created, id, reason}.
 */
async function createFromSnapshot(db, now = Date.now()) {
  const snap = (await db.collection("stats").doc("weeklyQualifierSnapshot")
      .get()).data();
  if (!snap || !snap.tournamentDayKey) return {created: false, reason: "no-snapshot"};

  const id = docIdFor(snap.tournamentDayKey);
  const ref = db.collection("tournaments").doc(id);
  if ((await ref.get()).exists) return {created: false, id, reason: "exists"};

  const {lockAtMs, showAtMs} = scheduleFor(snap.tournamentDayKey);
  // Don't resurrect a show whose night has already passed (a job down for days
  // that recovers): the snapshot grace window makes this rare, but a lock time
  // already behind us means there's nothing to stage.
  if (now >= lockAtMs) return {created: false, id, reason: "too-late"};

  const doc = buildMainStageDoc({snapshot: snap, nowMs: now, lockAtMs, showAtMs});
  await ref.set({...doc, createdAt: FieldValue.serverTimestamp()});
  return {created: true, id};
}

/**
 * Lock any "accepting" tournament whose 4pm has arrived: freeze the confirmed
 * field + the 5-seat panel, or cancel if too few confirmed. Idempotent - only
 * acts on "accepting" docs, so a later tick leaves a locked one alone.
 */
async function lockDueTournaments(db, now = Date.now()) {
  const due = await db.collection("tournaments")
      .where("format", "==", "mainstage")
      .where("status", "==", "accepting")
      .get();
  const results = [];
  for (const d of due.docs) {
    const t = d.data();
    if (!(now >= t.lockAtMs)) continue;
    const exclude = await excludedJudgeUids(
        db, [...(t.judgePool || []), ...(t.handPickedJudges || [])]);
    const out = lockOutcome({
      finalists: t.finalists || [],
      alternates: t.alternates || [],
      invites: t.invites || {},
      judgePool: t.judgePool || [],
      handPicked: t.handPickedJudges || [],
      exclude,
    });
    if (out.cancel) {
      await d.ref.update({status: "cancelled", cancelReason: "not-enough-players",
        lockedAt: FieldValue.serverTimestamp()});
      results.push({id: d.id, cancelled: true});
    } else {
      await d.ref.update({
        status: "locked",
        field: out.field,
        judges: out.judges,
        judgeShortfall: out.judgeShortfall,
        judgeStandby: out.judgeStandby, // backfills a live judge no-show
        lockedAt: FieldValue.serverTimestamp(),
      });
      results.push({id: d.id, locked: true, field: out.field.length,
        judges: out.judges.length});
    }
  }
  return results;
}

/** The scheduled sweep: create then lock, both gated on the launch flag. */
async function sweepMainStage(now = Date.now()) {
  const db = getFirestore();
  const cfg = (await db.collection("config").doc("tournament").get()).data();
  if (!tournamentEnabled(cfg)) return {skipped: "disabled"};
  const created = await createFromSnapshot(db, now);
  const locked = await lockDueTournaments(db, now);
  return {created, locked};
}

/** A finalist/alternate confirms or declines (callable body). */
async function respondToInvite(auth, data) {
  if (!auth) throw httpsError("unauthenticated", "Must be signed in.");
  const {tournamentId, accept} = data || {};
  if (!tournamentId) throw httpsError("invalid-argument", "Missing tournamentId.");
  const db = getFirestore();
  const ref = db.collection("tournaments").doc(tournamentId);
  return db.runTransaction(async (tx) => {
    const doc = (await tx.get(ref)).data();
    const r = inviteResponse(doc, auth.uid, accept === true);
    if (!r.ok) throw httpsError("failed-precondition", r.error);
    tx.update(ref, {[`invites.${auth.uid}`]: r.status});
    return {ok: true, status: r.status};
  });
}

/** The founder hand-picks the panel seats (admin-only; set before the lock). */
async function setJudges(auth, data, isAdmin) {
  if (!isAdmin) throw httpsError("permission-denied", "Admin only.");
  const {tournamentId, judges} = data || {};
  if (!tournamentId) throw httpsError("invalid-argument", "Missing tournamentId.");
  if (!Array.isArray(judges)) throw httpsError("invalid-argument", "judges must be an array.");
  const db = getFirestore();
  const ref = db.collection("tournaments").doc(tournamentId);
  return db.runTransaction(async (tx) => {
    const doc = (await tx.get(ref)).data();
    if (!doc || (doc.status !== "accepting" && doc.status !== "locked")) {
      throw httpsError("failed-precondition", "Judges can only be set before the show.");
    }
    const picks = judges.filter((u) => typeof u === "string");
    // Hand-picked judges are provisional until they confirm, so they go on the
    // invite list (pending) exactly like finalists - respondToMainStageInvite
    // accepts anyone on that list. Don't clobber a judge who already answered.
    const invites = {...(doc.invites || {})};
    for (const uid of picks) {
      if (!(uid in invites)) invites[uid] = "pending";
    }
    tx.update(ref, {handPickedJudges: picks, invites});
    return {ok: true, count: picks.length};
  });
}

/** The #1 seed's live callout -> builds the bracket (callable body). */
async function callout(auth, data) {
  if (!auth) throw httpsError("unauthenticated", "Must be signed in.");
  const {tournamentId, pickUid} = data || {};
  if (!tournamentId || !pickUid) {
    throw httpsError("invalid-argument", "Missing tournamentId or pickUid.");
  }
  const db = getFirestore();
  const ref = db.collection("tournaments").doc(tournamentId);
  return db.runTransaction(async (tx) => {
    const doc = (await tx.get(ref)).data();
    const r = calloutResult(doc, auth.uid, pickUid);
    if (!r.ok) throw httpsError("failed-precondition", r.error);
    tx.update(ref, {bracket: storeBracket(r.bracket), status: "live"});
    return {ok: true, bracket: r.bracket};
  });
}

/**
 * Record a Main Stage battle's winner and advance the bracket. Called by the
 * (parked) live battle-settle path. Idempotent via the bracket's own
 * applyResult. When the final settles, writes winnerId, which fires the shared
 * onTournamentCompleted trigger (belt + prizes) exactly like every other
 * format - no special-casing downstream.
 */
async function recordBattleResult(db, tournamentId, roundIdx, matchIdx, winnerUid) {
  const ref = db.collection("tournaments").doc(tournamentId);
  return db.runTransaction(async (tx) => {
    const doc = (await tx.get(ref)).data();
    if (!doc || doc.status !== "live" || !doc.bracket) {
      return {ok: false, reason: "not-live"};
    }
    const next = applyResult(loadBracket(doc.bracket), roundIdx, matchIdx,
        winnerUid);
    const update = {bracket: storeBracket(next)};
    let completed = false;
    if (isComplete(next)) {
      update.status = "completed";
      update.winnerId = next.champion;
      update.completedAt = FieldValue.serverTimestamp();
      completed = true;
    }
    tx.update(ref, update);
    return {ok: true, completed, champion: next.champion || null};
  });
}

// A tiny HttpsError shim so the callable bodies can live here (pure-ish) and
// the index.js wrappers just pass auth/data through. Lazily required to avoid
// pulling firebase-functions into the pure test path.
function httpsError(code, message) {
  const {HttpsError} = require("firebase-functions/v2/https");
  return new HttpsError(code, message);
}

module.exports = {
  LOCK_HOUR_PACIFIC,
  SHOW_HOUR_PACIFIC,
  tournamentEnabled,
  scheduleFor,
  docIdFor,
  createFromSnapshot,
  lockDueTournaments,
  sweepMainStage,
  respondToInvite,
  setJudges,
  callout,
  recordBattleResult,
};
