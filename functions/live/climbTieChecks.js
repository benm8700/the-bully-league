/**
 * LIVE checks (deployed backend) for the gauntlet TIE rule + Elo on gauntlet
 * wins (2026-09-01). Pure engine rules are in test/climbTournament.test.js;
 * what only shows up here is the seam - the rating STAMP written at pairing,
 * finalizeMatch routing a TIE to applyClimbTie (both advance), and a WIN
 * actually moving hidden Elo.
 *
 * Two players: a tie advances BOTH and moves no rating; then a decisive win
 * advances one, eliminates the other, and moves Elo up/down.
 *
 * Run from functions/:  node live/climbTieChecks.js
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
initializeApp({credential: cert({
  projectId: val("FIREBASE_PROJECT_ID"),
  clientEmail: val("FIREBASE_CLIENT_EMAIL"),
  privateKey: val("FIREBASE_PRIVATE_KEY"),
})});
const db = getFirestore();
const auth = getAuth();
const PROJECT = "the-bully-league";
const API_KEY = "AIzaSyD-yeC1osuXpfwXWNZPnLEOq7yLviM7J0c";

let passed = 0; let failed = 0;
function check(name, cond, detail = "") {
  if (cond) { passed++; console.log(`  ok   ${name}`); } else {
    failed++; console.log(`  FAIL ${name}  ${detail}`);
  }
}

const stamp = Date.now().toString(36);
const A = `ct-a-${stamp}`;
const B = `ct-b-${stamp}`;
const TID = `climbtie-${stamp}`;
const tRef = db.collection("tournaments").doc(TID);
const madeMatches = new Set();

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
    headers: {"Content-Type": "application/json", Authorization: "Bearer " + tokens[uid]},
    body: JSON.stringify({data: data ?? {}}),
  });
  const j = await r.json().catch(() => ({}));
  return {status: r.status, body: j.result, raw: j};
}

async function makeUser(uid, admin) {
  await auth.createUser({uid, email: `${uid}@example.com`, password: "Test12345!"});
  await db.collection("users").doc(uid).set({
    username: uid, usernameLower: uid, rating: 1200, rankTitle: "Average Joe",
    rankedMatchesPlayed: 0, wins: 0, losses: 0, accountStatus: "active",
    isAdmin: admin, createdAt: Timestamp.now(),
    profile: {introVideoUrl: `https://example.com/${uid}.mp4`},
  });
}

const climbers = async () => ((await tRef.get()).data().climb || {}).climbers || [];
const find = (cs, uid) => cs.find((c) => c.uid === uid) || {};
const rating = async (uid) => (await db.collection("users").doc(uid).get()).data().rating;

/** Pair A and B via a real climbPoll, return the created matchId. */
async function pair() {
  await call(A, "climbPoll", {tournamentId: TID});
  await call(B, "climbPoll", {tournamentId: TID});
  const mid = find(await climbers(), A).currentMatchId;
  if (mid) madeMatches.add(mid);
  return mid;
}

/** Settle a match: mark completed, optionally seed ONE ballot (winner), then
 * finalize as admin. No ballot => a tie. */
async function settle(matchId, winnerUid) {
  await db.collection("matches").doc(matchId).set({
    status: "completed", completedAt: FieldValue.serverTimestamp(),
  }, {merge: true});
  if (winnerUid) {
    await db.collection("votes").doc(matchId).collection("ballots")
        .doc(`v-${stamp}`).set({votedForPlayerId: winnerUid, weight: 1,
          timestamp: FieldValue.serverTimestamp()});
  }
  return call(A, "debugFinalizeMatch", {matchId});
}

(async () => {
  try {
    console.log("\nsetup");
    await makeUser(A, true);
    await makeUser(B, false);
    const now = Date.now();
    await tRef.set({
      name: "Tie Probe", format: "climb", status: "in_progress",
      windowStartMs: now - 60000, windowEndMs: now + 3600 * 1000,
      createdAt: Timestamp.now(), climb: {climbers: []},
    });
    await call(A, "joinClimb", {tournamentId: TID});
    await call(B, "joinClimb", {tournamentId: TID});
    check("both joined at 0 wins",
        find(await climbers(), A).wins === 0 && find(await climbers(), B).wins === 0);

    console.log("\ntie");
    const m1 = await pair();
    check("paired into a real match", !!m1, JSON.stringify(await climbers()));
    const md = (await db.collection("matches").doc(m1).get()).data();
    check("match STAMPS both players' Elo (1200/1200)",
        md.player1Rating === 1200 && md.player2Rating === 1200,
        `p1=${md.player1Rating} p2=${md.player2Rating}`);
    const tie = await settle(m1); // no ballot -> tie
    check("a tie settles with NO winner",
        tie.status === 200 && (tie.body?.winnerId ?? null) === null,
        JSON.stringify(tie.raw).slice(0, 120));
    const afterTie = await climbers();
    check("TIE: both climbers advance to 1 win",
        find(afterTie, A).wins === 1 && find(afterTie, B).wins === 1,
        JSON.stringify(afterTie.map((c) => `${c.uid}:${c.wins}/${c.status}`)));
    check("TIE: neither is eliminated (both waiting)",
        find(afterTie, A).status === "waiting" && find(afterTie, B).status === "waiting");
    check("TIE: no Elo change (both still 1200)",
        (await rating(A)) === 1200 && (await rating(B)) === 1200,
        `a=${await rating(A)} b=${await rating(B)}`);

    console.log("\nwin");
    const m2 = await pair();
    check("re-paired at 1 win each", !!m2 && m2 !== m1);
    await settle(m2, A); // A wins
    const afterWin = await climbers();
    check("WIN: winner advances to 2 wins, waiting",
        find(afterWin, A).wins === 2 && find(afterWin, A).status === "waiting",
        JSON.stringify(afterWin.map((c) => `${c.uid}:${c.wins}/${c.status}`)));
    check("WIN: loser is eliminated",
        find(afterWin, B).status === "eliminated");
    const ra = await rating(A);
    const rb = await rating(B);
    check("WIN moves hidden Elo: winner UP, loser DOWN",
        ra > 1200 && rb < 1200, `winner=${ra} loser=${rb}`);
  } catch (e) {
    console.error("threw:", e.message);
    failed++;
  } finally {
    for (const id of madeMatches) {
      await db.collection("matches").doc(id).delete().catch(() => {});
      await db.recursiveDelete(db.collection("votes").doc(id)).catch(() => {});
    }
    await tRef.delete().catch(() => {});
    for (const uid of [A, B]) {
      await db.recursiveDelete(db.collection("users").doc(uid)).catch(() => {});
      await auth.deleteUser(uid).catch(() => {});
    }
    console.log("\nprobe data deleted");
  }
  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
})();
