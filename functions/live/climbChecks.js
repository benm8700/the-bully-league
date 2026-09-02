/**
 * LIVE checks for the nightly "climb" tournament, against the DEPLOYED
 * backend. The pure rules are covered by test/climbTournament.test.js; what
 * only works here is the seam - the deployed joinClimb/climbPoll callables,
 * the pairing transaction creating real matches, finalizeMatch routing a climb
 * result to applyClimbResult, sweepClimb running without throwing, and a
 * champion actually emerging.
 *
 * Drives four players up a ladder: a beats b and c beats d, then a beats c,
 * so a is champion. Winners are forced by seeding one ballot per match and
 * finalizing as admin.
 *
 * Run from functions/:  node live/climbChecks.js
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
const P = ["a", "b", "c", "d"].map((x) => `cl-${x}-${stamp}`);
const NOINTRO = `cl-ni-${stamp}`;
const TID = `climb-${stamp}`;
const tRef = db.collection("tournaments").doc(TID);
const createdMatches = new Set();

async function makeUser(uid, i, {intro = true, admin = false} = {}) {
  await auth.createUser({uid, email: `${uid}@example.com`, password: "Test12345!"});
  await db.collection("users").doc(uid).set({
    username: `Cl${i}${stamp}`, usernameLower: `cl${i}${stamp}`,
    rating: 1200, rankTitle: "Average Joe", rankedMatchesPlayed: 0,
    wins: 0, losses: 0, accountStatus: "active", isAdmin: admin,
    createdAt: Timestamp.now(),
    ...(intro ? {profile: {introVideoUrl: `https://example.com/${uid}.mp4`}} : {}),
  });
}

/** Force a climb match to a winner: mark it completed, seed one ballot, and
 * finalize as admin (which routes through applyClimbResult). */
async function settle(matchId, winnerUid) {
  createdMatches.add(matchId);
  await db.collection("matches").doc(matchId).set({
    status: "completed", completedAt: FieldValue.serverTimestamp(),
    readyPlayerIds: [],
  }, {merge: true});
  await db.collection("votes").doc(matchId).collection("ballots")
      .doc(`v-${stamp}`).set({votedForPlayerId: winnerUid, weight: 1,
        timestamp: FieldValue.serverTimestamp()});
  // P[0] is the admin driver.
  const r = await call(P[0], "debugFinalizeMatch", {matchId});
  return r;
}

async function climbers() {
  return ((await tRef.get()).data().climb || {}).climbers || [];
}
function find(cs, uid) {
  return cs.find((c) => c.uid === uid);
}

(async () => {
  try {
    console.log("\nsetup");
    for (const [i, uid] of P.entries()) await makeUser(uid, i, {admin: i === 0});
    await makeUser(NOINTRO, 9, {intro: false});
    const now = Date.now();
    await tRef.set({
      name: "Climb Probe", format: "climb", status: "in_progress",
      windowStartMs: now - 60000, windowEndMs: now + 3600 * 1000,
      prizeType: "points", createdAt: Timestamp.now(),
      climb: {climbers: []},
    });

    console.log("\njoin");
    for (const uid of P) {
      const r = await call(uid, "joinClimb", {tournamentId: TID});
      check(`${uid} joins at 0 wins`,
          r.status === 200 && r.body.joined === true &&
          r.body.standing.wins === 0, JSON.stringify(r.raw).slice(0, 140));
    }
    const ni = await call(NOINTRO, "joinClimb", {tournamentId: TID});
    check("an account with no intro video cannot join", ni.status !== 200,
        JSON.stringify(ni.raw).slice(0, 120));

    check("four climbers are recorded", (await climbers()).length === 4);

    console.log("\nround 1 pairing");
    // Poll all; each of the four ends up in one of two matches.
    const seen = new Set();
    for (const uid of P) {
      const r = await call(uid, "climbPoll", {tournamentId: TID});
      if (r.body && r.body.state === "in_match") seen.add(r.body.matchId);
    }
    check("polling pairs the four 0-win climbers into two matches",
        seen.size === 2, `matches=${[...seen]}`);

    // Identify the two matches and who is in them.
    const cs1 = await climbers();
    const inMatch = cs1.filter((c) => c.status === "in_match");
    check("all four are now in a match", inMatch.length === 4);
    const matchIds = [...new Set(cs1.map((c) => c.currentMatchId).filter(Boolean))];

    console.log("\nround 1 results");
    // For each match, the alphabetically-first present player wins (a over b,
    // c over d), so the winners are deterministic.
    for (const matchId of matchIds) {
      const m = (await db.collection("matches").doc(matchId).get()).data();
      const winner = [m.player1Id, m.player2Id].sort()[0];
      await settle(matchId, winner);
    }
    const cs2 = await climbers();
    const survivors = cs2.filter((c) => c.status !== "eliminated");
    check("two climbers survive round 1", survivors.length === 2,
        `survivors=${survivors.map((c) => c.uid)}`);
    check("survivors are at 1 win", survivors.every((c) => c.wins === 1));
    check("two climbers are eliminated",
        cs2.filter((c) => c.status === "eliminated").length === 2);

    console.log("\nround 2 (the final)");
    for (const c of survivors) {
      await call(c.uid, "climbPoll", {tournamentId: TID});
    }
    const cs3 = await climbers();
    const finalMatch = [...new Set(cs3.filter((c) => c.status === "in_match")
        .map((c) => c.currentMatchId))][0];
    check("the two survivors are paired in a final", Boolean(finalMatch),
        JSON.stringify(cs3.map((c) => [c.uid, c.wins, c.status])));
    const fm = (await db.collection("matches").doc(finalMatch).get()).data();
    const champ = [fm.player1Id, fm.player2Id].sort()[0];
    await settle(finalMatch, champ);

    console.log("\nchampion");
    // Push the window into the past so the sweep crowns the last survivor.
    await tRef.set({windowEndMs: Date.now() - 1000}, {merge: true});
    const {sweepClimb} = require("../climbPlay");
    const sweep = await sweepClimb();
    check("sweepClimb runs against real Firestore without throwing",
        sweep && Array.isArray(sweep.results), JSON.stringify(sweep).slice(0, 160));
    const t = (await tRef.get()).data();
    check("the tournament completes", t.status === "completed", t.status);
    check("the champion is the climber who won every round",
        t.winnerId === champ, `winner=${t.winnerId} expected=${champ}`);
    check("exactly one climber is left standing",
        (await climbers()).filter((c) => c.status !== "eliminated").length === 1);

    console.log(`\n${passed} passed, ${failed} failed`);
  } catch (e) {
    console.error("THREW:", e && e.message);
    failed++;
  } finally {
    // Clean up everything this made - a live check that leaves data behind
    // gets acted on by the real scheduled jobs.
    for (const matchId of createdMatches) {
      const ballots = await db.collection("votes").doc(matchId)
          .collection("ballots").get().catch(() => ({docs: []}));
      for (const b of ballots.docs) await b.ref.delete().catch(() => {});
      await db.collection("matches").doc(matchId).delete().catch(() => {});
    }
    await tRef.delete().catch(() => {});
    for (const uid of [...P, NOINTRO]) {
      await db.collection("users").doc(uid).delete().catch(() => {});
      await auth.deleteUser(uid).catch(() => {});
    }
    process.exit(failed === 0 ? 0 : 1);
  }
})();
