/**
 * TEAR DOWN the judges'-table dry run staged by primeJudgesTableDryRun.js.
 *
 * Deletes the staged tournament, the four throwaway battler/bench accounts, and
 * any battle match stamped on the bracket (plus its judge votes and the two
 * dummy battlers' ratingHistory). Nothing real to restore - the two seated
 * judges are the real phone accounts but they only judge, they never battle, so
 * their rating/wins/losses are untouched.
 *
 * Run from functions/:  node live/teardownJudgesTableDryRun.js
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
const DUMMIES =
  ["msjt-a", "msjt-b", "msjt-c", "msjt-d", "msjt-j3", "msjt-j4", "msjt-j5"];

async function run() {
  const tSnap = await db.collection("tournaments").doc(TID).get();
  const t = tSnap.exists ? tSnap.data() : null;

  const matchIds = [];
  const rounds = t && t.bracket && t.bracket.rounds;
  if (Array.isArray(rounds)) {
    for (const r of rounds) {
      for (const m of (r.matches || [])) {
        if (m && m.matchId) matchIds.push(m.matchId);
      }
    }
  }

  for (const mid of matchIds) {
    const votes = await db.collection("matches").doc(mid)
        .collection("mainStageVotes").get();
    await Promise.all(votes.docs.map((d) => d.ref.delete().catch(() => {})));
    for (const u of DUMMIES) {
      await db.collection("users").doc(u).collection("ratingHistory")
          .doc(mid).delete().catch(() => {});
    }
    await db.collection("matches").doc(mid).delete().catch(() => {});
    console.log(`  deleted battle match ${mid}`);
  }

  for (const u of DUMMIES) {
    await db.collection("users").doc(u).delete().catch(() => {});
  }
  await db.collection("tournaments").doc(TID).delete().catch(() => {});

  console.log(t ? "\n✅ Judges'-table dry run torn down." :
    "\nNo staged dry run found (already clean).");
}

run().catch((e) => {
  console.error("FAILED:", e.message);
  process.exit(1);
});
