/**
 * LIVE checks for the Daily Gauntlet SWISS format, against the DEPLOYED
 * backend. The pure rules are covered by test/swissTournament.test.js; what
 * only works here is the SEAM: the deployed signUpGauntlet/gauntletPoll
 * callables, presence-gated pairing creating real `swiss` matches, finalize
 * routing a swiss result to applySwissResult (NON-elimination), Swiss
 * re-pairing (winners meet winners, no rematch), and the most-wins champion.
 *
 * Drives four players: round 1 a>b and c>d (all four stay in - the point of
 * non-elimination); round 2 pairs the two winners (a,c) and the two losers
 * (b,d) with no rematch; a beats c to finish 2-0 and is champion. A fifth
 * account signs up but never polls, to prove presence-gating never hands an
 * absent entrant a live match.
 *
 * Settles via the LOCAL finalizeMatch (latest code, routes `swiss`) so the
 * deployed debug finalizer needn't be redeployed.
 *
 * Run from functions/:  node live/swissChecks.js
 */
const fs = require("fs");
const {initializeApp, cert} = require("firebase-admin/app");
const {getFirestore, Timestamp, FieldValue} = require("firebase-admin/firestore");
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
  if (cond) {
    passed++; console.log(`  ok   ${name}`);
  } else {
    failed++; console.log(`  FAIL ${name} ${detail}`);
  }
}

const tokens = {};
async function call(uid, fn, data) {
  if (!tokens[uid]) {
    const custom = await auth.createCustomToken(uid);
    const r = await fetch(
        "https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=" + API_KEY,
        {method: "POST", headers: {"Content-Type": "application/json"},
          body: JSON.stringify({token: custom, returnSecureToken: true})});
    tokens[uid] = (await r.json()).idToken;
  }
  const r = await fetch(`https://us-central1-${PROJECT}.cloudfunctions.net/${fn}`, {
    method: "POST",
    headers: {"Content-Type": "application/json",
      Authorization: "Bearer " + tokens[uid]},
    body: JSON.stringify({data: data ?? {}}),
  });
  const j = await r.json().catch(() => ({}));
  return {status: r.status, body: j.result, raw: j};
}

const stamp = Date.now().toString(36);
const P = ["a", "b", "c", "d"].map((x) => `sw-${x}-${stamp}`);
const SILENT = `sw-e-${stamp}`; // signs up but never polls
const NOINTRO = `sw-ni-${stamp}`;
const TID = `swiss-${stamp}`;
const tRef = db.collection("tournaments").doc(TID);
const createdMatches = new Set();

async function makeUser(uid, i, {intro = true} = {}) {
  await auth.createUser({uid, email: `${uid}@example.com`, password: "Test12345!"});
  await db.collection("users").doc(uid).set({
    username: `Sw${i}${stamp}`, usernameLower: `sw${i}${stamp}`,
    rating: 1200, rankTitle: "Average Joe", rankedMatchesPlayed: 0,
    wins: 0, losses: 0, accountStatus: "active", isAdmin: false,
    createdAt: Timestamp.now(),
    ...(intro ? {profile: {introVideoUrl: `https://example.com/${uid}.mp4`}} : {}),
  });
}

/** Force a swiss match to a winner: mark completed, seed one ballot, and run
 * the LOCAL finalizeMatch (routes swiss -> applySwissResult). */
async function settle(matchId, winnerUid) {
  createdMatches.add(matchId);
  await db.collection("matches").doc(matchId).set({
    status: "completed", completedAt: FieldValue.serverTimestamp(),
    readyPlayerIds: [],
  }, {merge: true});
  await db.collection("votes").doc(matchId).collection("ballots")
      .doc(`v-${stamp}`).set({votedForPlayerId: winnerUid, weight: 1,
        timestamp: FieldValue.serverTimestamp()});
  const {finalizeMatch} = require("../matchFinalization");
  await finalizeMatch(matchId, {force: true}); // bypass the 90s vote window

}

async function entrants() {
  return ((await tRef.get()).data().swiss || {}).entrants || [];
}
function find(es, uid) {
  return es.find((e) => e.uid === uid);
}
/** Poll each uid once, in order, so presence accumulates and the present
 * waiting players pair. Returns the set of match ids seen. */
async function pollAll(uids) {
  const seen = new Set();
  for (const uid of uids) {
    const r = await call(uid, "gauntletPoll", {tournamentId: TID});
    if (r.body && r.body.state === "in_match") seen.add(r.body.matchId);
  }
  return seen;
}
async function matchOf(matchId) {
  return (await db.collection("matches").doc(matchId).get()).data();
}
function pairKey(m) {
  return [m.player1Id, m.player2Id].sort().join("|");
}

(async () => {
  try {
    console.log("\nsetup");
    for (const [i, uid] of P.entries()) await makeUser(uid, i);
    await makeUser(SILENT, 8);
    await makeUser(NOINTRO, 9, {intro: false});
    const now = Date.now();
    // Phase 1: signups OPEN (window in the future, status "open").
    await tRef.set({
      name: "Swiss Probe", format: "swiss", status: "open",
      windowStartMs: now + 3600 * 1000, windowEndMs: now + 2 * 3600 * 1000,
      prizeType: "points", createdAt: Timestamp.now(),
      swiss: {entrants: [], presence: {}},
    });

    console.log("\nsignup");
    for (const uid of [...P, SILENT]) {
      const r = await call(uid, "signUpGauntlet", {tournamentId: TID});
      check(`${uid} signs up at 0-0`,
          r.status === 200 && r.body.signedUp === true &&
          r.body.standing.wins === 0 && r.body.standing.losses === 0,
          JSON.stringify(r.raw).slice(0, 140));
    }
    const ni = await call(NOINTRO, "signUpGauntlet", {tournamentId: TID});
    check("an account with no intro video cannot sign up", ni.status !== 200,
        JSON.stringify(ni.raw).slice(0, 120));
    check("five entrants recorded", (await entrants()).length === 5);

    // Phase 2: open the battling window (signups now closed, field locked).
    await tRef.set({windowStartMs: Date.now() - 60000,
      windowEndMs: Date.now() + 3600 * 1000}, {merge: true});
    const closed = await call(NOINTRO, "signUpGauntlet", {tournamentId: TID});
    check("signups are closed once the window opens", closed.status !== 200,
        JSON.stringify(closed.raw).slice(0, 120));

    console.log("\nround 1 pairing (presence-gated)");
    const seen1 = await pollAll(P); // SILENT never polls
    check("polling pairs the four present players into two matches",
        seen1.size === 2, `matches=${[...seen1]}`);
    const cs1 = await entrants();
    check("all four pollers are in a match",
        P.every((u) => find(cs1, u).status === "in_match"));
    check("the silent (never-polled) entrant is NOT paired",
        find(cs1, SILENT).status === "waiting" &&
        !find(cs1, SILENT).currentMatchId,
        JSON.stringify(find(cs1, SILENT)));

    console.log("\nround 1 results (NON-elimination)");
    const r1matches = [...seen1];
    const r1winners = {};
    for (const matchId of r1matches) {
      const m = await matchOf(matchId);
      const winner = [m.player1Id, m.player2Id].sort()[0]; // deterministic
      r1winners[matchId] = winner;
      await settle(matchId, winner);
    }
    const cs2 = await entrants();
    check("nobody is eliminated - all five entrants remain",
        cs2.length === 5 && cs2.every((e) => e.status !== "done"),
        JSON.stringify(cs2.map((e) => [e.uid.slice(-6), e.wins, e.losses, e.status])));
    const winners1 = Object.values(r1winners);
    check("each winner is 1-0 and back to waiting",
        winners1.every((u) => {
          const e = find(cs2, u); return e.wins === 1 && e.losses === 0 &&
            e.status === "waiting";
        }));
    check("each loser is 0-1 and STILL in (waiting, not eliminated)",
        P.filter((u) => !winners1.includes(u)).every((u) => {
          const e = find(cs2, u); return e.wins === 0 && e.losses === 1 &&
            e.status === "waiting";
        }));

    console.log("\nround 2 pairing (Swiss: winners meet winners, no rematch)");
    const seen2 = await pollAll(P);
    check("the four pair into two fresh matches", seen2.size === 2,
        `matches=${[...seen2]}`);
    const r2pairs = [];
    for (const matchId of seen2) r2pairs.push(await matchOf(matchId));
    const winnerPair = new Set(winners1);
    const bothWinners = r2pairs.some((m) =>
      winnerPair.has(m.player1Id) && winnerPair.has(m.player2Id));
    check("the two 1-0 winners are paired together", bothWinners,
        JSON.stringify(r2pairs.map(pairKey)));
    // No rematch: none of the round-2 pairs equals a round-1 pair.
    const r1keys = new Set();
    for (const mid of r1matches) r1keys.add(pairKey(await matchOf(mid)));
    const noRematch = r2pairs.every((m) => !r1keys.has(pairKey(m)));
    check("no round-2 pair is a repeat of a round-1 pair", noRematch,
        `r1=${[...r1keys]} r2=${r2pairs.map(pairKey)}`);

    console.log("\nround 2 results + champion");
    // In each match the alphabetically-first player wins, so the winners-pair
    // resolves to a single 2-0 player.
    for (const matchId of seen2) {
      const m = await matchOf(matchId);
      await settle(matchId, [m.player1Id, m.player2Id].sort()[0]);
    }
    const cs3 = await entrants();
    const top = [...cs3].sort((a, b) => (b.wins - a.wins) || (a.losses - b.losses))[0];
    check("a 2-0 player exists (won both rounds)", top.wins === 2 && top.losses === 0,
        JSON.stringify(cs3.map((e) => [e.uid.slice(-6), e.wins, e.losses])));

    // End the window and sweep to crown the most-wins champion.
    await tRef.set({windowEndMs: Date.now() - 1000}, {merge: true});
    const {sweepGauntlet} = require("../swissPlay");
    const sweep = await sweepGauntlet();
    check("sweepGauntlet runs against real Firestore without throwing",
        sweep && Array.isArray(sweep.results), JSON.stringify(sweep).slice(0, 160));
    const t = (await tRef.get()).data();
    check("the tournament completes", t.status === "completed", t.status);
    check("the champion is the most-wins player (2-0)", t.winnerId === top.uid,
        `winner=${t.winnerId} expected=${top.uid}`);
    check("still non-elimination: all five entrants are in the final field",
        (await entrants()).length === 5);

    console.log(`\n${passed} passed, ${failed} failed`);
  } catch (e) {
    console.error("THREW:", e && e.stack);
    failed++;
  } finally {
    for (const matchId of createdMatches) {
      const ballots = await db.collection("votes").doc(matchId)
          .collection("ballots").get().catch(() => ({docs: []}));
      for (const b of ballots.docs) await b.ref.delete().catch(() => {});
      await db.collection("matches").doc(matchId).delete().catch(() => {});
    }
    await tRef.delete().catch(() => {});
    for (const uid of [...P, SILENT, NOINTRO]) {
      await db.collection("users").doc(uid).delete().catch(() => {});
      await auth.deleteUser(uid).catch(() => {});
    }
    process.exit(failed === 0 ? 0 : 1);
  }
})();
