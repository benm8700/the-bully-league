/**
 * LIVE checks for the minimum gap between votes, against the DEPLOYED
 * backend.
 *
 * This is the half of the anti-farming design a modified client cannot
 * skip. The client-side watch gate is friction and honest UX; this is the
 * floor. Worth checking live rather than in a unit test precisely because
 * the value of it is that it runs on the server.
 *
 * Run from functions/:  node live/voteGateChecks.js
 */
const fs = require("fs");
const {initializeApp, cert} = require("firebase-admin/app");
const {getFirestore, Timestamp} = require("firebase-admin/firestore");
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

let token = null;
async function call(uid, fn, data) {
  if (!token) {
    const custom = await auth.createCustomToken(uid);
    const r = await fetch(
        "https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=" + API_KEY,
        {method: "POST", headers: {"Content-Type": "application/json"},
          body: JSON.stringify({token: custom, returnSecureToken: true})});
    token = (await r.json()).idToken;
  }
  const r = await fetch(`https://us-central1-${PROJECT}.cloudfunctions.net/${fn}`, {
    method: "POST",
    headers: {"Content-Type": "application/json", Authorization: "Bearer " + token},
    body: JSON.stringify({data: data ?? {}}),
  });
  const j = await r.json().catch(() => ({}));
  return {status: r.status, body: j.result, raw: j};
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const stamp = Date.now().toString(36);
const V = `vg-${stamp}`;
const P1 = `vg-p1-${stamp}`;
const P2 = `vg-p2-${stamp}`;
const matches = [`vgm1-${stamp}`, `vgm2-${stamp}`];

(async () => {
  try {
    // A judge old enough to vote at full weight.
    await auth.createUser({uid: V, email: `${V}@example.com`,
      password: "Test12345!"});
    await db.collection("users").doc(V).set({
      username: `Vg${stamp}`, usernameLower: `vg${stamp}`,
      rating: 1200, rankTitle: "Average Joe", rankedMatchesPlayed: 0,
      wins: 0, losses: 0, accountStatus: "active", isAdmin: false,
      createdAt: Timestamp.now(),
    });
    // Two completed matches for them to judge, both inside the window.
    for (const id of matches) {
      await db.collection("matches").doc(id).set({
        player1Id: P1, player2Id: P2, mode: "ranked", status: "completed",
        createdAt: Timestamp.now(), completedAt: Timestamp.now(),
        voteFinalized: false, winnerId: null, voteCount: 0,
      });
    }
    // A voting session, so no CAPTCHA token is needed.
    await db.collection("voteSessions").doc(V).set({
      votesRemaining: 25,
      expiresAt: Timestamp.fromMillis(Date.now() + 20 * 60 * 1000),
    });

    console.log("\nthe floor on voting speed");
    let r = await call(V, "castVote",
        {matchId: matches[0], votedForPlayerId: P1});
    check("the first vote is accepted", r.status === 200,
        JSON.stringify(r.raw).slice(0, 160));

    r = await call(V, "castVote",
        {matchId: matches[1], votedForPlayerId: P1});
    check("A SECOND VOTE IMMEDIATELY AFTER IS REFUSED",
        r.status !== 200 && JSON.stringify(r.raw).includes("Slow down"),
        JSON.stringify(r.raw).slice(0, 160));

    const ballots = await db.collection("votes").doc(matches[1])
        .collection("ballots").get();
    check("...and no ballot was written for it", ballots.empty,
        "(only meaningful if the first vote above succeeded)");

    console.log("\nbut it does not ration honest judging");
    await sleep(5000);
    r = await call(V, "castVote",
        {matchId: matches[1], votedForPlayerId: P2});
    check("after a few seconds the same vote goes through",
        r.status === 200, JSON.stringify(r.raw).slice(0, 160));

    const voter = await db.collection("users").doc(V).get();
    check("the last-vote stamp is recorded",
        Number.isFinite(Number(voter.data().lastVoteAtMs)));
  } finally {
    for (const id of matches) {
      const b = await db.collection("votes").doc(id)
          .collection("ballots").get();
      await Promise.all(b.docs.map((d) => d.ref.delete()));
      await db.collection("matches").doc(id).delete().catch(() => {});
    }
    await db.collection("voteSessions").doc(V).delete().catch(() => {});
    await db.recursiveDelete(db.collection("users").doc(V)).catch(() => {});
    await auth.deleteUser(V).catch(() => {});
    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
  }
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
