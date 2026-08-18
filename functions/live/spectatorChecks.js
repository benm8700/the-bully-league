/**
 * LIVE checks for spectating, against the DEPLOYED backend.
 *
 * The rule is covered by test/spectator.test.js. What matters here is that
 * the DEPLOYED function refuses the same things - because this is a second
 * door into a video channel, and generateAgoraToken's rule that you cannot
 * get a token for a stranger's match is one of the few genuine security
 * boundaries in this app. A spectator endpoint one condition too wide
 * quietly reopens it.
 *
 * Run from functions/:  node live/spectatorChecks.js
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
const P1 = `sp-p1-${stamp}`;
const P2 = `sp-p2-${stamp}`;
const FAN = `sp-fan-${stamp}`;
const T = `sp-t-${stamp}`;
const LIVE_MATCH = `t_${T}_r1_m0`;
const RANKED_MATCH = `sp-ranked-${stamp}`;

async function makeUser(uid) {
  await auth.createUser({uid, email: `${uid}@example.com`,
    password: "Test12345!"});
  await db.collection("users").doc(uid).set({
    username: `Sp${uid.slice(-6)}`, usernameLower: `sp${uid.slice(-6)}`,
    rating: 1200, rankTitle: "Average Joe", rankedMatchesPlayed: 0,
    wins: 0, losses: 0, accountStatus: "active", isAdmin: false,
    createdAt: Timestamp.now(),
  });
}

(async () => {
  try {
    for (const uid of [P1, P2, FAN]) await makeUser(uid);

    await db.collection("tournaments").doc(T).set({
      name: `Spectate Probe ${stamp}`, format: "live", status: "in_progress",
      minEntrants: 2, prizeType: "points", createdAt: Timestamp.now(),
      bracket: {rounds: [{
        roundNumber: 1,
        windowStartMs: Date.now(),
        windowEndMs: Date.now() + 10 * 60 * 1000,
        matchups: [{player1Id: P1, player2Id: P2}],
      }]},
    });
    await db.collection("matches").doc(LIVE_MATCH).set({
      player1Id: P1, player2Id: P2, mode: "tournament", status: "pending",
      channelName: `match_${LIVE_MATCH}`,
      tournament: {tournamentId: T, roundNumber: 1, matchupIndex: 0},
      arrivedAt: {[P1]: Date.now(), [P2]: Date.now()},
      createdAt: Timestamp.now(), voteFinalized: false, voteCount: 0,
    });
    // An ordinary ranked match between the same two people - the thing
    // spectating must NEVER open up.
    await db.collection("matches").doc(RANKED_MATCH).set({
      player1Id: P1, player2Id: P2, mode: "ranked", status: "pending",
      channelName: `match_${RANKED_MATCH}`,
      createdAt: Timestamp.now(), voteFinalized: false, voteCount: 0,
    });

    console.log("\nwatching a live tournament match");
    let r = await call(FAN, "watchLiveMatch", {matchId: LIVE_MATCH});
    check("a spectator gets a token", r.status === 200 && !!r.body?.token,
        JSON.stringify(r.raw).slice(0, 180));
    check("...for the match's real channel",
        r.body?.channelName === `match_${LIVE_MATCH}`,
        String(r.body?.channelName));
    check("...on a uid clear of the players' 1 and 2",
        Number(r.body?.agoraUid) > 2, String(r.body?.agoraUid));

    const again = await call(FAN, "watchLiveMatch", {matchId: LIVE_MATCH});
    // Requires a REAL uid on both sides, or undefined === undefined passes
    // this whenever the call is failing - which is exactly how it read on
    // the first run against an unbound Cloud Run service.
    check("rejoining reuses the same uid rather than adding a ghost",
        Number(again.body?.agoraUid) > 2 &&
        again.body?.agoraUid === r.body?.agoraUid,
        "Agora bills per participant-minute");

    console.log("\nTHE BOUNDARY: what spectating must NOT open");
    r = await call(FAN, "watchLiveMatch", {matchId: RANKED_MATCH});
    check("AN ORDINARY RANKED MATCH IS STILL PRIVATE", r.status !== 200,
        JSON.stringify(r.raw).slice(0, 160));

    r = await call(P1, "watchLiveMatch", {matchId: LIVE_MATCH});
    check("a player is sent to the player path, not handed a subscriber token",
        r.status !== 200, JSON.stringify(r.raw).slice(0, 140));

    await db.collection("tournaments").doc(T).update({format: "async"});
    r = await call(FAN, "watchLiveMatch", {matchId: LIVE_MATCH});
    check("an async tournament's match is not spectatable", r.status !== 200,
        JSON.stringify(r.raw).slice(0, 140));
    await db.collection("tournaments").doc(T).update({format: "live"});

    await db.collection("tournaments").doc(T).update({status: "open"});
    r = await call(FAN, "watchLiveMatch", {matchId: LIVE_MATCH});
    check("a tournament that is not running yet is not watchable",
        r.status !== 200, JSON.stringify(r.raw).slice(0, 140));
    await db.collection("tournaments").doc(T).update({status: "in_progress"});

    await db.collection("matches").doc(LIVE_MATCH)
        .update({status: "completed"});
    r = await call(FAN, "watchLiveMatch", {matchId: LIVE_MATCH});
    check("a finished battle is not watchable live", r.status !== 200,
        JSON.stringify(r.raw).slice(0, 140));
    await db.collection("matches").doc(LIVE_MATCH).update({status: "pending"});

    console.log("\nwhat is on right now");
    r = await call(FAN, "liveMatchesFor", {tournamentId: T});
    check("the current round's live matches are listed",
        r.status === 200 && r.body?.matches?.length === 1 &&
        r.body.matches[0].matchId === LIVE_MATCH,
        JSON.stringify(r.body).slice(0, 180));
    check("...and marked live once both players have arrived",
        r.body?.matches?.[0]?.live === true);

    await db.collection("tournaments").doc(T).update({status: "completed"});
    r = await call(FAN, "liveMatchesFor", {tournamentId: T});
    check("a finished tournament lists nothing",
        r.status === 200 && r.body?.matches?.length === 0,
        JSON.stringify(r.body));
  } finally {
    await db.recursiveDelete(db.collection("tournaments").doc(T))
        .catch(() => {});
    for (const id of [LIVE_MATCH, RANKED_MATCH]) {
      await db.collection("matches").doc(id).delete().catch(() => {});
    }
    for (const uid of [P1, P2, FAN]) {
      await db.recursiveDelete(db.collection("users").doc(uid)).catch(() => {});
      await auth.deleteUser(uid).catch(() => {});
    }
    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
  }
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
