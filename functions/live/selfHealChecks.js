/**
 * LIVE verification of the matchmaking pairing fixes (2026-11-01):
 *  1. ±1-tier pairing is INSTANT (two accounts one tier apart pair on the
 *     first poll, no 15s widen wait).
 *  2. SELF-HEAL: a player desynced back to a "waiting" queue entry while a
 *     live pending match exists with them as a participant is routed back
 *     into that match on their next poll (the deadlock seen twice on device).
 *
 * Run from functions/:  node live/selfHealChecks.js
 */
const fs = require("fs");
const {initializeApp, cert} = require("firebase-admin/app");
const {getFirestore, Timestamp} = require("firebase-admin/firestore");
const {getDatabase} = require("firebase-admin/database");
const {getAuth} = require("firebase-admin/auth");

const E = fs.readFileSync("../website/.env.local", "utf8");
function val(k) {
  const line = E.split(/\r?\n/).find((l) => l.startsWith(k + "="));
  let v = line.slice(k.length + 1).trim();
  if (v.startsWith('"') && v.endsWith('"')) v = v.slice(1, -1);
  return v.replace(/\\n/g, "\n");
}
const PROJECT = "the-bully-league";
const API_KEY = "AIzaSyD-yeC1osuXpfwXWNZPnLEOq7yLviM7J0c";

initializeApp({
  credential: cert({projectId: PROJECT, clientEmail: val("FIREBASE_CLIENT_EMAIL"), privateKey: val("FIREBASE_PRIVATE_KEY")}),
  databaseURL: "https://the-bully-league-default-rtdb.firebaseio.com",
});
const db = getFirestore();
const rtdb = getDatabase();

const tokens = {};
async function signIn(uid) {
  const custom = await getAuth().createCustomToken(uid);
  const r = await fetch("https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=" + API_KEY, {
    method: "POST", headers: {"Content-Type": "application/json"},
    body: JSON.stringify({token: custom, returnSecureToken: true}),
  });
  tokens[uid] = (await r.json()).idToken;
}
async function call(uid, name, data = {}) {
  const r = await fetch("https://us-central1-" + PROJECT + ".cloudfunctions.net/" + name, {
    method: "POST",
    headers: {"Content-Type": "application/json", "Authorization": "Bearer " + tokens[uid]},
    body: JSON.stringify({data}),
  });
  const t = await r.text();
  let body;
  try {
    body = JSON.parse(t);
  } catch {
    body = t.slice(0, 250);
  }
  return {status: r.status, body: body?.result ?? body, raw: body};
}
let pass = 0; let fail = 0;
const check = (n, ok, d = "") => {
  if (ok) {
    pass++; console.log("  ok   - " + n);
  } else {
    fail++; console.log("  FAIL - " + n + "  <- " + JSON.stringify(d));
  }
};

(async () => {
  const uids = [];
  const mkUser = async (name, rating) => {
    const u = await getAuth().createUser({
      email: name + "-" + Date.now() + "@example.com",
      password: "probe-" + Math.floor(Date.now() / 1000),
    });
    await db.collection("users").doc(u.uid).set({
      username: name, accountStatus: "active", rating,
      rankTitle: "Average Joe", rankedMatchesPlayed: 5, wins: 2, losses: 3,
      points: 0, pointsBalance: 0, isAdmin: false, createdAt: Timestamp.now(),
      profile: {introVideoUrl: "https://example.com/intro.mp4"},
      liveWatchOptIn: false,
    });
    uids.push(u.uid);
    await signIn(u.uid);
    return u.uid;
  };

  let matchId = null;
  try {
    // One tier apart, exactly like the real phones (1243 Door Guy / 1194 Funny Friend).
    const A = await mkUser("SelfHealA", 1243);
    const B = await mkUser("SelfHealB", 1194);

    await call(A, "enterMatchmakingQueue", {mode: "ranked"});
    await call(B, "enterMatchmakingQueue", {mode: "ranked"});

    // (1) INSTANT ±1-tier pairing: A's very first poll should pair with B.
    const pA = await call(A, "pollMatchmaking", {mode: "ranked"});
    check("A pairs with B on the FIRST poll (±1 tier, no widen wait)",
        pA.body?.status === "matched", pA.body);
    matchId = pA.body?.matchId;

    // B's poll should see the match too (its entry is matched).
    const pB = await call(B, "pollMatchmaking", {mode: "ranked"});
    check("B also sees the match (entry matched)", pB.body?.status === "matched" && pB.body?.matchId === matchId, pB.body);

    // Confirm the match is a real pending ranked match with both players.
    const m = (await db.collection("matches").doc(matchId).get()).data();
    check("match is pending ranked with both players",
        m && m.status === "pending" && m.mode === "ranked" &&
        [m.player1Id, m.player2Id].includes(A) && [m.player1Id, m.player2Id].includes(B), m?.status);

    // (2) Reproduce the DEADLOCK: desync B's queue entry back to "waiting"
    // (match stays pending). This is exactly the state seen on device.
    await rtdb.ref(`matchmakingQueue/ranked/${B}`).update({
      status: "waiting", matchId: null, channelName: null, opponentId: null,
    });
    const desynced = (await rtdb.ref(`matchmakingQueue/ranked/${B}`).get()).val();
    check("B is now desynced (waiting, no matchId) while match still pending",
        desynced.status === "waiting" && !desynced.matchId, desynced);

    // SELF-HEAL: B's next poll must route B back INTO the pending match.
    const heal = await call(B, "pollMatchmaking", {mode: "ranked"});
    check("SELF-HEAL: desynced B's poll returns matched for the SAME match",
        heal.body?.status === "matched" && heal.body?.matchId === matchId, heal.body);

    // And the entry is repaired to matched (so getActiveMatch / banner recover too).
    const repaired = (await rtdb.ref(`matchmakingQueue/ranked/${B}`).get()).val();
    check("B's queue entry repaired to matched", repaired.status === "matched" && repaired.matchId === matchId, repaired);

    const active = await call(B, "getActiveMatch", {});
    check("getActiveMatch now recovers B's match too", active.body?.found === true && active.body?.matchId === matchId, active.body);

    // A player NOT in any pending match keeps searching (no false self-heal).
    const C = await mkUser("SelfHealC", 1200);
    await call(C, "enterMatchmakingQueue", {mode: "ranked"});
    // Remove A/B from the queue so C has nobody at its tier for an instant pair...
    await rtdb.ref(`matchmakingQueue/ranked/${A}`).remove();
    await rtdb.ref(`matchmakingQueue/ranked/${B}`).remove();
    const cPoll = await call(C, "pollMatchmaking", {mode: "ranked"});
    check("a player with no pending match just searches (no false heal)",
        cPoll.body?.status === "searching" || cPoll.body?.status === "matched" ? cPoll.body?.status === "searching" : false, cPoll.body);
  } finally {
    // Cleanup
    try {
      for (const u of uids) {
        await rtdb.ref(`matchmakingQueue/ranked/${u}`).remove().catch(() => {});
        await db.collection("users").doc(u).delete().catch(() => {});
        await getAuth().deleteUser(u).catch(() => {});
      }
      if (matchId) await db.collection("matches").doc(matchId).delete().catch(() => {});
    } catch (e) {
      console.log("cleanup note:", e.message);
    }
    console.log(`\nself-heal: ${pass} passed, ${fail} failed`);
    process.exit(fail ? 1 : 0);
  }
})().catch((e) => {
  console.error("ERR", e);
  process.exit(1);
});
