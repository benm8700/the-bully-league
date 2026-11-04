const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {pacificWallClockToUtcMs} = require("./eventWindow");
const {
  applyResult,
  isComplete,
  stampOpened,
  stuckMatchupOutcome,
} = require("./mainStageBracket");
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

/** How long past 6pm the #1 gets to make the dramatic callout before the show
 * auto-starts without them. Soft enforcement: the show opens at ~6 regardless
 * of whether the #1 acts, but it is never longer than this + the sweep cadence.
 * It only auto-opens the STAGE (builds the bracket, goes live) - the battles
 * themselves stay player-initiated, with the forfeit sweep for no-shows. */
const AUTO_START_GRACE_MS = 3 * 60 * 1000;

/**
 * Whether a locked show is overdue to start: 6pm + the grace has passed and
 * the #1 still hasn't called out (status is still "locked", not "live"). PURE.
 */
function shouldAutoStart(doc, now) {
  return !!doc && doc.status === "locked" &&
    Number.isFinite(doc.showAtMs) &&
    now >= doc.showAtMs + AUTO_START_GRACE_MS &&
    Array.isArray(doc.field) && doc.field.length === 4;
}

/**
 * The time-enforcement backstop: start any locked show whose 6pm (+grace) has
 * passed without the #1's callout, so the semis begin at ~6 even if the #1
 * ghosts. Auto-uses standard seeding - #1 (field[0]) vs the bottom seed - and
 * goes live, then nudges everyone in via notifyShowLive. Idempotent (only acts
 * on "locked"). Reuses the format+status index lockDueTournaments already has.
 */
async function autoStartDueShows(db, now = Date.now()) {
  const due = await db.collection("tournaments")
      .where("format", "==", "mainstage")
      .where("status", "==", "locked")
      .get();
  const results = [];
  for (const d of due.docs) {
    const doc = d.data();
    if (!shouldAutoStart(doc, now)) continue;
    const field = doc.field;
    const r = calloutResult(doc, field[0], field[field.length - 1]);
    if (!r.ok) {
      results.push({id: d.id, error: r.error});
      continue;
    }
    await d.ref.update({
      // Stamp openedMs on the semis so the stuck-matchup backstop can tell a
      // no-show from a battle that just hasn't started yet.
      bracket: storeBracket(stampOpened(r.bracket, now)),
      status: "live",
      autoStarted: true,
    });
    try {
      const {notifyShowLive} = require("./mainStageNotify");
      await notifyShowLive(d.id, {...doc, status: "live"});
    } catch (e) {
      console.error("auto-start notifyShowLive failed:", e.message);
    }
    results.push({id: d.id, autoStarted: true});
  }
  return results;
}

/** The scheduled sweep: create tonight's tournament, lock the field at the
 * cutoff, and finish any battle the panel already DECIDED whose 30s grace has
 * elapsed (a backstop, in case every client left before nudging the settle) -
 * all gated on the launch flag. There is deliberately NO deadline force-close
 * on an UNDECIDED battle: a debate runs as long or short as it needs, and a
 * battle settles only when the panel reaches a verdict, not on a clock. */
async function sweepMainStage(now = Date.now()) {
  const db = getFirestore();
  const cfg = (await db.collection("config").doc("tournament").get()).data();
  if (!tournamentEnabled(cfg)) return {skipped: "disabled"};
  const created = await createFromSnapshot(db, now);
  const locked = await lockDueTournaments(db, now);
  // Backstop AFTER locking, so a show locked and overdue in the same tick can
  // still auto-start this run.
  const autoStarted = await autoStartDueShows(db, now);
  const {settleDecidedBattles, forceResolveStalledBattles} =
      require("./mainStagePlay");
  // Force a verdict on any FINISHED battle the panel never decided (a stalled /
  // absent panel must not halt the bracket), advance any matchup a no-show
  // never started or abandoned, then settle everything decided.
  const forced = await forceResolveStalledBattles(db, now);
  const advanced = await forceAdvanceStuckMatchups(db, now);
  const settled = await settleDecidedBattles(db, now);
  return {created, locked, autoStarted, forced, advanced, settled};
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
  const result = await db.runTransaction(async (tx) => {
    const doc = (await tx.get(ref)).data();
    const r = calloutResult(doc, auth.uid, pickUid);
    if (!r.ok) throw httpsError("failed-precondition", r.error);
    tx.update(ref,
        {bracket: storeBracket(stampOpened(r.bracket, Date.now())), status: "live"});
    return {ok: true, bracket: r.bracket, doc};
  });
  // The show is now live - pull the finalists and judges in (best-effort).
  try {
    const {notifyShowLive} = require("./mainStageNotify");
    await notifyShowLive(tournamentId, result.doc);
  } catch (e) {
    console.error("notifyShowLive failed:", e.message);
  }
  return {ok: true, bracket: result.bracket};
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
  const result = await db.runTransaction(async (tx) => {
    const doc = (await tx.get(ref)).data();
    if (!doc || doc.status !== "live" || !doc.bracket) {
      return {ok: false, reason: "not-live"};
    }
    const next = applyResult(loadBracket(doc.bracket), roundIdx, matchIdx,
        winnerUid);
    // Stamp openedMs on the final the moment both semis settle (it just became
    // ready), so it too has the no-show clock. Semis keep their earlier stamp.
    const update = {bracket: storeBracket(stampOpened(next, Date.now()))};
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
  // If advancing just made the FINAL ready (both semis done), carry the two
  // finalists to the final. Best-effort + deduped; skipped if the bracket is
  // already complete.
  if (result.ok && !result.completed) {
    try {
      const {notifyFinalReady} = require("./mainStageNotify");
      const fresh = (await ref.get()).data();
      await notifyFinalReady(tournamentId, fresh);
    } catch (e) {
      console.error("notifyFinalReady failed:", e.message);
    }
  }
  return result;
}

// A ready matchup that produces no result for this long is force-advanced, so a
// no-show / abandon can't halt the single-elimination show. Generous enough
// never to cut a real battle short - a Main Stage battle runs well under this
// from start to finish. (The JUDGING stall, after a battle completes, is handled
// separately by forceResolveStalledBattles.)
const MATCHUP_NOSHOW_MS = 20 * 60 * 1000;

/**
 * Backstop: advance any ready matchup that has produced no result for too long -
 * a battle nobody ever started (no matchId past its openedMs) or one started and
 * abandoned before it could complete. The player who showed (startedBy) advances
 * over the one who didn't; if nobody started, the higher seed does. Never touches
 * a FINISHED-but-undecided battle - that is the judging sweep's job. Best-effort
 * per matchup; each recordBattleResult re-reads the doc, so advancing several in
 * one run is safe.
 */
async function forceAdvanceStuckMatchups(db, now = Date.now()) {
  const snap = await db.collection("tournaments")
      .where("format", "==", "mainstage")
      .where("status", "==", "live").get();
  const out = [];
  for (const d of snap.docs) {
    const t = d.data();
    if (!t.bracket) continue;
    const bracket = loadBracket(t.bracket);
    for (let ri = 0; ri < bracket.rounds.length; ri++) {
      const round = bracket.rounds[ri] || [];
      for (let mi = 0; mi < round.length; mi++) {
        const m = round[mi];
        if (!m || m.a == null || m.b == null || m.winner != null) continue;
        let matchInfo = null;
        if (m.matchId) {
          const md =
            (await db.collection("matches").doc(m.matchId).get()).data();
          // A missing match doc is treated as never-started, so openedMs is
          // still the clock.
          matchInfo = md ? {
            status: md.status,
            judgeWinnerId: md.judgeWinnerId,
            startedBy: md.startedBy,
            createdMs: md.createdAt && md.createdAt.toMillis ?
              md.createdAt.toMillis() : 0,
          } : null;
        }
        const outcome =
          stuckMatchupOutcome(m, matchInfo, now, MATCHUP_NOSHOW_MS);
        if (!outcome) continue;
        try {
          const r = await recordBattleResult(db, d.id, ri, mi, outcome.winner);
          if (r.ok) {
            out.push({tournamentId: d.id, roundIdx: ri, matchIdx: mi});
            // Tidy the abandoned battle doc so it doesn't linger pending.
            if (m.matchId) {
              await db.collection("matches").doc(m.matchId)
                  .update({status: "abandoned"}).catch(() => {});
            }
          }
        } catch (e) {
          console.error(
              `mainstage force-advance ${d.id} r${ri}m${mi}:`, e.message);
        }
      }
    }
  }
  return out;
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
  forceAdvanceStuckMatchups,
  autoStartDueShows,
  shouldAutoStart,
  AUTO_START_GRACE_MS,
};
