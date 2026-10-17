/**
 * LIVE checks for claimBattleForfeit against the DEPLOYED backend.
 *
 * The pure rule is covered by test/matchmaking.test.js (battleForfeitDecision).
 * What only works here: the real callable + a real ranked match + real user
 * docs, proving a forfeit actually MOVES rating (winner up, loser down, W/L
 * updated), that a present opponent blocks it, that a non-participant is
 * refused, and that a both-gone claim is a no-contest with no rating move.
 *
 * Run from functions/:  node live/claimBattleForfeitChecks.js
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
const A = `ff-a-${stamp}`; // present (claims)
const B = `ff-b-${stamp}`; // absent (forfeits)
const C = `ff-c-${stamp}`; // outsider
const MATCH = `fftest_${stamp}`;
const STALE_MS = 60 * 1000;

async function makeUser(uid) {
  await auth.createUser({uid, email: `${uid}@example.com`, password: "Test12345!"});
  await db.collection("users").doc(uid).set({
    username: uid, usernameLower: uid,
    rating: 1200, rankTitle: "Average Joe", rankedMatchesPlayed: 0,
    wins: 0, losses: 0, points: 0, pointsBalance: 0,
    accountStatus: "active", isAdmin: false, createdAt: Timestamp.now(),
  });
}
async function userDoc(uid) {
  return (await db.collection("users").doc(uid).get()).data();
}
async function matchDoc() {
  return (await db.collection("matches").doc(MATCH).get()).data();
}
async function writeMatch(lastSeen, extra = {}) {
  await db.collection("matches").doc(MATCH).set({
    player1Id: A, player2Id: B, mode: "ranked", status: "pending",
    channelName: `match_${MATCH}`, readyPlayerIds: [A, B],
    lastSeenAt: lastSeen, leftPlayerIds: [],
    // Round has started -> an absence is a forfeit (not a warm-up no-contest).
    battleStartedAt: Date.now(),
    player1Rating: 1200, player2Rating: 1200,
    voteFinalized: false, winnerId: null, voteCount: 0,
    settings: {roundCount: 3, fullConfidenceVotes: 10},
    createdAt: Timestamp.now(), completedAt: null,
    ...extra,
  });
}

(async () => {
  try {
    for (const uid of [A, B, C]) await makeUser(uid);

    // Opponent PRESENT (fresh heartbeat) -> refused.
    const now = Date.now();
    await writeMatch({[A]: now, [B]: now});
    let r = await call(A, "claimBattleForfeit", {matchId: MATCH});
    check("a present opponent blocks the forfeit",
        r.body?.settled === false && r.body?.reason === "opponent-present",
        JSON.stringify(r.raw).slice(0, 160));

    // A non-participant is refused.
    r = await call(C, "claimBattleForfeit", {matchId: MATCH});
    check("a non-participant is refused", r.status === 403,
        JSON.stringify(r.raw).slice(0, 160));

    // Opponent STALE -> A wins by forfeit, and rating MOVES.
    await writeMatch({[A]: now, [B]: now - STALE_MS});
    r = await call(A, "claimBattleForfeit", {matchId: MATCH});
    const m = await matchDoc();
    const a = await userDoc(A); const b = await userDoc(B);
    check("a stale opponent forfeits -> caller wins",
        r.body?.settled === true && r.body?.winnerId === A &&
        m.status === "completed" && m.forfeitWinnerId === A &&
        m.voteFinalized === true,
        `settled=${r.body?.settled} winner=${r.body?.winnerId} status=${m.status}`);
    check("the forfeit MOVED rating (winner up, loser down)",
        a.rating > 1200 && b.rating < 1200,
        `A.rating=${a.rating} B.rating=${b.rating}`);
    check("W/L updated (winner +win, loser +loss)",
        a.wins === 1 && b.losses === 1,
        `A.wins=${a.wins} B.losses=${b.losses}`);

    // Idempotent: a second claim on the finalized match does nothing new.
    r = await call(A, "claimBattleForfeit", {matchId: MATCH});
    check("a second claim is a no-op (already settled)",
        r.body?.settled === false, JSON.stringify(r.raw).slice(0, 160));

    // BOTH gone -> no-contest, no rating move.
    const MATCH2 = `fftest2_${stamp}`;
    await db.collection("matches").doc(MATCH2).set({
      player1Id: A, player2Id: B, mode: "ranked", status: "pending",
      channelName: `match_${MATCH2}`, readyPlayerIds: [A, B],
      lastSeenAt: {[A]: now - STALE_MS, [B]: now - STALE_MS}, leftPlayerIds: [],
      player1Rating: 1200, player2Rating: 1200,
      voteFinalized: false, winnerId: null,
      settings: {roundCount: 3}, createdAt: Timestamp.now(), completedAt: null,
    });
    const aBefore = (await userDoc(A)).rating;
    r = await call(A, "claimBattleForfeit", {matchId: MATCH2});
    const m2 = (await db.collection("matches").doc(MATCH2).get()).data();
    const aAfter = (await userDoc(A)).rating;
    check("both gone -> no-contest (no winner, no rating move)",
        r.body?.winnerId === null && m2.status === "abandoned" &&
        aAfter === aBefore,
        `winner=${r.body?.winnerId} status=${m2.status} rating ${aBefore}->${aAfter}`);
    await db.collection("matches").doc(MATCH2).delete().catch(() => {});

    // WARM-UP departure (no battleStartedAt): a stale opponent is a NO-CONTEST,
    // not a loss - and rating does NOT move.
    const MATCH3 = `fftest3_${stamp}`;
    await db.collection("matches").doc(MATCH3).set({
      player1Id: A, player2Id: B, mode: "ranked", status: "pending",
      channelName: `match_${MATCH3}`, readyPlayerIds: [A, B],
      lastSeenAt: {[A]: now, [B]: now - STALE_MS}, leftPlayerIds: [],
      // NO battleStartedAt -> still in the warm-up.
      player1Rating: 1200, player2Rating: 1200,
      voteFinalized: false, winnerId: null,
      settings: {roundCount: 3}, createdAt: Timestamp.now(), completedAt: null,
    });
    const aPre = (await userDoc(A)).rating;
    r = await call(A, "claimBattleForfeit", {matchId: MATCH3});
    const m3 = (await db.collection("matches").doc(MATCH3).get()).data();
    const aPost = (await userDoc(A)).rating;
    check("warm-up departure -> no-contest (no winner, no rating move)",
        r.body?.settled === true && r.body?.winnerId === null &&
        m3.status === "abandoned" && m3.abandonedReason === "warmup-noncontest" &&
        aPost === aPre,
        `winner=${r.body?.winnerId} reason=${m3.abandonedReason} rating ${aPre}->${aPost}`);
    await db.collection("matches").doc(MATCH3).delete().catch(() => {});

    // markBattleStarted stamps once and is idempotent.
    const MATCH4 = `fftest4_${stamp}`;
    await db.collection("matches").doc(MATCH4).set({
      player1Id: A, player2Id: B, mode: "ranked", status: "pending",
      readyPlayerIds: [A, B], createdAt: Timestamp.now(),
    });
    await call(A, "markBattleStarted", {matchId: MATCH4});
    const firstStamp = (await db.collection("matches").doc(MATCH4).get()).data().battleStartedAt;
    await call(B, "markBattleStarted", {matchId: MATCH4});
    const secondStamp = (await db.collection("matches").doc(MATCH4).get()).data().battleStartedAt;
    check("markBattleStarted stamps once and is idempotent",
        typeof firstStamp === "number" && secondStamp === firstStamp,
        `first=${firstStamp} second=${secondStamp}`);
    await db.collection("matches").doc(MATCH4).delete().catch(() => {});
  } catch (e) {
    console.error("ERROR", e);
    failed++;
  } finally {
    await db.collection("matches").doc(MATCH).delete().catch(() => {});
    for (const uid of [A, B, C]) {
      await db.recursiveDelete(db.collection("users").doc(uid)).catch(() => {});
      await auth.deleteUser(uid).catch(() => {});
    }
  }
  console.log(`\nclaimBattleForfeit: ${passed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
})();
