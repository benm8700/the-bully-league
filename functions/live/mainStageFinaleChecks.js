/**
 * Verifies the Main Stage FINALE celebration against the deployed backend: the
 * onTournamentCompleted trigger stamping the champion + runner-up popups and
 * the runner-up badge counter, and the getPendingTournamentFinale callable
 * returning each finalist's moment once and then clearing it.
 *
 * Drives a real mainstage tournament to completion (create live -> update to
 * completed + a final bracket), which is the one way to exercise the finale
 * without four real devices playing a whole bracket.
 *
 * Run from functions/:  node live/mainStageFinaleChecks.js
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
});
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {getAuth} = require("firebase-admin/auth");

const db = getFirestore();
const API_KEY = "AIzaSyD-yeC1osuXpfwXWNZPnLEOq7yLviM7J0c";
const REGION = "https://us-central1-the-bully-league.cloudfunctions.net";

const TID = "msfinale-check";
const CHAMP = "msfinale-champ";
const RUNNER = "msfinale-runner";

let passed = 0;
async function check(name, fn) {
  await fn();
  passed++;
  console.log(`  ok - ${name}`);
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

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
async function callFn(name, token, data) {
  const r = await fetch(`${REGION}/${name}`, {
    method: "POST",
    headers: {"Content-Type": "application/json", "Authorization": "Bearer " + token},
    body: JSON.stringify({data}),
  });
  return {status: r.status, body: await r.json()};
}

async function seed() {
  const batch = db.batch();
  batch.set(db.collection("users").doc(CHAMP), {
    username: "MsChamp", usernameLower: "mschamp",
    tournamentWins: 0, tournamentRunnerUps: 0,
  });
  batch.set(db.collection("users").doc(RUNNER), {
    username: "MsRunner", usernameLower: "msrunner",
    tournamentWins: 0, tournamentRunnerUps: 0,
  });
  // Create the tournament NOT yet completed - the trigger is on the
  // status -> "completed" UPDATE, so a doc born completed would not fire.
  batch.set(db.collection("tournaments").doc(TID), {
    name: "Finale Check Cup",
    format: "mainstage",
    status: "live",
    createdBy: "test",
    bracket: {
      rounds: [
        {matches: [
          {a: CHAMP, b: "x", winner: CHAMP},
          {a: RUNNER, b: "y", winner: RUNNER},
        ]},
        {matches: [{a: CHAMP, b: RUNNER, winner: null}]},
      ],
    },
  });
  await batch.commit();
}

async function cleanup() {
  await db.collection("tournaments").doc(TID).delete().catch(() => {});
  for (const u of [CHAMP, RUNNER]) {
    await db.collection("users").doc(u).delete().catch(() => {});
    await getAuth().deleteUser(u).catch(() => {});
  }
}

async function run() {
  await cleanup(); // in case a prior run died mid-way
  await seed();

  await check("completing the tournament fires the finale trigger", async () => {
    await db.collection("tournaments").doc(TID).update({
      status: "completed",
      winnerId: CHAMP,
      completedAt: FieldValue.serverTimestamp(),
      "bracket.rounds": [
        {matches: [
          {a: CHAMP, b: "x", winner: CHAMP},
          {a: RUNNER, b: "y", winner: RUNNER},
        ]},
        {matches: [{a: CHAMP, b: RUNNER, winner: CHAMP}]},
      ],
    });
    await sleep(4000); // let the trigger run
    const t = (await db.collection("tournaments").doc(TID).get()).data();
    assert.strictEqual(t.finaleRecorded, true, "finaleRecorded flag set");
  });

  await check("the champion is stamped place 1 and credited a win", async () => {
    const c = (await db.collection("users").doc(CHAMP).get()).data();
    assert.strictEqual(c.pendingTournamentFinale.place, 1);
    assert.strictEqual(c.pendingTournamentFinale.name, "Finale Check Cup");
    assert.strictEqual(c.tournamentWins, 1, "champion credited a win");
  });

  await check("the runner-up is stamped place 2 and credited a runner-up", async () => {
    const r = (await db.collection("users").doc(RUNNER).get()).data();
    assert.strictEqual(r.pendingTournamentFinale.place, 2);
    assert.strictEqual(r.tournamentRunnerUps, 1, "runner-up counter bumped");
    assert.strictEqual(r.tournamentWins, 0, "runner-up did NOT get a win");
  });

  await check("getPendingTournamentFinale returns the champion's moment once", async () => {
    const tok = await idToken(CHAMP);
    const r1 = await callFn("getPendingTournamentFinale", tok, {});
    assert.strictEqual(r1.status, 200, JSON.stringify(r1.body));
    assert.strictEqual(r1.body.result.finale.place, 1);
    // Cleared on read - a second call returns nothing.
    const r2 = await callFn("getPendingTournamentFinale", tok, {});
    assert.strictEqual(r2.body.result.finale, null, "popup fires exactly once");
  });

  await check("getPendingTournamentFinale returns the runner-up's moment once", async () => {
    const tok = await idToken(RUNNER);
    const r1 = await callFn("getPendingTournamentFinale", tok, {});
    assert.strictEqual(r1.body.result.finale.place, 2);
    const r2 = await callFn("getPendingTournamentFinale", tok, {});
    assert.strictEqual(r2.body.result.finale, null);
  });

  await check("a benign re-update does NOT double-credit (trigger guard)", async () => {
    await db.collection("tournaments").doc(TID).update({touched: Date.now()});
    await sleep(3000);
    const c = (await db.collection("users").doc(CHAMP).get()).data();
    const r = (await db.collection("users").doc(RUNNER).get()).data();
    assert.strictEqual(c.tournamentWins, 1, "no second win");
    assert.strictEqual(r.tournamentRunnerUps, 1, "no second runner-up");
  });
}

run()
    .then(() => console.log(`\n${passed} passed`))
    .catch((e) => {
      console.error("FAILED:", e.message);
      process.exitCode = 1;
    })
    .finally(cleanup);
