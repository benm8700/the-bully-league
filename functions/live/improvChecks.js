/**
 * IMPROV STATION end-to-end live check against the deployed backend.
 *
 * Verifies the decided hybrid ranking shape and the mode plumbing:
 *   - queue `improv` with NO intro video (the gate is exempt for improv)
 *   - pair into a real recorded match that carries 3 shared prompts
 *   - completeMatch awards the SHARED career XP (it feeds the one ladder)
 *   - finalize moves the SEPARATE improvRating (up winner / down loser) and
 *     records improvWins/improvLosses
 *   - finalize leaves the ROAST ladder UNTOUCHED: rating, wins, losses,
 *     rankedMatchesPlayed, careerRankedMatches all unchanged, and NO roast
 *     ratingHistory entry is written (so the FormCard and the weekly Main
 *     Stage qualifier stay pure-roast - improv never grants qualification)
 *   - the win bonus XP is paid on top
 *
 * Creates throwaway accounts and deletes everything in a finally.
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
  // NOTE: deliberately NO profile.introVideoUrl - improv must be exempt from
  // the intro-video gate, and these accounts prove it by queueing without one.
  const mkUser = async (name, extra = {}) => {
    const u = await getAuth().createUser({
      email: name + "-" + Date.now() + "@example.com",
      password: "probe-" + Math.floor(Date.now() / 1000),
    });
    await db.collection("users").doc(u.uid).set(Object.assign({
      username: name, accountStatus: "active", rating: 1200,
      rankTitle: "Average Joe", rankedMatchesPlayed: 5, wins: 2, losses: 3,
      careerRankedMatches: 5, points: 0, pointsBalance: 0, isAdmin: false,
      createdAt: Timestamp.now(),
    }, extra));
    made.push(u.uid);
    await signIn(u.uid);
    return u.uid;
  };

  const p1 = await mkUser("ImprovOne", {isAdmin: true});
  const p2 = await mkUser("ImprovTwo");
  const judge = await mkUser("ImprovJudge",
      {createdAt: Timestamp.fromMillis(Date.now() - 5 * 86400000)});

  try {
    // ---- 1. QUEUE (no intro video) AND PAIR --------------------------
    let res = await call(p1, "enterMatchmakingQueue", {mode: "improv"});
    check("queue improv with NO intro video (gate exempt)",
        res.status === 200, JSON.stringify(res.raw).slice(0, 180));
    await call(p1, "pollMatchmaking", {mode: "improv"});
    await call(p2, "enterMatchmakingQueue", {mode: "improv"});
    res = await call(p2, "pollMatchmaking", {mode: "improv"});
    const matchId = res.body?.matchId;
    check("two players PAIR into a real improv match",
        res.status === 200 && Boolean(matchId), JSON.stringify(res.body));
    if (!matchId) throw new Error("no pairing - cannot continue");
    refs.push(db.collection("matches").doc(matchId));

    const m = (await db.collection("matches").doc(matchId).get()).data();
    check("match is mode improv and carries 3 shared prompts",
        m.mode === "improv" && Array.isArray(m.improvPrompts) &&
          m.improvPrompts.length === 3 &&
          m.improvPrompts.every((p) => typeof p === "string" && p.length > 0),
        JSON.stringify({mode: m.mode, prompts: m.improvPrompts}));

    // Snapshot the ROAST ladder fields BEFORE finalize so we can prove improv
    // leaves them untouched.
    const beforeP1 = (await db.collection("users").doc(p1).get()).data();
    const beforeP2 = (await db.collection("users").doc(p2).get()).data();

    // ---- 2. COMPLETE (shared XP) -------------------------------------
    res = await call(p1, "completeMatch", {matchId});
    check("completeMatch succeeds", res.status === 200,
        JSON.stringify(res.raw).slice(0, 160));
    await sleep(1500);
    const done = (await db.collection("matches").doc(matchId).get()).data();
    check("match marked completed", done.status === "completed", done.status);

    const afterPlay1 = (await db.collection("users").doc(p1).get()).data();
    check("participation XP awarded (improv feeds the SHARED career XP)",
        afterPlay1.points > 0 && afterPlay1.pointsBalance === afterPlay1.points,
        JSON.stringify({p: afterPlay1.points, b: afterPlay1.pointsBalance}));

    // ---- 3. VOTE (per-round) + FINALIZE ------------------------------
    await db.collection("votes").doc(matchId).collection("ballots")
        .doc(judge).set({picks: {"0": p1, "1": p1, "2": p1}, weight: 1,
          timestamp: Timestamp.now()});
    refs.push(db.collection("votes").doc(matchId));

    res = await call(p1, "debugFinalizeMatch", {matchId});
    check("improv match finalizes", res.status === 200,
        JSON.stringify(res.raw).slice(0, 200));
    await sleep(3000);

    const w = (await db.collection("users").doc(p1).get()).data();
    const l = (await db.collection("users").doc(p2).get()).data();

    check("improvRating moved: UP for winner, DOWN for loser",
        w.improvRating > 1200 && l.improvRating < 1200,
        JSON.stringify({w: w.improvRating, l: l.improvRating}));
    check("improv W-L recorded on its own counters",
        w.improvWins === 1 && l.improvLosses === 1,
        JSON.stringify({ww: w.improvWins, ll: l.improvLosses}));

    // The whole point of the separate ladder: ROAST is untouched.
    check("roast rating UNCHANGED by an improv match",
        w.rating === beforeP1.rating && l.rating === beforeP2.rating,
        JSON.stringify({w: w.rating, l: l.rating}));
    check("roast wins/losses UNCHANGED",
        w.wins === beforeP1.wins && l.losses === beforeP2.losses,
        JSON.stringify({ww: w.wins, ll: l.losses}));
    check("roast ladder counters UNCHANGED (GOAT-eligibility / carve-out safe)",
        w.rankedMatchesPlayed === beforeP1.rankedMatchesPlayed &&
          w.careerRankedMatches === beforeP1.careerRankedMatches,
        JSON.stringify({rmp: w.rankedMatchesPlayed, crm: w.careerRankedMatches}));

    const hist = await db.collection("users").doc(p1)
        .collection("ratingHistory").doc(matchId).get();
    check("NO roast ratingHistory entry (FormCard + Main Stage qualifier pure)",
        !hist.exists, `exists=${hist.exists}`);

    check("win bonus XP paid on top of the participation award",
        w.points > afterPlay1.points, JSON.stringify(w.points));
  } finally {
    for (const r of refs) await r.delete().catch(() => {});
    for (const uid of made) {
      await db.collection("users").doc(uid).delete().catch(() => {});
      await getAuth().deleteUser(uid).catch(() => {});
    }
    console.log("\nprobe data deleted");
  }

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch((e) => {console.error(e); process.exit(1);});
