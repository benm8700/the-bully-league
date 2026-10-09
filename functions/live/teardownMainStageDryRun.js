/**
 * TEAR DOWN the Main Stage dry run staged by primeMainStageDryRun.js.
 *
 * Removes the staged tournament, the bench accounts, and any battle match it
 * produced (plus that match's judge votes and the two battlers' ratingHistory
 * entry), then RESTORES each real participant's rating/wins/losses from the
 * snapshot the prime script stored - a dry-run battle does move the battlers'
 * Elo, and their real accounts should not carry it.
 *
 * NOTE: it does NOT reverse points / quest progress / recentOpponentIds from
 * the battle (points only ever rise and the beta resets at launch, so a few
 * dozen points are harmless). Everything else is cleaned.
 *
 * Run from functions/:  node live/teardownMainStageDryRun.js
 */
const fs = require("fs");
const {initializeApp, cert} = require("firebase-admin/app");

const E = fs.readFileSync("../website/.env.local", "utf8");
function val(k) {
  const line = E.split(/\r?\n/).find((l) => l.startsWith(k + "="));
  let v = line.slice(k.length + 1).trim();
  if (v.startsWith("\"") && v.endsWith("\"")) v = v.slice(1, -1);
  return v.replace(/\\n/g, "\n");
}
initializeApp({
  credential: cert({
    projectId: val("FIREBASE_PROJECT_ID"),
    clientEmail: val("FIREBASE_CLIENT_EMAIL"),
    privateKey: val("FIREBASE_PRIVATE_KEY"),
  }),
  storageBucket: "the-bully-league.firebasestorage.app",
});
const {getFirestore} = require("firebase-admin/firestore");

const db = getFirestore();
const TID = "mainstage_dryrun";
const BENCH = ["msdry-bench-1", "msdry-bench-2"];

async function run() {
  const tSnap = await db.collection("tournaments").doc(TID).get();
  const t = tSnap.exists ? tSnap.data() : null;

  // Collect every stamped battle match id across the bracket.
  const matchIds = [];
  const rounds = t && t.bracket && t.bracket.rounds;
  if (Array.isArray(rounds)) {
    for (const r of rounds) {
      for (const m of (r.matches || [])) {
        if (m && m.matchId) matchIds.push(m.matchId);
      }
    }
  }

  const realUids = Array.isArray(t && t.field) ?
    t.field.filter((u) => !BENCH.includes(u)) : [];
  // judge may not be in field; include invites keys too.
  if (t && t.invites) {
    for (const u of Object.keys(t.invites)) {
      if (!BENCH.includes(u) && !realUids.includes(u)) realUids.push(u);
    }
  }

  // Delete battle matches + their votes + the battlers' ratingHistory entry.
  for (const mid of matchIds) {
    const votes = await db.collection("matches").doc(mid)
        .collection("mainStageVotes").get();
    await Promise.all(votes.docs.map((d) => d.ref.delete().catch(() => {})));
    for (const u of realUids) {
      await db.collection("users").doc(u).collection("ratingHistory")
          .doc(mid).delete().catch(() => {});
    }
    await db.collection("matches").doc(mid).delete().catch(() => {});
    console.log(`  deleted battle match ${mid}`);
  }

  // Restore the real participants' rating/wins/losses from the snapshot.
  const snap = (t && t.dryRunSnapshot) || {};
  for (const [uid, s] of Object.entries(snap)) {
    const restore = {};
    if (s.rating !== null && s.rating !== undefined) restore.rating = s.rating;
    if (s.wins !== null && s.wins !== undefined) restore.wins = s.wins;
    if (s.losses !== null && s.losses !== undefined) restore.losses = s.losses;
    if (Object.keys(restore).length) {
      await db.collection("users").doc(uid).update(restore).catch(() => {});
      console.log(`  restored ${uid}: ${JSON.stringify(restore)}`);
    }
  }

  // Remove bench accounts and the tournament.
  for (const u of BENCH) {
    await db.collection("users").doc(u).delete().catch(() => {});
  }
  await db.collection("tournaments").doc(TID).delete().catch(() => {});

  console.log(t ? "\n✅ Dry run torn down." :
    "\nNo staged dry run found (already clean).");
}

run().catch((e) => {
  console.error("FAILED:", e.message);
  process.exit(1);
});
