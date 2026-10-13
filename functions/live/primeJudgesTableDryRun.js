/**
 * PRIME A JUDGES'-TABLE DRY RUN against real Firestore.
 *
 * Unlike primeMainStageDryRun.js (which seats the two phone accounts as the
 * BATTLERS to test the chess-clock battle), this seats them as the two seated
 * JUDGES and stages a dummy semifinal that is already DONE being fought
 * (status "completed", no judgeWinnerId) - i.e. sitting in the DEBATE phase.
 *
 * That is exactly the state that lights up, for each phone:
 *   Home -> gold "The Main Stage is LIVE" banner -> MainStageScreen (role judge,
 *   liveBattleMatchId set) -> "Open the judges' room" -> JudgesRoomScreen, which
 *   (match completed + undecided) routes to the ON-CAMERA JudgePanelView: both
 *   judges publish to judges_<matchId>, see each other, cast colour-coded public
 *   votes, and the first judge on camera starts the debate recording.
 *
 * A 2-judge panel settles: both voting the same decides it; a 1-1 split is
 * broken by the head judge (the first seated hand-pick). On decision the match
 * finalizes (force) and the bracket advances - the full real settle path.
 *
 * The per-action callables (watchJudgesTable / castMainStageJudgeVote /
 * startDebateRecording) are NOT gated on config/tournament.enabled, and the Home
 * banner reads the doc directly, so the whole flow works with the launch flag
 * OFF - this script just writes the doc + a completed dummy match.
 *
 * Run from functions/:
 *   node live/primeJudgesTableDryRun.js <judge1> <judge2>
 * where each arg is a USERNAME (case-insensitive) or a raw uid. Then clean up:
 *   node live/teardownJudgesTableDryRun.js
 */
const crypto = require("crypto");
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
const {DEFAULTS: BATTLE_DEFAULTS} = require("../mainStageBattle");
const {JUDGE_WINDOW_MS} = require("../mainStagePlay");

const db = getFirestore();
const TID = "mainstage_dryrun"; // the single canonical dry-run tournament doc
// Four throwaway battler/bench accounts for a valid 4-seed bracket. The
// callout semi (msjt-a vs msjt-b) is the one "on stage" for the judges; the
// other semi (msjt-c vs msjt-d) is never played.
const DUMMIES = [
  {id: "msjt-a", name: "RedDummy"},
  {id: "msjt-b", name: "BlueDummy"},
  {id: "msjt-c", name: "BenchOne"},
  {id: "msjt-d", name: "BenchTwo"},
];

async function resolve(arg) {
  const q = await db.collection("users")
      .where("usernameLower", "==", String(arg).toLowerCase()).limit(1).get();
  if (!q.empty) return {uid: q.docs[0].id, name: q.docs[0].data().username || arg};
  const doc = await db.collection("users").doc(String(arg)).get();
  if (doc.exists) return {uid: doc.id, name: doc.data().username || arg};
  throw new Error(`Could not find a user for "${arg}" (not a username or uid)`);
}

async function run() {
  const args = process.argv.slice(2);
  if (args.length < 2) {
    console.error("usage: node live/primeJudgesTableDryRun.js <judge1> <judge2>");
    process.exit(2);
  }
  const realArgs = args.filter((a) => a !== "--five");
  const five = args.includes("--five");
  const [j1, j2] = await Promise.all(realArgs.slice(0, 2).map(resolve));
  console.log(`judge1 (head) = ${j1.name} (${j1.uid})`);
  console.log(`judge2        = ${j2.name} (${j2.uid})`);
  if (j1.uid === j2.uid) throw new Error("judge1 and judge2 must be two DIFFERENT accounts");

  // --five: pad the panel to 5 with dummy judges so the layout shows a real
  // 3-over-2 on device (the 3 extras have no camera, so they render as "camera
  // off" placeholder tiles - but the grid shape + tile sizing are real).
  const JUDGE_DUMMIES = [
    {id: "msjt-j3", name: "JudgeThree"},
    {id: "msjt-j4", name: "JudgeFour"},
    {id: "msjt-j5", name: "JudgeFive"},
  ];
  const panel = [j1.uid, j2.uid, ...(five ? JUDGE_DUMMIES.map((j) => j.id) : [])];
  if (five) console.log("panel padded to 5 (3 placeholder judges)");

  // Clean slate: remove any existing active mainstage doc so the client picks
  // exactly this one (it chooses the newest active mainstage tournament).
  const existing = await db.collection("tournaments")
      .where("format", "==", "mainstage").get();
  for (const d of existing.docs) {
    if (["accepting", "locked", "live"].includes(d.data().status)) {
      await d.ref.delete().catch(() => {});
      console.log(`  cleared pre-existing active mainstage doc ${d.id}`);
    }
  }

  const batch = db.batch();
  const userDocs = [...DUMMIES, ...(five ? JUDGE_DUMMIES : [])];
  userDocs.forEach((u) => batch.set(db.collection("users").doc(u.id), {
    username: u.name, usernameLower: u.name.toLowerCase(),
    rating: 1200, dryRun: true,
  }, {merge: true}));

  // Seeds: [#1, bench, pick, bench]. #1 (msjt-a) calls out msjt-b, so the
  // callout semi rounds[0][0] = {a: msjt-a, b: msjt-b} is the on-stage battle.
  const seeds = [DUMMIES[0].id, DUMMIES[2].id, DUMMIES[1].id, DUMMIES[3].id];
  const bracket = createBracket(seeds, DUMMIES[1].id);
  const stored = storeBracket(bracket);

  // The on-stage battle, already fought: mirrors what startMainStageBattle
  // writes, but status "completed" + no judgeWinnerId = the DEBATE phase.
  const {getMatchSettings} = require("../matchSettings");
  const settings = await getMatchSettings("tournament");
  const matchId = `ms_${crypto.randomBytes(12).toString("hex")}`;
  batch.set(db.collection("matches").doc(matchId), {
    player1Id: DUMMIES[0].id,
    player2Id: DUMMIES[1].id,
    player1Rating: 1200,
    player2Rating: 1200,
    mode: "tournament",
    mainStage: {tournamentId: TID, roundIdx: 0, matchIdx: 0},
    mainStageConfig: {...BATTLE_DEFAULTS},
    settings,
    judgeWindowMs: JUDGE_WINDOW_MS, // matches the real finals window (10 min)
    status: "completed", // battle over -> the judges' debate is open
    channelName: `match_${matchId}`,
    origin: "mainstage",
    createdAt: FieldValue.serverTimestamp(),
  });

  // Stamp the match id onto the callout matchup so liveBattleMatchId resolves.
  const rounds = stored.rounds.map((r, ri) => ({
    ...r,
    matches: r.matches.map((mm, mi) =>
      (ri === 0 && mi === 0) ? {...mm, matchId} : mm),
  }));

  batch.set(db.collection("tournaments").doc(TID), {
    format: "mainstage",
    createdBy: "auto",
    status: "live",
    cutoffDayKey: "dryrun",
    finalists: seeds,
    field: seeds,
    alternates: [],
    judgePool: [],
    handPickedJudges: [j1.uid, j2.uid], // first = head judge (breaks a tie)
    judges: panel, // the seated panel (2, or 5 with --five)
    invites: {
      [j1.uid]: "accepted", [j2.uid]: "accepted",
      [DUMMIES[0].id]: "accepted", [DUMMIES[1].id]: "accepted",
    },
    bracket: {...stored, rounds},
    judgesDryRun: true,
    dryRun: true,
    createdAt: FieldValue.serverTimestamp(),
  });
  await batch.commit();

  console.log(`\n✅ Staged judges'-table dry run (tournament '${TID}', match ${matchId}).`);
  console.log("\nON BOTH PHONES (both are seated judges):");
  console.log("  Home → gold \"The Main Stage is LIVE\" banner → tap it →");
  console.log("  \"Open the judges' room\" → you go ON CAMERA at the table:");
  console.log("    • you should see the OTHER judge's camera once they open it too");
  console.log("    • tap a battler (Red = player 1, Blue = player 2), then Confirm");
  console.log("    • each vote wraps that judge's tile in the battler's colour + the live tally");
  console.log("  Both voting the SAME battler (or a 1-1 split, head judge =");
  console.log(`  ${j1.name}) settles it → \"<name> takes it\" → the bracket advances.`);
  console.log("\nWhen done:  node live/teardownJudgesTableDryRun.js");
}

run().catch((e) => {
  console.error("FAILED:", e.message);
  process.exit(1);
});
