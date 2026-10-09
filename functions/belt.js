const {onDocumentUpdated} = require("firebase-functions/v2/firestore");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");

/**
 * THE BELT - the app's one losable "title fight" honour.
 *
 * There is exactly ONE belt platform-wide, held by whoever most recently won
 * the Daily Gauntlet. Win tonight's gauntlet and you take it; win it again and
 * you have DEFENDED it (defenseCount++); if someone else wins, the belt changes
 * hands. A single scarce, losable title - the same shape as GOAT, deliberately
 * NOT a second ladder of many titles (see the one-status-ladder rule). It is
 * pure prestige: it touches no rating, no XP, no points.
 *
 * It lives at stats/belt, which firestore.rules already makes client-READABLE
 * and server-WRITE-ONLY - a client that could write it would crown itself.
 *
 * The award hooks a FORMAT-AGNOSTIC Firestore trigger on the tournament's
 * status -> "completed" transition, so it catches the climb sweep, the swiss
 * sweep, and any future format without touching each crowning site. Only the
 * Daily Gauntlet (createdBy "auto") awards the belt; a manually-created special
 * tournament carries its own prizes and never moves this title.
 */

const BELT_DOC = "belt";

/**
 * PURE. Given the current belt state and a freshly-crowned gauntlet champion,
 * what stats/belt should become - or null for "no change".
 *
 * Returns null when there is no winner (a cancelled gauntlet keeps the current
 * holder), and - the idempotency guard - when THIS tournament already awarded
 * the belt, so an at-least-once re-fire never double-counts a defense.
 */
function beltTransition(current, {championUid, championName, tournamentId, nowMs}) {
  if (!championUid) return null;
  if (current && current.sourceTournamentId === tournamentId) return null;
  const defending = !!current && current.holderUid === championUid;
  const name = championName ||
    (defending ? current.holderName : null) || null;
  return {
    holderUid: championUid,
    holderName: name,
    wonAtMs: nowMs,
    sourceTournamentId: tournamentId,
    defenseCount: defending ? (current.defenseCount || 0) + 1 : 0,
    previousHolderUid: defending ?
      (current.previousHolderUid ?? null) :
      (current ? current.holderUid : null),
  };
}

/** The belt is only contested in the nightly Daily Gauntlet. PURE. */
function isGauntlet(t) {
  return !!t && t.createdBy === "auto";
}

/** The crowned champion of a completed gauntlet, whatever the format wrote. */
function championOf(t) {
  if (!t) return null;
  return t.winnerId ||
    (t.swiss && t.swiss.championUid) ||
    (t.climb && t.climb.championUid) ||
    null;
}

/**
 * Award (or defend) the belt for a just-completed gauntlet. Best-effort and
 * idempotent. Looks up the champion's display name so the public banner never
 * has to resolve a uid.
 */
async function awardBeltForTournament(db, tournamentId, t, nowMs = Date.now()) {
  if (!isGauntlet(t)) return {awarded: false, reason: "not-gauntlet"};
  const championUid = championOf(t);
  if (!championUid) return {awarded: false, reason: "no-winner"};

  let championName = null;
  try {
    const u = await db.collection("users").doc(championUid).get();
    championName = u.exists ? (u.data().username || null) : null;
  } catch (_) {
    // Name is a convenience; the uid is what matters. Carry on without it.
  }

  const ref = db.collection("stats").doc(BELT_DOC);
  return db.runTransaction(async (tx) => {
    const cur = await tx.get(ref);
    const next = beltTransition(cur.exists ? cur.data() : null,
        {championUid, championName, tournamentId, nowMs});
    if (!next) return {awarded: false, reason: "no-change"};
    tx.set(ref, {...next, updatedAtMs: nowMs});
    return {awarded: true, holderUid: next.holderUid,
      defenseCount: next.defenseCount};
  });
}

/**
 * Record a PERMANENT tournament win on the champion's user doc. Unlike the
 * belt (gauntlet-only, losable), this counts EVERY tournament - the nightly
 * gauntlet, special events, brackets - and only ever rises. It drives the
 * "Tournament Champion" award badge (earned-and-kept, like the emoji awards).
 *
 * Idempotent via a `championRecorded` flag on the tournament doc, claimed in
 * the same transaction. (Writing that flag re-fires this trigger, but the
 * status is already "completed" by then, so the re-fire returns early.)
 */
async function recordTournamentWin(db, tournamentId, t) {
  const championUid = championOf(t);
  if (!championUid) return {recorded: false, reason: "no-winner"};
  const tRef = db.collection("tournaments").doc(tournamentId);
  const uRef = db.collection("users").doc(championUid);
  return db.runTransaction(async (tx) => {
    const tSnap = await tx.get(tRef);
    if (!tSnap.exists) return {recorded: false, reason: "gone"};
    if (tSnap.data().championRecorded === true) {
      return {recorded: false, reason: "already"};
    }
    const uSnap = await tx.get(uRef);
    // The champion of a live tournament is almost never a deleted account, but
    // skip the increment rather than resurrect a gone user doc; still claim the
    // flag so we never retry.
    if (uSnap.exists) {
      tx.update(uRef, {tournamentWins: FieldValue.increment(1)});
    }
    tx.update(tRef, {championRecorded: true});
    return {recorded: uSnap.exists, championUid};
  });
}

exports.onTournamentCompleted = onDocumentUpdated(
    "tournaments/{tournamentId}", async (event) => {
      const before = event.data && event.data.before &&
        event.data.before.data();
      const after = event.data && event.data.after && event.data.after.data();
      if (!after) return;
      const becameComplete = (!before || before.status !== "completed") &&
        after.status === "completed";
      if (!becameComplete || !after.winnerId) return;
      const db = getFirestore();
      const id = event.params.tournamentId;
      // Permanent win badge first (every tournament), then the belt (gauntlet
      // only). Independent and best-effort - one failing never blocks the other.
      await recordTournamentWin(db, id, after)
          .catch((err) => console.error(`win record ${id}:`, err.message));
      await awardBeltForTournament(db, id, after)
          .catch((err) => console.error(`belt award ${id}:`, err.message));
      // Prizes (points auto-award, non-cash recorded for fulfillment). Also
      // best-effort and independent - see prizes.js.
      await require("./prizes").awardPrizeForTournament(db, id, after)
          .catch((err) => console.error(`prize award ${id}:`, err.message));
    });

module.exports.beltTransition = beltTransition;
module.exports.isGauntlet = isGauntlet;
module.exports.championOf = championOf;
module.exports.awardBeltForTournament = awardBeltForTournament;
module.exports.recordTournamentWin = recordTournamentWin;
module.exports.BELT_DOC = BELT_DOC;
