/**
 * Removes leftover test artefacts before the private beta.
 *
 * All of this was created by live check scripts and earlier device
 * testing, and none of it is real. It matters because a tester opening
 * Tournaments and finding "_probe_" and "admin-gate-test", or a
 * leaderboard carrying "td-outsider" with no rating at all, reads as an
 * unfinished app - which is exactly the impression a private beta exists
 * to avoid.
 *
 * WHAT IS DELIBERATELY KEPT:
 *   - PlayerOne, PlayerTwo, SeventhVoter, slamrod, SoloProbe. The first
 *     three are the developer's two-device test accounts and have real
 *     match history; slamrod is the real admin account; SoloProbe is
 *     signed in on the emulator.
 *   - MATCH DOCUMENTS, always. Other accounts' rating history depends on
 *     them, and the feed already renders an unresolvable player as
 *     "Unknown" rather than breaking - the same rule account deletion
 *     follows for a real user.
 *   - Reports are MARKED REVIEWED rather than deleted. The report trail
 *     is deliberately retained even through a CCPA deletion, so deleting
 *     one to tidy up would be the wrong habit to start; clearing the
 *     queue is what was actually wanted.
 *
 * Run from functions/:  node live/purgeTestData.js [--apply]
 */
const fs = require("fs");
const {initializeApp, cert} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");
const {getAuth} = require("firebase-admin/auth");
const {getDatabase} = require("firebase-admin/database");

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
  databaseURL: "https://the-bully-league-default-rtdb.firebaseio.com",
});

const PURGE_USERNAMES = ["MMTestA", "MMTestB", "td-player", "td-outsider"];
const PURGE_TOURNAMENTS = ["Test Cup", "admin-gate-test", "Bye Test Cup",
  "_probe_"];
const APPLY = process.argv.includes("--apply");

(async () => {
  const db = getFirestore();
  const act = async (label, fn) => {
    console.log(`  ${APPLY ? "" : "[dry] "}${label}`);
    if (APPLY) await fn();
  };

  console.log("\nACCOUNTS");
  const users = await db.collection("users").get();
  for (const doc of users.docs) {
    const name = doc.data().username;
    if (!PURGE_USERNAMES.includes(name)) continue;
    await act(`delete user ${name} (${doc.id}) + claim + auth + queue`,
        async () => {
          for (const mode of ["exhibition", "ranked"]) {
            await getDatabase()
                .ref(`matchmakingQueue/${mode}/${doc.id}`)
                .remove().catch(() => {});
          }
          const key = (doc.data().usernameLower ?? name).toLowerCase();
          const claim = await db.collection("usernames").doc(key).get();
          if (claim.exists && claim.data().uid === doc.id) {
            await claim.ref.delete();
          }
          await db.recursiveDelete(doc.ref);
          await getAuth().deleteUser(doc.id).catch(() => {});
        });
  }

  console.log("\nTOURNAMENTS");
  const tours = await db.collection("tournaments").get();
  for (const doc of tours.docs) {
    const name = doc.data().name ?? doc.id;
    if (!PURGE_TOURNAMENTS.includes(name)) continue;
    const entrants = await doc.ref.collection("entrants").get();
    await act(`delete tournament "${name}" (${entrants.size} entrants)`,
        () => db.recursiveDelete(doc.ref));
  }

  console.log("\nREPORTS");
  const reports = await db.collection("reports")
      .where("status", "==", "pending").get();
  for (const doc of reports.docs) {
    await act(`mark reviewed: ${doc.id} (${doc.data().reason})`,
        () => doc.ref.set({
          status: "reviewed",
          moderatorNotes: "Test submission from pre-beta development. " +
            "No action taken.",
        }, {merge: true}));
  }

  if (!APPLY) console.log("\nDry run. Re-run with --apply.");
  // Explicit, because getDatabase() opens a connection that keeps the
  // event loop alive forever - the work finishes but the process never
  // exits, which looks exactly like a hang.
  process.exit(0);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
