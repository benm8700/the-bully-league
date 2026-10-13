/**
 * LIVE checks for the judges' DEBATE recording GATES (startDebateRecording).
 *
 * Deliberately covers only the gate/refusal paths, which run BEFORE any Agora
 * call: a non-judge is refused, and a seated judge is told "not in debate"
 * while the battle is still live. The happy path (an actual Agora cloud
 * recording on the judges channel) needs a live 5-judge channel and is dry-run
 * territory - running it here would start a real empty recording.
 *
 * Run from functions/:  node live/debateRecordingChecks.js
 */
const fs = require("fs");
const {initializeApp, cert} = require("firebase-admin/app");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {getAuth} = require("firebase-admin/auth");

const E = fs.readFileSync("../website/.env.local", "utf8");
function val(k) {
  const line = E.split(/\r?\n/).find((l) => l.startsWith(k + "="));
  let v = line.slice(k.length + 1).trim();
  if (v.startsWith("\"") && v.endsWith("\"")) v = v.slice(1, -1);
  return v.replace(/\\n/g, "\n");
}
const PROJECT = "the-bully-league";
const API_KEY = "AIzaSyD-yeC1osuXpfwXWNZPnLEOq7yLviM7J0c";
initializeApp({credential: cert({
  projectId: val("FIREBASE_PROJECT_ID"),
  clientEmail: val("FIREBASE_CLIENT_EMAIL"),
  privateKey: val("FIREBASE_PRIVATE_KEY"),
})});
const db = getFirestore();
const auth = getAuth();

let passed = 0; let failed = 0;
function check(name, cond, detail = "") {
  if (cond) { passed++; console.log(`  ok   ${name}`); } else {
    failed++; console.log(`  FAIL ${name} ${detail}`);
  }
}

async function callAs(uid, fn, data) {
  const custom = await auth.createCustomToken(uid);
  const r = await fetch("https://identitytoolkit.googleapis.com/v1/accounts:" +
      "signInWithCustomToken?key=" + API_KEY,
  {method: "POST", headers: {"Content-Type": "application/json"},
    body: JSON.stringify({token: custom, returnSecureToken: true})});
  const idToken = (await r.json()).idToken;
  const resp = await fetch(`https://us-central1-${PROJECT}.cloudfunctions.net/${fn}`, {
    method: "POST",
    headers: {"Content-Type": "application/json", Authorization: "Bearer " + idToken},
    body: JSON.stringify({data: data ?? {}}),
  });
  const j = await resp.json().catch(() => ({}));
  return {status: resp.status, result: j.result, errMessage: j.error?.message};
}

const s = Date.now().toString(36);
const J1 = `dr-j1-${s}`; const X = `dr-x-${s}`;
const P1 = `dr-p1-${s}`; const P2 = `dr-p2-${s}`;
const TID = `dr-t-${s}`; const M = `drm-${s}`;
const all = [J1, X, P1, P2];

async function run() {
  await Promise.all(all.map((u) =>
    auth.createUser({uid: u, email: `${u}@example.com`, password: "testpass123"}).catch(() => {})));
  await db.collection("tournaments").doc(TID).set({
    format: "mainstage", status: "live", judges: [J1], handPickedJudges: [J1],
  });
  await db.collection("matches").doc(M).set({
    status: "in_progress", mode: "tournament", player1Id: P1, player2Id: P2,
    mainStage: {tournamentId: TID, roundIdx: 0, matchIdx: 0},
  });

  const x = await callAs(X, "startDebateRecording", {matchId: M});
  check("a non-judge can't start the debate recording",
      x.status !== 200 && /seated judges/i.test(x.errMessage || ""), JSON.stringify(x));

  const early = await callAs(J1, "startDebateRecording", {matchId: M});
  check("a judge gets 'not in debate' while the battle is still live",
      early.status === 200 && early.result?.started === false &&
        early.result?.reason === "not-in-debate", JSON.stringify(early));
}

run().then(() => console.log(`\n${passed} passed, ${failed} failed`))
    .catch((e) => { console.error("FAILED:", e.message); failed++; })
    .finally(async () => {
      for (const u of all) await auth.deleteUser(u).catch(() => {});
      await db.collection("tournaments").doc(TID).delete().catch(() => {});
      await db.collection("matches").doc(M).delete().catch(() => {});
      console.log("cleanup done");
      process.exit(failed > 0 ? 1 : 0);
    });
