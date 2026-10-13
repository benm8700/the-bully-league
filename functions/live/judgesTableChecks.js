/**
 * LIVE checks for the Main Stage judges' video table backend (stage 1):
 *   - generateAgoraToken's `judges_<matchId>` branch (seated judges publish)
 *   - watchJudgesTable (the crowd's subscriber token + the debate-phase gate)
 *   - castMainStageJudgeVote's new "vote only during the debate" gate
 *
 * Run from functions/:  node live/judgesTableChecks.js
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
  return {status: resp.status, result: j.result, errStatus: j.error?.status,
    errMessage: j.error?.message};
}

const s = Date.now().toString(36);
const J1 = `jt-j1-${s}`; const J2 = `jt-j2-${s}`; const J3 = `jt-j3-${s}`;
const P1 = `jt-p1-${s}`; const P2 = `jt-p2-${s}`;
const C = `jt-c-${s}`; const X = `jt-x-${s}`;
const TID = `jt-t-${s}`;
const M = `jtm-${s}`;
const all = [J1, J2, J3, P1, P2, C, X];

async function cleanup() {
  for (const u of all) {
    await auth.deleteUser(u).catch(() => {});
    await db.collection("users").doc(u).delete().catch(() => {});
  }
  await db.recursiveDelete(db.collection("matches").doc(M)).catch(() => {});
  await db.collection("tournaments").doc(TID).delete().catch(() => {});
}

async function run() {
  await Promise.all(all.map((u) =>
    auth.createUser({uid: u, email: `${u}@example.com`, password: "testpass123"})
        .catch(() => {})));
  await Promise.all(all.map((u) =>
    db.collection("users").doc(u).set({username: u, createdAt: FieldValue.serverTimestamp()})));
  await db.collection("tournaments").doc(TID).set({
    format: "mainstage", status: "live",
    judges: [J1, J2, J3], handPickedJudges: [J1],
  });
  await db.collection("matches").doc(M).set({
    status: "in_progress", mode: "tournament",
    player1Id: P1, player2Id: P2,
    mainStage: {tournamentId: TID, roundIdx: 0, matchIdx: 0},
    channelName: `match_${M}`,
  });

  // A seated judge gets a PUBLISHER token for the judges' table channel.
  const jt = await callAs(J1, "generateAgoraToken", {channelName: `judges_${M}`});
  check("a seated judge gets a judges'-table publisher token",
      jt.status === 200 && !!jt.result?.token, JSON.stringify(jt));

  // An outsider (not on the panel) is refused the publisher token.
  const xt = await callAs(X, "generateAgoraToken", {channelName: `judges_${M}`});
  check("a non-judge is refused the judges'-table publisher token",
      xt.status !== 200 && /seated judges/i.test(xt.errMessage || ""),
      JSON.stringify(xt));

  // Voting is refused while the battle is still being fought.
  const earlyVote = await callAs(J1, "castMainStageJudgeVote",
      {matchId: M, winnerUid: P1});
  check("a judge can't vote while the battle is still in progress",
      earlyVote.status !== 200 && /debate|ends/i.test(earlyVote.errMessage || ""),
      JSON.stringify(earlyVote));

  // The crowd can't watch the table before the debate (battle not over).
  const earlyWatch = await callAs(C, "watchJudgesTable", {matchId: M});
  check("the crowd can't watch the table before the battle ends",
      earlyWatch.status !== 200 && /judges haven't|haven't started/i.test(earlyWatch.errMessage || ""),
      JSON.stringify(earlyWatch));

  // Battle ends -> the debate opens.
  await db.collection("matches").doc(M).update({status: "completed"});

  // Now the crowd gets a subscriber token + the panel to label the tiles.
  const watch = await callAs(C, "watchJudgesTable", {matchId: M});
  check("the crowd gets a judges'-table subscriber token during the debate",
      watch.status === 200 && !!watch.result?.token, JSON.stringify(watch));
  check("...and the panel + head judge come back to label the tiles",
      Array.isArray(watch.result?.judges) && watch.result.judges.length === 3 &&
        watch.result.headJudge === J1 && watch.result.seatUidBase === 11,
      JSON.stringify(watch.result));

  // A judge CAN vote now (one of three - not yet decisive).
  const vote = await callAs(J1, "castMainStageJudgeVote", {matchId: M, winnerUid: P1});
  check("a judge can vote during the debate, and everyone can read the vote",
      vote.status === 200 && vote.result?.decided === false, JSON.stringify(vote));
  const voteDoc = await db.collection("matches").doc(M)
      .collection("mainStageVotes").doc(J1).get();
  check("the vote is recorded and the rules let any signed-in viewer read it",
      voteDoc.exists && voteDoc.data().winnerUid === P1);

  // Once a verdict lands, the table is over.
  await db.collection("matches").doc(M).update({judgeWinnerId: P1});
  const lateWatch = await callAs(C, "watchJudgesTable", {matchId: M});
  check("once the verdict is in, the table is closed",
      lateWatch.status !== 200 && /verdict/i.test(lateWatch.errMessage || ""),
      JSON.stringify(lateWatch));
}

run().then(() => console.log(`\n${passed} passed, ${failed} failed`))
    .catch((e) => { console.error("FAILED:", e.message); failed++; })
    .finally(async () => { await cleanup(); console.log("cleanup done");
      process.exit(failed > 0 ? 1 : 0); });
