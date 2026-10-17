/**
 * LIVE checks for leaveMatch against the DEPLOYED backend.
 *
 * The rule (developer's): one player leaving keeps a live match alive (the
 * other may still be there or rejoin); BOTH leaving cancels it as a
 * no-contest so it stops lingering as "pending". The pure decision is covered
 * by test/matchmaking.test.js (applyLeave); what only works here is the real
 * callable + a real match doc: that a non-participant is refused, that one
 * leave does NOT abandon, that the second leave DOES, and that it is
 * idempotent on an already-settled match.
 *
 * Run from functions/:  node live/leaveMatchChecks.js
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

const tokens = {};
async function idToken(uid) {
  if (tokens[uid]) return tokens[uid];
  const custom = await auth.createCustomToken(uid);
  const r = await fetch(
      "https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=" + API_KEY,
      {method: "POST", headers: {"Content-Type": "application/json"},
        body: JSON.stringify({token: custom, returnSecureToken: true})});
  const j = await r.json();
  if (!j.idToken) throw new Error("sign-in failed: " + JSON.stringify(j));
  tokens[uid] = j.idToken;
  return j.idToken;
}
async function call(uid, fn, data) {
  const token = await idToken(uid);
  const r = await fetch(`https://us-central1-${PROJECT}.cloudfunctions.net/${fn}`, {
    method: "POST",
    headers: {"Content-Type": "application/json", Authorization: "Bearer " + token},
    body: JSON.stringify({data: data ?? {}}),
  });
  const j = await r.json().catch(() => ({}));
  return {status: r.status, body: j.result, raw: j};
}

const stamp = Date.now().toString(36);
const A = `lm-a-${stamp}`;
const B = `lm-b-${stamp}`;
const C = `lm-c-${stamp}`;
const MATCH = `lmtest_${stamp}`;

async function makeUser(uid) {
  await auth.createUser({uid, email: `${uid}@example.com`, password: "Test12345!"});
  await db.collection("users").doc(uid).set({
    username: uid, usernameLower: uid,
    rating: 1200, rankTitle: "Average Joe", rankedMatchesPlayed: 0,
    wins: 0, losses: 0, points: 0, pointsBalance: 0,
    accountStatus: "active", isAdmin: false, createdAt: Timestamp.now(),
  });
}

async function matchState() {
  return (await db.collection("matches").doc(MATCH).get()).data();
}

(async () => {
  try {
    for (const uid of [A, B, C]) await makeUser(uid);
    await db.collection("matches").doc(MATCH).set({
      player1Id: A, player2Id: B, mode: "friend", status: "pending",
      channelName: `match_${MATCH}`, origin: "challenge",
      voteFinalized: false, winnerId: null, voteCount: 0,
      readyPlayerIds: [], createdAt: Timestamp.now(), completedAt: null,
    });

    let r = await call(C, "leaveMatch", {matchId: MATCH});
    check("a non-participant is refused", r.status === 403, JSON.stringify(r.raw).slice(0, 160));

    r = await call(A, "leaveMatch", {matchId: MATCH});
    let m = await matchState();
    check("player A leaving does NOT abandon the match",
        r.body?.abandoned === false && m.status === "pending" &&
        (m.leftPlayerIds || []).includes(A),
        `abandoned=${r.body?.abandoned} status=${m.status} left=${JSON.stringify(m.leftPlayerIds)}`);

    r = await call(A, "leaveMatch", {matchId: MATCH});
    m = await matchState();
    check("A leaving twice is idempotent (still pending, not both-left)",
        r.body?.abandoned === false && m.status === "pending" &&
        (m.leftPlayerIds || []).filter((x) => x === A).length === 1,
        `left=${JSON.stringify(m.leftPlayerIds)}`);

    r = await call(B, "leaveMatch", {matchId: MATCH});
    m = await matchState();
    check("the SECOND player leaving abandons it as a no-contest",
        r.body?.abandoned === true && m.status === "abandoned" &&
        m.abandonedReason === "both-left" && m.winnerId === null &&
        m.voteFinalized === true,
        `abandoned=${r.body?.abandoned} status=${m.status} reason=${m.abandonedReason}`);

    r = await call(A, "leaveMatch", {matchId: MATCH});
    check("leaving an already-abandoned match is a no-op",
        r.body?.abandoned === false, JSON.stringify(r.raw).slice(0, 160));

    r = await call(A, "leaveMatch", {matchId: `nope_${stamp}`});
    check("leaving a nonexistent match is a safe no-op",
        r.status === 200 && r.body?.abandoned === false,
        JSON.stringify(r.raw).slice(0, 160));

    // A STARTED friend battle (both readied): ONE leaving ends it now.
    const LIVE = `lmlive_${stamp}`;
    await db.collection("matches").doc(LIVE).set({
      player1Id: A, player2Id: B, mode: "friend", status: "pending",
      channelName: `match_${LIVE}`, origin: "challenge",
      voteFinalized: false, winnerId: null, voteCount: 0,
      readyPlayerIds: [A, B], createdAt: Timestamp.now(), completedAt: null,
    });
    r = await call(A, "leaveMatch", {matchId: LIVE});
    const lm = (await db.collection("matches").doc(LIVE).get()).data();
    check("a started friend battle ends when ONE player leaves",
        r.body?.abandoned === true && lm.status === "abandoned" &&
        lm.abandonedReason === "opponent-left",
        `abandoned=${r.body?.abandoned} status=${lm.status} reason=${lm.abandonedReason}`);
    await db.collection("matches").doc(LIVE).delete().catch(() => {});

    // A STARTED ranked battle: one leaving does NOT no-contest it (forfeit is
    // a separate task), so it stays pending on a single leave.
    const RANKED = `lmrank_${stamp}`;
    await db.collection("matches").doc(RANKED).set({
      player1Id: A, player2Id: B, mode: "ranked", status: "pending",
      channelName: `match_${RANKED}`,
      voteFinalized: false, winnerId: null, voteCount: 0,
      readyPlayerIds: [A, B], createdAt: Timestamp.now(), completedAt: null,
    });
    r = await call(A, "leaveMatch", {matchId: RANKED});
    const rk = (await db.collection("matches").doc(RANKED).get()).data();
    check("a started ranked battle is NOT ended by one leave (stays pending)",
        r.body?.abandoned === false && rk.status === "pending",
        `abandoned=${r.body?.abandoned} status=${rk.status}`);
    await db.collection("matches").doc(RANKED).delete().catch(() => {});

    // DELIBERATE pre-battle cancel (the bio-reveal Leave/X): ends the match as
    // a no-contest for BOTH, so neither player is stranded waiting.
    const CANCEL = `lmcancel_${stamp}`;
    await db.collection("matches").doc(CANCEL).set({
      player1Id: A, player2Id: B, mode: "ranked", status: "pending",
      readyPlayerIds: [A], // one readied, round not started
      voteFinalized: false, winnerId: null, createdAt: Timestamp.now(),
    });
    r = await call(A, "leaveMatch", {matchId: CANCEL, cancel: true});
    const cm = (await db.collection("matches").doc(CANCEL).get()).data();
    check("a deliberate pre-battle cancel abandons it no-contest (both freed)",
        r.body?.abandoned === true && cm.status === "abandoned" &&
        cm.abandonedReason === "cancelled-pre-battle" && cm.winnerId === null,
        `abandoned=${r.body?.abandoned} status=${cm.status} reason=${cm.abandonedReason}`);
    await db.collection("matches").doc(CANCEL).delete().catch(() => {});

    // But cancel must NOT override a battle already underway (battleStartedAt).
    const CANCEL2 = `lmcancel2_${stamp}`;
    await db.collection("matches").doc(CANCEL2).set({
      player1Id: A, player2Id: B, mode: "ranked", status: "pending",
      readyPlayerIds: [A, B], battleStartedAt: Date.now(),
      voteFinalized: false, winnerId: null, createdAt: Timestamp.now(),
    });
    r = await call(A, "leaveMatch", {matchId: CANCEL2, cancel: true});
    const cm2 = (await db.collection("matches").doc(CANCEL2).get()).data();
    check("cancel is ignored once a round has started (stays pending)",
        cm2.status === "pending",
        `status=${cm2.status}`);
    await db.collection("matches").doc(CANCEL2).delete().catch(() => {});
  } catch (e) {
    console.error("ERROR", e);
    failed++;
  } finally {
    await db.collection("matches").doc(MATCH).delete().catch(() => {});
    for (const uid of [A, B, C]) {
      await db.collection("users").doc(uid).delete().catch(() => {});
      await auth.deleteUser(uid).catch(() => {});
    }
  }
  console.log(`\nleaveMatch: ${passed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
})();
