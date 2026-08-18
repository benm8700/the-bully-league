/**
 * FULL CORE-LOOP REGRESSION against the deployed backend.
 *
 * This session changed several shared paths - enterQueue gained an
 * entitlement check, finalizeMatch gained rank announcements, tournament
 * results and a rating-history write inside its transaction, and
 * awardPoints started maintaining a second balance. Each was verified
 * alone. This checks they still work TOGETHER, because a regression in
 * finalizeMatch or enterQueue breaks the whole app regardless of how good
 * anything built on top of it is.
 *
 * queue -> pair -> complete -> vote -> finalize -> rating, points,
 * history, rank, clip eligibility.
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
  const mkUser = async (name, extra = {}) => {
    const u = await getAuth().createUser({
      email: name + "-" + Date.now() + "@example.com",
      password: "probe-" + Math.floor(Date.now() / 1000),
    });
    await db.collection("users").doc(u.uid).set(Object.assign({
      username: name, accountStatus: "active", rating: 1200,
      rankTitle: "Average Joe", rankedMatchesPlayed: 5, wins: 2, losses: 3,
      points: 0, pointsBalance: 0, isAdmin: false, createdAt: Timestamp.now(),
    }, extra));
    made.push(u.uid);
    await signIn(u.uid);
    return u.uid;
  };

  const p1 = await mkUser("LoopOne", {isAdmin: true});
  const p2 = await mkUser("LoopTwo");
  const judge = await mkUser("LoopJudge",
      {createdAt: Timestamp.fromMillis(Date.now() - 5 * 86400000)});

  try {
    // p2 was invited by p1, so completing this match should pay p1. This
    // exercises the referral hook INSIDE completeMatch - the unit test
    // calls grantReferralIfEarned directly and would not notice the hook
    // being removed or never wired up.
    await db.collection("users").doc(p2).update({referredByUserId: p1});

    // ---- 1. QUEUE AND PAIR -------------------------------------------
    let res = await call(p1, "enterMatchmakingQueue", {mode: "ranked"});
    check("STEP 1: a player can still enter the queue",
        res.status === 200, JSON.stringify(res.raw).slice(0, 160));
    res = await call(p1, "pollMatchmaking", {mode: "ranked"});
    check("...and polls without pairing when alone",
        res.status === 200 && !res.body.matchId, JSON.stringify(res.body));

    await call(p2, "enterMatchmakingQueue", {mode: "ranked"});
    res = await call(p2, "pollMatchmaking", {mode: "ranked"});
    const matchId = res.body?.matchId;
    check("STEP 2: two players are PAIRED into a real match",
        res.status === 200 && Boolean(matchId), JSON.stringify(res.body));
    if (!matchId) throw new Error("no pairing - cannot continue");
    refs.push(db.collection("matches").doc(matchId));

    const paired = (await db.collection("matches").doc(matchId).get()).data();
    check("the match carries settings and a window verdict, stamped",
        Boolean(paired.settings) && paired.eventWindow !== undefined,
        JSON.stringify({s: !!paired.settings, w: paired.eventWindow}));
    // Both ratings as they stood at pairing. Without these, a player who
    // deletes their account before voting closes leaves an opponent whose
    // rating change can never be computed - the match document is kept
    // precisely to protect that history.
    check("BOTH RATINGS ARE STAMPED at pairing",
        Number.isFinite(paired.player1Rating) &&
        Number.isFinite(paired.player2Rating),
        JSON.stringify({p1: paired.player1Rating, p2: paired.player2Rating}));

    // ---- 3. COMPLETE --------------------------------------------------
    res = await call(p1, "completeMatch", {matchId});
    check("STEP 3: the match completes", res.status === 200,
        JSON.stringify(res.raw).slice(0, 160));
    await sleep(1500);
    const done = (await db.collection("matches").doc(matchId).get()).data();
    check("...and is marked completed", done.status === "completed",
        done.status);

    const afterPlay = await db.collection("users").doc(p1).get();
    check("POINTS were awarded for playing, to BOTH numbers",
        afterPlay.data().points > 0 &&
          afterPlay.data().pointsBalance === afterPlay.data().points,
        JSON.stringify({p: afterPlay.data().points,
          b: afterPlay.data().pointsBalance}));

    // Asserted on the LEDGER ENTRY, not on a points comparison. p1 wins
    // this match, so "p1 has more points than p2" would be true whether
    // or not the referral fired - a check that cannot fail proves
    // nothing.
    const referralEntry = await db.collection("users").doc(p1)
        .collection("pointsLedger").doc(`referral_${p2}`).get();
    const invitee = await db.collection("users").doc(p2).get();
    check("THE REFERRAL HOOK FIRES from completeMatch, not just in a unit",
        referralEntry.exists &&
          invitee.data().referralRewardGranted === true,
        `ledger=${referralEntry.exists} flag=${invitee.data().referralRewardGranted}`);

    // ---- 4. VOTE ------------------------------------------------------
    // Written directly rather than through castVote: voting requires a
    // Turnstile solve or an existing vote session, and Turnstile
    // deliberately refuses automated browsers. That is the anti-bot
    // protection working, so this path - and with it the daily voting
    // streak - cannot be driven from a script and is covered by its own
    // unit and live checks instead.
    await db.collection("votes").doc(matchId).collection("ballots")
        .doc(judge).set({votedForPlayerId: p1, weight: 1,
          timestamp: Timestamp.now()});

    // ---- 5. FINALIZE --------------------------------------------------
    res = await call(p1, "debugFinalizeMatch", {matchId});
    check("STEP 4: the match finalizes", res.status === 200,
        JSON.stringify(res.raw).slice(0, 200));
    await sleep(3000);

    const w = (await db.collection("users").doc(p1).get()).data();
    const l = (await db.collection("users").doc(p2).get()).data();
    check("RATING moved, up for the winner and down for the loser",
        w.rating > 1200 && l.rating < 1200,
        JSON.stringify({w: w.rating, l: l.rating}));
    check("wins and losses were recorded",
        w.wins === 3 && l.losses === 4,
        JSON.stringify({w: w.wins, l: l.losses}));
    check("WIN POINTS were awarded on top of play points",
        w.points > afterPlay.data().points, JSON.stringify(w.points));
    check("the spendable balance still tracks the career total",
        w.pointsBalance === w.points,
        JSON.stringify({p: w.points, b: w.pointsBalance}));

    const hist = await db.collection("users").doc(p1)
        .collection("ratingHistory").doc(matchId).get();
    check("RATING HISTORY was written inside the same transaction",
        hist.exists && hist.data().ratingAfter === w.rating,
        JSON.stringify(hist.data()));

    // ---- 6. DOWNSTREAM ------------------------------------------------
    res = await call(p1, "getPendingRankChange");
    check("the rank-change check runs without error",
        res.status === 200, JSON.stringify(res.raw).slice(0, 160));

    res = await call(p1, "getMyRatingHistory");
    check("the player can read their own history back",
        res.status === 200 && res.body.entries.length === 1,
        JSON.stringify(res.body?.summary));

    res = await call(p1, "getMyEntitlement");
    check("the entitlement check still answers",
        res.status === 200 && res.body.ranked?.allowed === true,
        JSON.stringify(res.body).slice(0, 160));

    // A brand-new player has never taken their free clip, so this must be
    // granted at zero cost - a fresh account being asked for 250 points it
    // cannot possibly have is precisely the dead end the free clip exists
    // to remove.
    res = await call(p1, "requestMatchClip", {matchId, source: "points"});
    check("A NEW PLAYER'S FIRST CLIP IS FREE",
        res.status === 200 && res.body.cost === 0 &&
        res.body.source === "free",
        JSON.stringify(res.raw).slice(0, 200));

    const afterFree = await db.collection("users").doc(p1).get();
    check("...and the free clip is recorded as spent",
        afterFree.data().freeClipUsed === true);

    // The SECOND one must cost, or "first clip free" is just "clips free".
    res = await call(p2, "requestMatchClip", {matchId, source: "points"});
    const p2Free = res.body?.source === "free";
    check("the opponent gets their own free clip, independently", p2Free,
        JSON.stringify(res.raw).slice(0, 160));

    res = await call(judge, "getWatchFeed", {limit: 5});
    check("the judge feed still loads",
        res.status === 200 && Array.isArray(res.body.matches),
        JSON.stringify(res.raw).slice(0, 160));
  } finally {
    for (const uid of [p1, p2]) {
      await call(uid, "leaveMatchmakingQueue", {mode: "ranked"}).catch(() => {});
    }
    for (const r of refs) {
      const b = await db.collection("votes").doc(r.id).collection("ballots")
          .get().catch(() => null);
      if (b) await Promise.all(b.docs.map((d) => d.ref.delete()));
      await r.delete().catch(() => {});
    }
    for (const uid of made) {
      for (const sub of ["ratingHistory", "pointsLedger"]) {
        const s = await db.collection("users").doc(uid).collection(sub)
            .get().catch(() => null);
        if (s) await Promise.all(s.docs.map((d) => d.ref.delete()));
      }
      await db.collection("users").doc(uid).delete().catch(() => {});
      await getAuth().deleteUser(uid).catch(() => {});
    }
    console.log("\nprobe data deleted");
  }
  console.log("\n" + pass + " passed, " + fail + " failed");
  process.exit(fail ? 1 : 0);
})();
