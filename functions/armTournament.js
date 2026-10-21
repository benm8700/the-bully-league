const {getFirestore, FieldValue} = require("firebase-admin/firestore");

/**
 * TEMPORARY one-shot armer for the first real Main Stage capture (2026-10-22).
 *
 * The tournament system ships behind config/tournament.enabled = false. For the
 * first full-flow capture we want the "finalists + judges picked and notified"
 * moment to fire on the REAL clock (just after the Thu 00:00 Pacific cutoff),
 * hands-off, rather than someone flipping a switch at midnight. So this job
 * flips the flag true ONCE, when now >= config/tournament.armAtMs.
 *
 * Idempotent and self-silencing: once enabled it no-ops forever. Reads armAtMs
 * from config so there is no hardcoded date. REMOVE THIS JOB after the event
 * (delete the file, its export in index.js, and its scheduledJobScan entry).
 */
async function armTournamentIfDue(now = Date.now()) {
  const db = getFirestore();
  const ref = db.collection("config").doc("tournament");
  const cfg = (await ref.get()).data() || {};
  if (cfg.enabled === true) return {skipped: "already-enabled"};
  const armAtMs = Number(cfg.armAtMs);
  if (!Number.isFinite(armAtMs)) return {skipped: "no-armAtMs"};
  if (now < armAtMs) return {skipped: "not-yet", inMinutes: Math.round((armAtMs - now) / 60000)};
  await ref.set({enabled: true, armedAt: FieldValue.serverTimestamp()}, {merge: true});
  return {armed: true, armAtMs};
}

module.exports = {armTournamentIfDue};
