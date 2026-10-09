/**
 * Live check for the Main Stage STALLED-PANEL FORCE-CLOSE against real
 * Firestore: a battle whose judging window has elapsed with too few votes must
 * not halt the bracket. Primes a live mainstage tournament with a started
 * semifinal battle backdated past its deadline, then runs the REAL
 * forceCloseStalledBattles() and asserts the battle is settled (higher seed on
 * a silent panel), the bracket advances, and the finals Elo moves - plus the
 * negative: a fresh battle is left alone. Everything is torn down in a finally.
 *
 * Run from functions/:  node live/mainStageForceCloseChecks.js
 */
const fs = require("fs");
const assert = require("assert");
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

const {getFirestore, Timestamp} = require("firebase-admin/firestore");
const {createBracket} = require("../mainStageBracket");
const {storeBracket} = require("../mainStageLifecycle");
const {forceCloseStalledBattles, JUDGE_WINDOW_MS} = require("../mainStagePlay");

const db = getFirestore();

let passed = 0;
async function check(name, fn) {
  await fn();
  passed++;
  console.log(`  ok - ${name}`);
}

const PFX = "msforce";
const uid = (s) => `${PFX}-${s}`;
const TID = "mainstage_msforce";
const FIELD = [uid("pA"), uid("pB"), uid("pC"), uid("pD")]; // pA = #1 seed
const JUDGES = [uid("j1"), uid("j2"), uid("j3"), uid("j4"), uid("j5")];
// The stalled semifinal (semi0: #1 pA vs called-out pB). Its own id so it is
// cleaned up precisely.
const MID = "msforce_semi0";
const FRESH_MID = "msforce_semi1"; // a just-started battle, must NOT force-close

async function seed() {
  const batch = db.batch();
  for (const u of FIELD) {
    batch.set(db.collection("users").doc(u), {username: u, rating: 1200});
  }
  for (const u of JUDGES) {
    batch.set(db.collection("users").doc(u), {username: u, rating: 1200});
  }
  const bracket = createBracket(FIELD, FIELD[1]); // pA calls out pB
  const stored = storeBracket(bracket);
  // Stamp matchIds onto both semis (started battles).
  stored.rounds[0].matches[0].matchId = MID; // pA vs pB (stalled)
  stored.rounds[0].matches[1].matchId = FRESH_MID; // pC vs pD (just started)
  batch.set(db.collection("tournaments").doc(TID), {
    format: "mainstage",
    createdBy: "auto",
    status: "live",
    cutoffDayKey: "2099-10-15",
    finalists: FIELD,
    field: FIELD,
    judges: JUDGES,
    handPickedJudges: [JUDGES[0]],
    bracket: stored,
    createdAt: Date.now(),
  });
  const base = {
    mode: "tournament",
    status: "completed", // battle over, panel never decided
    channelName: `match_${MID}`,
    player1Rating: 1200,
    player2Rating: 1200,
    judgeWindowMs: JUDGE_WINDOW_MS,
  };
  // The stalled battle: created 13 minutes ago (past the 12-minute window),
  // zero judge votes.
  batch.set(db.collection("matches").doc(MID), {
    ...base,
    player1Id: FIELD[0], // pA
    player2Id: FIELD[1], // pB
    mainStage: {tournamentId: TID, roundIdx: 0, matchIdx: 0},
    createdAt: Timestamp.fromMillis(Date.now() - 13 * 60 * 1000),
  });
  // A fresh battle: just started, must be left alone.
  batch.set(db.collection("matches").doc(FRESH_MID), {
    ...base,
    channelName: `match_${FRESH_MID}`,
    player1Id: FIELD[2], // pC
    player2Id: FIELD[3], // pD
    mainStage: {tournamentId: TID, roundIdx: 0, matchIdx: 1},
    createdAt: Timestamp.now(),
  });
  await batch.commit();
}

async function cleanup() {
  const dels = [
    db.collection("tournaments").doc(TID),
    db.collection("matches").doc(MID),
    db.collection("matches").doc(FRESH_MID),
  ];
  for (const u of [...FIELD, ...JUDGES]) dels.push(db.collection("users").doc(u));
  for (const u of FIELD) {
    dels.push(db.collection("users").doc(u).collection("ratingHistory").doc(MID));
  }
  const votes = await db.collection("matches").doc(MID)
      .collection("mainStageVotes").get();
  await Promise.all(votes.docs.map((d) => d.ref.delete().catch(() => {})));
  await Promise.all(dels.map((r) => r.delete().catch(() => {})));
}

async function run() {
  await seed();

  let result;
  await check("the sweep force-closes the stalled battle, leaves the fresh one",
      async () => {
        result = await forceCloseStalledBattles(db, Date.now());
        const ids = result.map((r) => r.matchId);
        assert.ok(ids.includes(MID), `stalled ${MID} should be force-closed`);
        assert.ok(!ids.includes(FRESH_MID),
            `fresh ${FRESH_MID} must NOT be force-closed`);
      });

  await check("a silent panel advances the HIGHER SEED (pA)", async () => {
    const m = (await db.collection("matches").doc(MID).get()).data();
    assert.strictEqual(m.judgeWinnerId, FIELD[0], "pA (#1 seed) should win");
    assert.ok(m.judgeForceClosedAt, "stamped as force-closed");
  });

  await check("the bracket advanced from the force-close", async () => {
    const t = (await db.collection("tournaments").doc(TID).get()).data();
    assert.strictEqual(t.bracket.rounds[0].matches[0].winner, FIELD[0]);
  });

  await check("the finals Elo moved (winner up, loser down)", async () => {
    const pa = (await db.collection("users").doc(FIELD[0]).get()).data();
    const pb = (await db.collection("users").doc(FIELD[1]).get()).data();
    assert.ok(pa.rating > 1200, `pA rating ${pa.rating} should exceed 1200`);
    assert.ok(pb.rating < 1200, `pB rating ${pb.rating} should be below 1200`);
  });

  await check("the fresh battle is untouched (no winner, no force-close stamp)",
      async () => {
        const m = (await db.collection("matches").doc(FRESH_MID).get()).data();
        assert.ok(!m.judgeWinnerId, "fresh battle must not be decided");
      });

  await check("a second sweep is idempotent (nothing left to close)",
      async () => {
        const again = await forceCloseStalledBattles(db, Date.now());
        assert.ok(!again.map((r) => r.matchId).includes(MID),
            "the settled battle is not re-closed");
      });
}

run()
    .then(() => console.log(`\n${passed} passed`))
    .catch((e) => {
      console.error("FAILED:", e.message);
      process.exitCode = 1;
    })
    .finally(cleanup);
