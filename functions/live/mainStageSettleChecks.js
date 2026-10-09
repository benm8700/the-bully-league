/**
 * Live check for the Main Stage finals SETTLEMENT against the DEPLOYED backend:
 * start a bracket battle, have the 5-judge panel cast open votes, and assert
 * the verdict settles the battle (finals Elo applied) AND advances the
 * #1-callout bracket. Primes a synthetic live mainstage tournament directly
 * (the flag-gated auto-creation is bypassed) and mints real ID tokens per
 * participant via createCustomToken -> signInWithCustomToken, so the deployed
 * callables run under genuine auth. Everything is torn down in a finally.
 *
 * Run from functions/:  node live/mainStageSettleChecks.js
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

const {getFirestore} = require("firebase-admin/firestore");
const {getAuth} = require("firebase-admin/auth");
const {createBracket} = require("../mainStageBracket");
const {storeBracket} = require("../mainStageLifecycle");

const db = getFirestore();
const API_KEY = "AIzaSyD-yeC1osuXpfwXWNZPnLEOq7yLviM7J0c";
const BASE = "https://the-bully-league.vercel.app"; // not used; callables below
const REGION = "https://us-central1-the-bully-league.cloudfunctions.net";

let passed = 0;
async function check(name, fn) {
  await fn();
  passed++;
  console.log(`  ok - ${name}`);
}

async function idToken(uid) {
  const custom = await getAuth().createCustomToken(uid);
  const r = await fetch(
      `https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=${API_KEY}`,
      {method: "POST", headers: {"Content-Type": "application/json"},
        body: JSON.stringify({token: custom, returnSecureToken: true})});
  const j = await r.json();
  if (!j.idToken) throw new Error("token mint failed: " + JSON.stringify(j));
  return j.idToken;
}

// Call a deployed onCall function via its HTTPS endpoint with the callable
// protocol ({data:...} body, Bearer token).
async function callFn(name, token, data) {
  const r = await fetch(`${REGION}/${name}`, {
    method: "POST",
    headers: {"Content-Type": "application/json",
      "Authorization": "Bearer " + token},
    body: JSON.stringify({data}),
  });
  const body = await r.json();
  return {status: r.status, body};
}

const PFX = "mssettle";
const uid = (s) => `${PFX}-${s}`;
const TID = "mainstage_mssettle";
const FIELD = [uid("pA"), uid("pB"), uid("pC"), uid("pD")];
const JUDGES = [uid("j1"), uid("j2"), uid("j3"), uid("j4"), uid("j5")];

async function seed() {
  const batch = db.batch();
  for (const u of FIELD) {
    batch.set(db.collection("users").doc(u), {username: u, rating: 1200});
  }
  for (const u of JUDGES) {
    batch.set(db.collection("users").doc(u), {username: u, rating: 1200});
  }
  // #1 (pA) calls out pB -> semifinal 0 = {a:pA, b:pB}; the other two auto-pair.
  const bracket = createBracket(FIELD, FIELD[1]);
  batch.set(db.collection("tournaments").doc(TID), {
    format: "mainstage",
    createdBy: "auto",
    status: "live",
    cutoffDayKey: "2099-10-15",
    finalists: FIELD,
    field: FIELD,
    judges: JUDGES,
    handPickedJudges: [JUDGES[0]], // j1 = head judge (tiebreak)
    bracket: storeBracket(bracket),
    createdAt: Date.now(),
  });
  await batch.commit();
}

async function cleanup() {
  const dels = [db.collection("tournaments").doc(TID)];
  for (const u of [...FIELD, ...JUDGES]) dels.push(db.collection("users").doc(u));
  // the created battle match + its votes
  const t = (await db.collection("tournaments").doc(TID).get()).data();
  const mid = t && t.bracket && t.bracket.rounds[0].matches[0].matchId;
  if (mid) {
    const votes = await db.collection("matches").doc(mid)
        .collection("mainStageVotes").get();
    await Promise.all(votes.docs.map((d) => d.ref.delete().catch(() => {})));
    dels.push(db.collection("matches").doc(mid));
    // ratingHistory the finals wrote
    for (const u of [FIELD[0], FIELD[1]]) {
      dels.push(db.collection("users").doc(u).collection("ratingHistory").doc(mid));
    }
  }
  await Promise.all(dels.map((r) => r.delete().catch(() => {})));
}

async function run() {
  await seed();
  const tokPA = await idToken(FIELD[0]);
  const tokPB = await idToken(FIELD[1]);

  let matchId;
  await check("startMainStageBattle creates the semifinal match", async () => {
    const r = await callFn("startMainStageBattle", tokPA,
        {tournamentId: TID, roundIdx: 0, matchIdx: 0});
    assert.strictEqual(r.status, 200, JSON.stringify(r.body));
    matchId = r.body.result.matchId;
    assert.ok(matchId, "a matchId");
    assert.strictEqual(r.body.result.agoraUid, 1); // pA is player1
  });

  await check("the opponent rejoins the SAME match (not a second)", async () => {
    const r = await callFn("startMainStageBattle", tokPB,
        {tournamentId: TID, roundIdx: 0, matchIdx: 0});
    assert.strictEqual(r.status, 200, JSON.stringify(r.body));
    assert.strictEqual(r.body.result.matchId, matchId);
    assert.strictEqual(r.body.result.agoraUid, 2); // pB is player2
  });

  // Simulate the battle having been played to its end (completeMatch would do
  // this; the judge-vote settlement requires a completed battle).
  await db.collection("matches").doc(matchId).update({status: "completed"});

  await check("a NON-judge cannot cast a judge vote", async () => {
    const tok = await idToken(uid("pC")); // a finalist, not on the panel
    const r = await callFn("castMainStageJudgeVote", tok,
        {matchId, winnerUid: FIELD[0]});
    assert.strictEqual(r.status, 403, JSON.stringify(r.body));
  });

  await check("judge votes tally; the panel verdict settles the battle", async () => {
    // 3 judges for pA, then it's decisive (3 of 5, 2 out can't catch).
    for (const j of JUDGES.slice(0, 3)) {
      const tok = await idToken(j);
      const r = await callFn("castMainStageJudgeVote", tok,
          {matchId, winnerUid: FIELD[0]});
      assert.strictEqual(r.status, 200, JSON.stringify(r.body));
    }
    // allow the (forced) finalize to run
    await new Promise((res) => setTimeout(res, 1500));
    const m = (await db.collection("matches").doc(matchId).get()).data();
    assert.strictEqual(m.judgeWinnerId, FIELD[0]);
    assert.strictEqual(m.winnerId, FIELD[0]);
    assert.strictEqual(m.voteFinalized, true);
  });

  await check("the bracket advanced: the matchup winner is filled", async () => {
    const t = (await db.collection("tournaments").doc(TID).get()).data();
    assert.strictEqual(t.bracket.rounds[0].matches[0].winner, FIELD[0]);
  });

  await check("finals moved Elo (the winner's hidden rating rose)", async () => {
    const pa = (await db.collection("users").doc(FIELD[0]).get()).data();
    assert.ok(pa.rating > 1200, `pA rating ${pa.rating} should exceed 1200`);
    const pb = (await db.collection("users").doc(FIELD[1]).get()).data();
    assert.ok(pb.rating < 1200, `pB rating ${pb.rating} should be below 1200`);
  });
}

run()
    .then(() => console.log(`\n${passed} passed`))
    .catch((e) => {
      console.error("FAILED:", e.message);
      process.exitCode = 1;
    })
    .finally(cleanup);
