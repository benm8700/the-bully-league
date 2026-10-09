/**
 * PRIME A MAIN STAGE DRY RUN against real Firestore.
 *
 * Stages a live `mainstage` tournament so the developer can walk the finals
 * battle + judging flow on real devices. The two battler accounts you name are
 * placed as the #1-callout SEMIFINAL (so both go straight to "Play your match"),
 * a judge account is seated on a one-judge panel (one vote settles the battle),
 * and two synthetic BENCH accounts fill the other semifinal so the 4-seed
 * bracket is valid (the bench semi is never played - the dry run is the one
 * real battle).
 *
 * The per-action callables (startMainStageBattle / castMainStageJudgeVote /
 * watchLiveMatch) are NOT gated on config/tournament.enabled, so the whole
 * flow works with the launch flag OFF - this script just needs to write the doc.
 *
 * Run from functions/:
 *   node live/primeMainStageDryRun.js <battler1> <battler2> <judge>
 * where each arg is a USERNAME (case-insensitive) or a raw uid. Then clean up:
 *   node live/teardownMainStageDryRun.js
 *
 * It records a snapshot of each real participant's rating/wins/losses so the
 * teardown can restore them (a dry-run battle does move the two battlers' Elo).
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
  databaseURL: "https://the-bully-league-default-rtdb.firebaseio.com",
  storageBucket: "the-bully-league.firebasestorage.app",
});
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {createBracket} = require("../mainStageBracket");
const {storeBracket} = require("../mainStageLifecycle");

const db = getFirestore();
const TID = "mainstage_dryrun";
const BENCH = ["msdry-bench-1", "msdry-bench-2"];

async function resolve(arg) {
  // Username (case-insensitive) first; fall back to a raw uid.
  const q = await db.collection("users")
      .where("usernameLower", "==", String(arg).toLowerCase()).limit(1).get();
  if (!q.empty) return {uid: q.docs[0].id, name: q.docs[0].data().username || arg};
  const doc = await db.collection("users").doc(String(arg)).get();
  if (doc.exists) return {uid: doc.id, name: doc.data().username || arg};
  throw new Error(`Could not find a user for "${arg}" (not a username or uid)`);
}

async function run() {
  const args = process.argv.slice(2);
  if (args.length < 3) {
    console.error("usage: node live/primeMainStageDryRun.js <battler1> <battler2> <judge>");
    process.exit(2);
  }
  const [b1, b2, judge] = await Promise.all(args.slice(0, 3).map(resolve));
  console.log(`battler1 = ${b1.name} (${b1.uid})`);
  console.log(`battler2 = ${b2.name} (${b2.uid})`);
  console.log(`judge    = ${judge.name} (${judge.uid})`);

  const realUids = [b1.uid, b2.uid, judge.uid];
  if (new Set(realUids).size !== 3) throw new Error("battler1/battler2/judge must be three DIFFERENT accounts");

  // Snapshot the real participants so teardown can restore them.
  const snap = {};
  for (const u of realUids) {
    const d = (await db.collection("users").doc(u).get()).data() || {};
    snap[u] = {rating: d.rating ?? null, wins: d.wins ?? null, losses: d.losses ?? null};
  }

  const batch = db.batch();
  // Bench finalists - just enough of a user doc that names resolve.
  BENCH.forEach((u, i) => batch.set(db.collection("users").doc(u), {
    username: `Bench${i + 1}`, usernameLower: `bench${i + 1}`,
    rating: 1200, dryRun: true,
  }, {merge: true}));

  // Seeds in order: [#1, bench, pick, bench]. #1 (b1) calls out b2, so the
  // callout semi is {a: b1, b: b2} = the two real devices; benches auto-pair.
  const seeds = [b1.uid, BENCH[0], b2.uid, BENCH[1]];
  const bracket = createBracket(seeds, b2.uid);

  batch.set(db.collection("tournaments").doc(TID), {
    format: "mainstage",
    createdBy: "auto",
    status: "live",
    cutoffDayKey: "dryrun",
    finalists: seeds,
    field: seeds,
    alternates: [],
    judgePool: [],
    handPickedJudges: [judge.uid], // first seated hand-pick = head judge
    judges: [judge.uid], // one-judge panel: a single vote settles the battle
    invites: {[judge.uid]: "accepted", [b1.uid]: "accepted", [b2.uid]: "accepted"},
    bracket: storeBracket(bracket),
    dryRun: true,
    dryRunSnapshot: snap,
    createdAt: FieldValue.serverTimestamp(),
  });
  await batch.commit();

  console.log("\n✅ Staged live Main Stage tournament 'mainstage_dryrun'.");
  console.log("\nON THE DEVICES:");
  console.log(`  • ${b1.name} and ${b2.name}: Home → gold "Main Stage is LIVE" banner →`);
  console.log("    \"Play your match\" → consent → camera check → the chess-clock battle.");
  console.log(`  • ${judge.name}: Home → "Main Stage is LIVE" banner → "Open the judges' room"`);
  console.log("    (appears once a battler has started) → watch + tap the winner to vote.");
  console.log("    With a one-judge panel, that single vote settles the battle and fills");
  console.log("    the bracket.");
  console.log("\nWhen done:  node live/teardownMainStageDryRun.js");
}

run().catch((e) => {
  console.error("FAILED:", e.message);
  process.exit(1);
});
