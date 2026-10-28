/**
 * LIVE-WATCH OPT-IN, end to end against the deployed backend.
 *
 * Everyday (ranked) matches are spectatable ONLY when both players opt in -
 * the consent rule that keeps two random strangers from being exposed to a
 * live audience they didn't sign up for (the Omegle exposure risk). This
 * proves the whole server path that the client can't prove on its own:
 *
 *   1. a ranked pairing where BOTH opted in is stamped liveWatchable = true
 *   2. a pairing where only ONE opted in is NOT stamped
 *   3. getLiveWatchableMatches lists the opted-in match, not the control,
 *      and never the caller's own match
 *   4. watchLiveMatch mints a spectator token for a third viewer
 *   5. a participant is refused (you-are-playing)
 *   6. the not-opted-in match is refused (not-a-tournament-match)
 *
 * The video pixels reuse the already-device-proven tournament spectator path;
 * this is the gate + listing + authorization, which is the risky logic.
 */
const fs = require("fs");
const {initializeApp, cert} = require("firebase-admin/app");
const {getFirestore, Timestamp} = require("firebase-admin/firestore");
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

initializeApp({credential: cert({
  projectId: PROJECT,
  clientEmail: val("FIREBASE_CLIENT_EMAIL"),
  privateKey: val("FIREBASE_PRIVATE_KEY"),
})});
const db = getFirestore();

const tokens = {};
async function signIn(uid) {
  const custom = await getAuth().createCustomToken(uid);
  const r = await fetch("https://identitytoolkit.googleapis.com/v1/accounts:" +
    "signInWithCustomToken?key=" + API_KEY, {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({token: custom, returnSecureToken: true}),
  });
  tokens[uid] = (await r.json()).idToken;
}
async function call(uid, name, data = {}) {
  const r = await fetch(
      "https://us-central1-" + PROJECT + ".cloudfunctions.net/" + name, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": "Bearer " + tokens[uid],
        },
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
    fail++; console.log("  FAIL - " + n + "  <- " + d);
  }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  const made = []; const refs = [];
  const mkUser = async (name, optedIn) => {
    const u = await getAuth().createUser({
      email: name + "-" + Date.now() + "@example.com",
      password: "probe-" + Math.floor(Date.now() / 1000),
    });
    await db.collection("users").doc(u.uid).set({
      username: name, accountStatus: "active", rating: 1200,
      rankTitle: "Average Joe", rankedMatchesPlayed: 5, wins: 2, losses: 3,
      points: 0, pointsBalance: 0, isAdmin: false, createdAt: Timestamp.now(),
      liveWatchOptIn: optedIn,
      profile: {introVideoUrl: "https://example.com/probe-intro.mp4"},
    });
    made.push(u.uid);
    await signIn(u.uid);
    return u.uid;
  };

  // Pair two accounts in ranked in isolation and return the matchId. Entering
  // sequentially (and asserting the pair) means the control pair can't steal
  // an opted-in player: a paired entry has already left the queue.
  const pairRanked = async (a, b) => {
    await call(a, "enterMatchmakingQueue", {mode: "ranked"});
    await call(a, "pollMatchmaking", {mode: "ranked"});
    await call(b, "enterMatchmakingQueue", {mode: "ranked"});
    const res = await call(b, "pollMatchmaking", {mode: "ranked"});
    const matchId = res.body?.matchId;
    if (matchId) refs.push(db.collection("matches").doc(matchId));
    return matchId;
  };

  const inA = await mkUser("WatchInA", true);
  const inB = await mkUser("WatchInB", true);
  const halfD = await mkUser("WatchHalfD", true);
  const halfE = await mkUser("WatchHalfE", false);
  const viewer = await mkUser("WatchViewer", false);

  try {
    // ---- both opted in -> liveWatchable -----------------------------
    const liveMatch = await pairRanked(inA, inB);
    check("STEP 1: two opted-in players pair into a real match",
        Boolean(liveMatch), "no pairing");
    if (!liveMatch) throw new Error("no pairing - cannot continue");
    await sleep(500);
    const live = (await db.collection("matches").doc(liveMatch).get()).data();
    check("...and the match is STAMPED liveWatchable = true",
        live.liveWatchable === true, JSON.stringify(live.liveWatchable));
    check("...and it is still pending (watchable while it plays)",
        live.status === "pending", live.status);

    // ---- only one opted in -> NOT liveWatchable ---------------------
    const controlMatch = await pairRanked(halfD, halfE);
    check("STEP 2: a half-opted-in pair also pairs",
        Boolean(controlMatch), "no pairing");
    await sleep(500);
    const control =
      (await db.collection("matches").doc(controlMatch).get()).data();
    check("...but is NOT stamped liveWatchable (one player opted out)",
        control.liveWatchable !== true, JSON.stringify(control.liveWatchable));

    // ---- the viewer's "Live now" list -------------------------------
    let res = await call(viewer, "getLiveWatchableMatches", {});
    const ids = (res.body?.matches || []).map((m) => m.matchId);
    check("STEP 3: the live-now list returns the opted-in match",
        res.status === 200 && ids.includes(liveMatch),
        JSON.stringify(res.body).slice(0, 200));
    check("...and does NOT include the half-opted-in match",
        !ids.includes(controlMatch), JSON.stringify(ids));
    const named = (res.body?.matches || []).find((m) => m.matchId === liveMatch);
    check("...and carries both player names, not raw uids",
        Boolean(named && named.player1Name && named.player2Name),
        JSON.stringify(named));

    // a participant is playing, not spectating - never sees their own match
    res = await call(inA, "getLiveWatchableMatches", {});
    const ownIds = (res.body?.matches || []).map((m) => m.matchId);
    check("STEP 4: a participant's own live match is excluded from their list",
        !ownIds.includes(liveMatch), JSON.stringify(ownIds));

    // ---- spectating is authorized / refused correctly ---------------
    res = await call(viewer, "watchLiveMatch", {matchId: liveMatch});
    check("STEP 5: a third viewer is minted a spectator token",
        res.status === 200 && Boolean(res.body?.token) &&
          Boolean(res.body?.channelName),
        JSON.stringify(res.raw).slice(0, 200));

    res = await call(inA, "watchLiveMatch", {matchId: liveMatch});
    check("STEP 6: a participant is refused (can't watch their own battle)",
        res.status !== 200 &&
          JSON.stringify(res.raw).includes("you-are-playing"),
        JSON.stringify(res.raw).slice(0, 200));

    res = await call(viewer, "watchLiveMatch", {matchId: controlMatch});
    check("STEP 7: the half-opted-in match refuses spectators",
        res.status !== 200 &&
          JSON.stringify(res.raw).includes("not-a-tournament-match"),
        JSON.stringify(res.raw).slice(0, 200));
  } finally {
    for (const uid of [inA, inB, halfD, halfE]) {
      await call(uid, "leaveMatchmakingQueue", {mode: "ranked"}).catch(() => {});
    }
    for (const r of refs) {
      await r.delete().catch(() => {});
    }
    for (const uid of made) {
      await db.collection("users").doc(uid).delete().catch(() => {});
      await getAuth().deleteUser(uid).catch(() => {});
    }
    console.log("\nprobe data deleted");
  }
  console.log("\n" + pass + " passed, " + fail + " failed");
  process.exit(fail ? 1 : 0);
})();
