const {getFirestore, FieldValue} = require("firebase-admin/firestore");

/**
 * TEMPORARY one-shot armer for the first real Main Stage capture (2026-10-22).
 *
 * The tournament system ships behind config/tournament.enabled = false. For the
 * first full-flow capture we want the "finalists + judges picked and notified"
 * moment to fire on the REAL clock (just after the Thu 00:00 Pacific cutoff),
 * hands-off. So this job, every 10 min:
 *   1. flips config/tournament.enabled true ONCE, when now >= armAtMs; and
 *   2. once the tournament doc exists and is still "accepting", auto-accepts the
 *      invites in config/tournament.autoAcceptUids (the finalists the developer
 *      is NOT filming the accept flow on) - idempotent, pending->accepted only,
 *      so the ONE left pending (bigdick69) goes through the real accept flow.
 *
 * Idempotent and self-silencing. Reads everything from config so there is no
 * hardcoded date/uid. REMOVE THIS JOB after the event (delete the file, its
 * export in index.js, and its scheduledJobScan entry; clear the config keys).
 */
async function armTournamentIfDue(now = Date.now()) {
  const db = getFirestore();
  const ref = db.collection("config").doc("tournament");
  const cfg = (await ref.get()).data() || {};
  const out = {};

  // 1. Arm: flip the flag once the cutoff has arrived.
  if (cfg.enabled !== true) {
    const armAtMs = Number(cfg.armAtMs);
    if (!Number.isFinite(armAtMs)) return {skipped: "no-armAtMs"};
    if (now < armAtMs) return {skipped: "not-yet", inMinutes: Math.round((armAtMs - now) / 60000)};
    await ref.set({enabled: true, armedAt: FieldValue.serverTimestamp()}, {merge: true});
    out.armed = true;
  }

  // 2. Pre-accept the configured finalists once the tournament has been built.
  const autoAccept = Array.isArray(cfg.autoAcceptUids) ? cfg.autoAcceptUids : [];
  const dayKey = cfg.captureDayKey;
  if (autoAccept.length && dayKey) {
    const tref = db.collection("tournaments").doc(`mainstage_${dayKey}`);
    const tsnap = await tref.get();
    if (tsnap.exists && tsnap.data().status === "accepting") {
      const invites = tsnap.data().invites || {};
      const upd = {};
      for (const uid of autoAccept) {
        if (invites[uid] === "pending") upd[`invites.${uid}`] = "accepted";
      }
      if (Object.keys(upd).length) {
        await tref.update(upd);
        out.preAccepted = Object.keys(upd).length;
      }
    }
  }

  return Object.keys(out).length ? out : {skipped: "done-or-waiting"};
}

module.exports = {armTournamentIfDue};
