/**
 * Verifies the Main Stage DRY-RUN STAGING end to end against the deployed
 * backend, headlessly: seeds three throwaway accounts, runs the REAL
 * primeMainStageDryRun.js script, then drives the exact callables the two
 * devices + judge would (startMainStageBattle x2, the real completeMatch,
 * castMainStageJudgeVote, then settleMainStageBattle after the 30s judges'-room
 * grace) and asserts the staged bracket settles and advances to the winner.
 * Finally runs the REAL teardown script and asserts it cleaned up + restored.
 *
 * This proves the thing the developer will run actually works, AND closes the
 * one seam mainStageSettleChecks skipped: the real completeMatch() on a
 * mainstage match (the settle check wrote status:"completed" directly).
 *
 * Run from functions/:  node live/verifyDryRunStaging.js
 */
const fs = require("fs");
const assert = require("assert");
const {execFileSync} = require("child_process");
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

const db = getFirestore();
const API_KEY = "AIzaSyD-yeC1osuXpfwXWNZPnLEOq7yLviM7J0c";
const REGION = "https://us-central1-the-bully-league.cloudfunctions.net";
const TID = "mainstage_dryrun";

const T1 = "msdry-verify-1";
const T2 = "msdry-verify-2";
const TJ = "msdry-verify-j";

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
  batch.set(db.collection("users").doc(T1), {username: "DryVerify1", usernameLower: "dryverify1", rating: 1200, wins: 0, losses: 0});
  batch.set(db.collection("users").doc(T2), {username: "DryVerify2", usernameLower: "dryverify2", rating: 1200, wins: 0, losses: 0});
  batch.set(db.collection("users").doc(TJ), {username: "DryVerifyJ", usernameLower: "dryverifyj", rating: 1200});
  await batch.commit();
}

async function cleanup() {
  try {
    execFileSync("node", ["live/teardownMainStageDryRun.js"], {stdio: "ignore"});
  } catch (_) {/* teardown is also asserted below; ignore here */}
  for (const u of [T1, T2, TJ]) {
    await db.collection("users").doc(u).delete().catch(() => {});
    await getAuth().deleteUser(u).catch(() => {});
  }
}

async function run() {
  await seed();

  await check("prime script stages a live mainstage tournament", () => {
    const out = execFileSync("node",
        ["live/primeMainStageDryRun.js", "DryVerify1", "DryVerify2", "DryVerifyJ"],
        {encoding: "utf8"});
    assert.ok(out.includes("Staged live Main Stage"), out);
  });

  let doc;
  await check("the staged doc is a valid live bracket (callout semi = the two battlers)", async () => {
    doc = (await db.collection("tournaments").doc(TID).get()).data();
    assert.strictEqual(doc.status, "live");
    assert.strictEqual(doc.format, "mainstage");
    const semi0 = doc.bracket.rounds[0].matches[0];
    assert.strictEqual(semi0.a, T1);
    assert.strictEqual(semi0.b, T2);
    assert.deepStrictEqual(doc.judges, [TJ]);
  });

  const tokT1 = await idToken(T1);
  const tokT2 = await idToken(T2);
  const tokTJ = await idToken(TJ);

  let matchId;
  await check("battler1 starts the semifinal (startMainStageBattle)", async () => {
    const r = await callFn("startMainStageBattle", tokT1, {tournamentId: TID, roundIdx: 0, matchIdx: 0});
    assert.strictEqual(r.status, 200, JSON.stringify(r.body));
    matchId = r.body.result.matchId;
    assert.ok(matchId);
    assert.strictEqual(r.body.result.agoraUid, 1);
  });

  await check("battler2 joins the SAME match", async () => {
    const r = await callFn("startMainStageBattle", tokT2, {tournamentId: TID, roundIdx: 0, matchIdx: 0});
    assert.strictEqual(r.status, 200, JSON.stringify(r.body));
    assert.strictEqual(r.body.result.matchId, matchId);
    assert.strictEqual(r.body.result.agoraUid, 2);
  });

  await check("the REAL completeMatch settles the pending mainstage battle", async () => {
    // The seam mainStageSettleChecks skipped - the battle screen calls this.
    const r = await callFn("completeMatch", tokT1, {matchId});
    assert.strictEqual(r.status, 200, JSON.stringify(r.body));
    const m = (await db.collection("matches").doc(matchId).get()).data();
    assert.strictEqual(m.status, "completed");
  });

  await check("a completed battle cannot be re-entered (blocked until resolved)", async () => {
    // The bug the dry run hit: re-starting handed back the ended match, whose
    // Agora token is then refused ("battle setup failed"). Now refused cleanly.
    const r = await callFn("startMainStageBattle", tokT1, {tournamentId: TID, roundIdx: 0, matchIdx: 0});
    assert.strictEqual(r.status, 400, JSON.stringify(r.body));
    assert.match(r.body.error.message, /already been played/);
  });

  await check("the one-judge panel's vote LOCKS the verdict (no advance yet)", async () => {
    // Current model (judges'-room grace split, 2026-10-12): a deciding vote
    // STAMPS judgeWinnerId immediately but does NOT advance the bracket - the
    // judges stay on camera through a 30s grace, then settleMainStageBattle
    // finalizes. So the verdict is locked here; the matchup winner is still null.
    const r = await callFn("castMainStageJudgeVote", tokTJ, {matchId, winnerUid: T1});
    assert.strictEqual(r.status, 200, JSON.stringify(r.body));
    assert.strictEqual(r.body.result.decided, true, JSON.stringify(r.body));
    assert.strictEqual(r.body.result.winner, T1, JSON.stringify(r.body));
    const m = (await db.collection("matches").doc(matchId).get()).data();
    assert.strictEqual(m.judgeWinnerId, T1, "verdict stamped synchronously on the deciding vote");
    const t = (await db.collection("tournaments").doc(TID).get()).data();
    assert.strictEqual(t.bracket.rounds[0].matches[0].winner, null,
        "bracket must NOT advance until the grace settles");
  });

  // (The panel gate - a non-judge refused on an UNDECIDED match - is covered
  // by mainStageSettleChecks; here the battle is already decided, where the
  // `already` short-circuit correctly returns the known result as a no-op.)

  await check("after the grace, settleMainStageBattle finalizes + advances the bracket", async () => {
    // settleMainStageBattle is the client nudge at the end of the 30s grace; the
    // server re-checks the buffer, so it refuses (settled:false, remainingMs>0)
    // until the grace elapses. Poll it to the finish rather than hardcoding 30s.
    let settled = false;
    for (let i = 0; i < 10 && !settled; i++) {
      const r = await callFn("settleMainStageBattle", tokT1, {matchId});
      assert.strictEqual(r.status, 200, JSON.stringify(r.body));
      const res = r.body.result || {};
      if (res.settled) { settled = true; break; }
      const waitMs = Number.isFinite(res.remainingMs) ? res.remainingMs + 500 : 4000;
      await new Promise((res2) => setTimeout(res2, Math.min(waitMs, 8000)));
    }
    assert.ok(settled, "battle settled after the grace");
    const m = (await db.collection("matches").doc(matchId).get()).data();
    assert.strictEqual(m.voteFinalized, true, "match finalized");
    const t = (await db.collection("tournaments").doc(TID).get()).data();
    assert.strictEqual(t.bracket.rounds[0].matches[0].winner, T1, "bracket advanced to the winner");
  });

  await check("teardown removes the tournament, bench, and battle match", async () => {
    execFileSync("node", ["live/teardownMainStageDryRun.js"], {encoding: "utf8"});
    assert.ok(!(await db.collection("tournaments").doc(TID).get()).exists, "tournament gone");
    assert.ok(!(await db.collection("matches").doc(matchId).get()).exists, "match gone");
    assert.ok(!(await db.collection("users").doc("msdry-bench-1").get()).exists, "bench gone");
  });

  await check("teardown restored battler ratings from the snapshot", async () => {
    const a = (await db.collection("users").doc(T1).get()).data();
    const b = (await db.collection("users").doc(T2).get()).data();
    assert.strictEqual(a.rating, 1200, `T1 rating restored (was ${a.rating})`);
    assert.strictEqual(b.rating, 1200, `T2 rating restored (was ${b.rating})`);
  });
}

run()
    .then(() => console.log(`\n${passed} passed`))
    .catch((e) => {
      console.error("FAILED:", e.message);
      process.exitCode = 1;
    })
    .finally(cleanup);
