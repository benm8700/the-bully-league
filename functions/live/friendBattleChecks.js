/**
 * LIVE checks for friend battles against the DEPLOYED backend.
 *
 * The pure rules are covered by test/friendBattle.test.js. What only
 * works here is everything involving two real accounts and real
 * documents: that a challenge actually reaches the right person, that
 * accepting produces ONE match both players can join, that a blocked
 * person is refused indistinguishably from a missing one, and - the part
 * that matters most - that a friend battle is judged but moves no rating
 * and pays no points, which is the constraint keeping this out of the
 * collusion business.
 *
 * Run from functions/:  node live/friendBattleChecks.js
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
const A = `fb-a-${stamp}`;
const B = `fb-b-${stamp}`;
const C = `fb-c-${stamp}`;
const NAMES = {[A]: `FbA${stamp}`, [B]: `FbB${stamp}`, [C]: `FbC${stamp}`};
const made = [];

async function makeUser(uid, extra = {}) {
  await auth.createUser({uid, email: `${uid}@example.com`, password: "Test12345!"});
  await db.collection("users").doc(uid).set({
    username: NAMES[uid], usernameLower: NAMES[uid].toLowerCase(),
    rating: 1200, rankTitle: "Average Joe", rankedMatchesPlayed: 0,
    wins: 0, losses: 0, points: 0, pointsBalance: 0,
    accountStatus: "active", isAdmin: false, createdAt: Timestamp.now(),
    ...extra,
  });
}

(async () => {
  try {
    for (const uid of [A, B, C]) await makeUser(uid);

    console.log("\nsending");
    let r = await call(A, "challengeFriend", {username: NAMES[B]});
    check("a challenge is sent by username",
        r.status === 200 && !!r.body.challengeId, JSON.stringify(r.raw).slice(0, 160));
    const challengeId = r.body?.challengeId;

    r = await call(A, "challengeFriend", {username: NAMES[B]});
    check("re-sending returns the SAME challenge rather than a duplicate",
        r.body?.challengeId === challengeId && r.body?.alreadySent === true,
        JSON.stringify(r.raw).slice(0, 160));

    r = await call(A, "challengeFriend", {username: NAMES[A]});
    check("self-challenge is refused", r.status !== 200,
        JSON.stringify(r.raw).slice(0, 120));

    r = await call(A, "challengeFriend", {username: "nobody-here-at-all"});
    check("an unknown username is refused", r.status !== 200);

    console.log("\nwho sees it");
    r = await call(B, "getMyChallenges");
    check("the target sees it incoming, named",
        r.body?.incoming?.length === 1 &&
        r.body.incoming[0].fromUsername === NAMES[A],
        JSON.stringify(r.body));
    r = await call(A, "getMyChallenges");
    check("the sender sees it outgoing, named",
        r.body?.outgoing?.length === 1 &&
        r.body.outgoing[0].toUsername === NAMES[B],
        JSON.stringify(r.body));
    r = await call(C, "getMyChallenges");
    check("an uninvolved player sees nothing",
        (r.body?.incoming?.length ?? 0) === 0 &&
        (r.body?.outgoing?.length ?? 0) === 0, JSON.stringify(r.body));

    r = await call(C, "respondToChallenge", {challengeId, accept: true});
    check("a third party cannot answer someone else's challenge",
        r.status !== 200, JSON.stringify(r.raw).slice(0, 120));

    console.log("\nblocking");
    await db.collection("users").doc(C).set(
        {blockedUserIds: [A]}, {merge: true});
    r = await call(A, "challengeFriend", {username: NAMES[C]});
    const blockedMsg = JSON.stringify(r.raw);
    check("someone who blocked me cannot be challenged", r.status !== 200);
    check("...and the refusal does not reveal the block",
        !/block/i.test(blockedMsg), blockedMsg.slice(0, 140));

    console.log("\naccepting");
    r = await call(B, "respondToChallenge", {challengeId, accept: true});
    check("the target accepts and gets a match",
        r.status === 200 && r.body.accepted === true && !!r.body.matchId,
        JSON.stringify(r.raw).slice(0, 160));
    const matchId = r.body?.matchId;

    const matchSnap = await db.collection("matches").doc(matchId).get();
    const match = matchSnap.data();
    check("the match is mode 'friend' with both players",
        match?.mode === "friend" && match.player1Id === A && match.player2Id === B,
        JSON.stringify({mode: match?.mode}));
    check("the challenger is player1, so Agora uids need no negotiation",
        match?.player1Id === A);
    check("it never counts toward the event-window bonus",
        match?.eventWindow?.qualified === false);

    r = await call(A, "getChallengeMatch", {matchId});
    check("the CHALLENGER can pick up the match they never started",
        r.status === 200 && r.body.opponentId === B && r.body.agoraUid === 1,
        JSON.stringify(r.raw).slice(0, 160));
    r = await call(B, "getChallengeMatch", {matchId});
    check("...and the acceptor gets the complementary uid",
        r.body?.agoraUid === 2 && r.body?.opponentId === A);
    r = await call(C, "getChallengeMatch", {matchId});
    check("an outsider cannot join it", r.status !== 200);

    r = await call(B, "respondToChallenge", {challengeId, accept: true});
    check("answering twice is refused rather than making a second match",
        r.status !== 200, JSON.stringify(r.raw).slice(0, 120));

    console.log("\nTHE CONSTRAINT: judged, but no rating and no points");
    // Settled through the REAL completeMatch callable, not by writing
    // status straight to Firestore.
    //
    // The shortcut was the reason this check missed a real bug: the
    // participation points are paid by completeMatch, so a test that
    // never calls it can only ever prove that FINALIZATION pays
    // nothing - which was true while friend battles were quietly
    // collecting a turn-up award on every match.
    r = await call(A, "completeMatch", {matchId});
    check("the match settles through the real callable",
        r.status === 200, JSON.stringify(r.raw).slice(0, 160));
    await db.collection("votes").doc(matchId).collection("ballots").doc(C).set({
      votedForPlayerId: A, weight: 1, timestamp: Timestamp.now(),
    });
    // Admin-gated force-finalize, bypassing the 24h window.
    await db.collection("users").doc(C).set({isAdmin: true}, {merge: true});
    r = await call(C, "debugFinalizeMatch", {matchId});
    check("it finalizes", r.status === 200, JSON.stringify(r.raw).slice(0, 160));

    const after = await db.collection("matches").doc(matchId).get();
    check("A WINNER IS RECORDED - the crowd's verdict is real",
        after.data().winnerId === A, JSON.stringify(after.data().winnerId));

    const [aDoc, bDoc] = await Promise.all([
      db.collection("users").doc(A).get(),
      db.collection("users").doc(B).get(),
    ]);
    check("NO RATING MOVED for the winner",
        aDoc.data().rating === 1200, String(aDoc.data().rating));
    check("nor for the loser", bDoc.data().rating === 1200,
        String(bDoc.data().rating));
    check("no win or loss was recorded",
        aDoc.data().wins === 0 && bDoc.data().losses === 0,
        JSON.stringify({w: aDoc.data().wins, l: bDoc.data().losses}));
    // The ledger reasons, not just the total. A failure reading {a:15}
    // says nothing about WHICH award paid, which is the only thing that
    // tells you where to look.
    const ledger = await db.collection("users").doc(A)
        .collection("pointsLedger").get();
    const reasons = ledger.docs.map((d) => `${d.id}=${d.data().amount}`);
    check("NO POINTS were paid - you pick your opponent, so this would farm",
        (aDoc.data().points ?? 0) === 0 && (bDoc.data().points ?? 0) === 0,
        JSON.stringify({a: aDoc.data().points, b: bDoc.data().points,
          ledger: reasons}));
    check("but it IS a recorded mode, so it can still be clipped",
        require("../matchmaking").RECORDED_MODES.includes("friend"));

    console.log("\ndeclining");
    r = await call(B, "challengeFriend", {username: NAMES[A]});
    const second = r.body?.challengeId;
    r = await call(A, "respondToChallenge", {challengeId: second, accept: false});
    check("a challenge can be declined", r.status === 200 &&
      r.body.accepted === false, JSON.stringify(r.raw).slice(0, 120));
    const declined = await db.collection("challenges").doc(second).get();
    check("declining creates NO match and no skip is spent",
        declined.data().status === "declined" && !declined.data().matchId);
    const aAfter = await db.collection("users").doc(A).get();
    check("...confirmed: the daily skip allowance is untouched",
        (aAfter.data().skipsUsedToday ?? 0) === 0);
  } finally {
    const chs = await db.collection("challenges").get();
    await Promise.all(chs.docs
        .filter((d) => [A, B].includes(d.data().fromUid))
        .map((d) => d.ref.delete()));

    const ms = await db.collection("matches")
        .where("mode", "==", "friend").get();
    for (const m of ms.docs) {
      if (![A, B].includes(m.data().player1Id)) continue;
      const ballots = await db.collection("votes").doc(m.id)
          .collection("ballots").get();
      await Promise.all(ballots.docs.map((d) => d.ref.delete()));
      await m.ref.delete();
    }
    for (const uid of [A, B, C]) {
      await db.collection("users").doc(uid).delete().catch(() => {});
      await auth.deleteUser(uid).catch(() => {});
    }
    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
  }
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
