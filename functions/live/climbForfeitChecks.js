/**
 * LIVE check for the climb forfeit-sweep fix (2026-09-01), against real
 * Firestore. The pure rule is covered by test/climbTournament.test.js; what
 * only shows up here is the SEAM - that sweepClimb reads the right fields off
 * a real match doc (readyPlayerIds, lastSeenAt, createdAt.toMillis) and does
 * not abandon a battle that is actually in progress.
 *
 * The bug it guards: a real climb battle stays `pending` its whole duration,
 * so the old sweep force-abandoned it at the 8-min no-show timeout, killing
 * a live battle mid-fight (and eliminating both players).
 *
 * Runs the LOCAL climbPlay.sweepClimb against real Firestore (same pattern as
 * scheduledJobScan), seeding aged matches directly.  Run:  node live/climbForfeitChecks.js
 */
const fs = require("fs");
const {initializeApp, cert} = require("firebase-admin/app");
const {getFirestore, Timestamp} = require("firebase-admin/firestore");

const E = fs.readFileSync("../website/.env.local", "utf8");
function val(k) {
  const line = E.split(/\r?\n/).find((l) => l.startsWith(k + "="));
  let v = line.slice(k.length + 1).trim();
  if (v.startsWith("\"") && v.endsWith("\"")) v = v.slice(1, -1);
  return v.replace(/\\n/g, "\n");
}
initializeApp({credential: cert({
  projectId: val("FIREBASE_PROJECT_ID"),
  clientEmail: val("FIREBASE_CLIENT_EMAIL"),
  privateKey: val("FIREBASE_PRIVATE_KEY"),
})});
const db = getFirestore();
const {sweepClimb, climbMatchId} = require("../climbPlay");

let passed = 0; let failed = 0;
function check(name, cond, detail = "") {
  if (cond) {
    passed++; console.log(`  ok   ${name}`);
  } else {
    failed++; console.log(`  FAIL ${name}  ${detail}`);
  }
}

const TID = "climb-forfeit-probe-" + Date.now();
const tRef = db.collection("tournaments").doc(TID);
const AGED = Timestamp.fromMillis(Date.now() - 10 * 60 * 1000); // 10 min ago

// Three matches: A = both readied (a live battle), B = a no-show pair,
// C = one readied and the other absent (one-sided no-show).
// Ids MUST be the real climbMatchId so applyClimbResult (which recomputes it
// from the players) recognises the match - exactly as climbPoll sets them.
const idA = climbMatchId(TID, "cf_a", "cf_b");
const idB = climbMatchId(TID, "cf_c", "cf_d");
const idC = climbMatchId(TID, "cf_e", "cf_f");
async function seedMatch(id, p1, p2, extra) {
  await db.collection("matches").doc(id).set(Object.assign({
    player1Id: p1, player2Id: p2, mode: "tournament", status: "pending",
    voteFinalized: false, winnerId: null, climb: {tournamentId: TID},
    readyPlayerIds: [], lastSeenAt: {}, arrivedAt: {}, createdAt: AGED,
  }, extra));
}

(async () => {
  try {
    console.log("\nseed");
    await seedMatch(idA, "cf_a", "cf_b", {readyPlayerIds: ["cf_a", "cf_b"]});
    await seedMatch(idB, "cf_c", "cf_d", {readyPlayerIds: []});
    await seedMatch(idC, "cf_e", "cf_f", {readyPlayerIds: ["cf_e"]});
    const climber = (uid, m) =>
      ({uid, wins: 0, status: "in_match", currentMatchId: m, joinedMs: Date.now()});
    await tRef.set({
      name: "Forfeit Probe", format: "climb", status: "in_progress",
      windowStartMs: Date.now() - 60000, windowEndMs: Date.now() + 3600 * 1000,
      createdAt: Timestamp.now(),
      climb: {climbers: [
        climber("cf_a", idA), climber("cf_b", idA),
        climber("cf_c", idB), climber("cf_d", idB),
        climber("cf_e", idC), climber("cf_f", idC),
      ]},
    });
    check("seeded a live tournament with 3 aged matches", true);

    console.log("\nsweep");
    await sweepClimb(Date.now());

    const a = (await db.collection("matches").doc(idA).get()).data();
    const b = (await db.collection("matches").doc(idB).get()).data();
    const c = (await db.collection("matches").doc(idC).get()).data();
    const climbers = ((await tRef.get()).data().climb || {}).climbers || [];
    const st = (uid) => (climbers.find((x) => x.uid === uid) || {}).status;

    // THE FIX: both readied = a battle in progress, aged 10 min. The old
    // sweep abandoned it; it must now be left pending.
    check("both-readied battle is NOT abandoned (still pending)",
        a.status === "pending", `status=${a.status}`);
    check("...and both its climbers stay in_match",
        st("cf_a") === "in_match" && st("cf_b") === "in_match",
        `${st("cf_a")}/${st("cf_b")}`);

    // A genuine no-show pair past the timeout is still forfeited (both out).
    check("no-show pair is abandoned as a no-contest",
        b.status === "abandoned" && b.winnerId === null,
        `status=${b.status} winner=${b.winnerId}`);
    check("...and both its climbers are eliminated",
        st("cf_c") === "eliminated" && st("cf_d") === "eliminated",
        `${st("cf_c")}/${st("cf_d")}`);

    // One readied, opponent absent past the timeout -> the present one wins
    // (the old arrivedAt-based logic wrongly eliminated both here).
    check("one-sided no-show: present player WINS the forfeit",
        c.status === "abandoned" && c.winnerId === "cf_e",
        `status=${c.status} winner=${c.winnerId}`);
    check("...present climber advances (waiting, 1 win), absent eliminated",
        st("cf_e") === "waiting" && st("cf_f") === "eliminated",
        `${st("cf_e")}(${(climbers.find((x) => x.uid === "cf_e") || {}).wins})/${st("cf_f")}`);
  } catch (e) {
    console.error("threw:", e.message);
    failed++;
  } finally {
    // Clean up so the scheduled jobs never act on probe data.
    for (const id of [idA, idB, idC]) {
      await db.collection("matches").doc(id).delete().catch(() => {});
    }
    await tRef.delete().catch(() => {});
    console.log("\nprobe data deleted");
  }
  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
})();
