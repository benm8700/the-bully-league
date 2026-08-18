/**
 * LIVE check: does a live bracket actually ADVANCE like a live bracket?
 *
 * This is the failure that would be invisible until the night of the
 * event. Round one starts with a ten-minute window, everyone plays, and
 * then round two opens with the ASYNC format's twenty-four-hour window -
 * so the show simply stops after the first round with the audience still
 * sitting there. Nothing errors. The bracket is just waiting until
 * tomorrow.
 *
 * Run from functions/:  node live/liveAdvanceChecks.js
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

const stamp = Date.now().toString(36);
const P = ["a", "b", "c", "d"].map((x) => `la-${x}-${stamp}`);
const LIVE_T = `la-live-${stamp}`;
const ASYNC_T = `la-async-${stamp}`;
const HOUR = 60 * 60 * 1000;

async function makeUser(uid, i) {
  await auth.createUser({uid, email: `${uid}@example.com`,
    password: "Test12345!"});
  await db.collection("users").doc(uid).set({
    username: `La${i}${stamp}`, usernameLower: `la${i}${stamp}`,
    rating: 1200, rankTitle: "Average Joe", rankedMatchesPlayed: 0,
    wins: 0, losses: 0, accountStatus: "active", isAdmin: false,
    createdAt: Timestamp.now(),
  });
}

/** A running 4-player bracket, in whichever format. */
async function seedTournament(id, extra) {
  await db.collection("tournaments").doc(id).set({
    name: `Adv ${id}`, status: "in_progress", minEntrants: 4,
    prizeType: "points", createdAt: Timestamp.now(),
    bracket: {rounds: [{
      roundNumber: 1,
      windowStartMs: Date.now(),
      windowEndMs: Date.now() + 10 * 60 * 1000,
      matchups: [
        {player1Id: P[0], player2Id: P[1]},
        {player1Id: P[2], player2Id: P[3]},
      ],
    }]},
    ...extra,
  });
}

/** Settles one matchup through the real production path. */
async function settle(tournamentId, matchupIndex, winnerId) {
  const {recordTournamentResult} = require("../tournament");
  return recordTournamentResult(
      {tournament: {tournamentId, roundNumber: 1, matchupIndex}}, winnerId);
}

(async () => {
  try {
    for (const [i, uid] of P.entries()) await makeUser(uid, i);
    await seedTournament(LIVE_T, {format: "live"});
    await seedTournament(ASYNC_T, {format: "async"});

    console.log("\nlive bracket");
    let r = await settle(LIVE_T, 0, P[0]);
    check("the first result applies but does not advance the round",
        r.applied === true && r.advanced === false, JSON.stringify(r));

    r = await settle(LIVE_T, 1, P[2]);
    check("the second result advances the round",
        r.applied === true && r.advanced === true, JSON.stringify(r));

    const live = (await db.collection("tournaments").doc(LIVE_T).get()).data();
    const r2 = live.bracket.rounds[1];
    check("a round two exists with the two real winners",
        r2 && r2.matchups[0].player1Id === P[0] &&
        r2.matchups[0].player2Id === P[2], JSON.stringify(r2?.matchups));
    const liveLen = r2.windowEndMs - r2.windowStartMs;
    check("ROUND TWO OPENS WITH A LIVE WINDOW, not a day",
        liveLen <= HOUR,
        `${liveLen / 60000} minutes - a day here would end the show after ` +
        "round one with the audience still watching");

    console.log("\nasync bracket, which must be untouched");
    r = await settle(ASYNC_T, 0, P[0]);
    r = await settle(ASYNC_T, 1, P[2]);
    const async_ = (await db.collection("tournaments").doc(ASYNC_T).get()).data();
    const a2 = async_.bracket.rounds[1];
    const asyncLen = a2.windowEndMs - a2.windowStartMs;
    check("the async format still opens round two with its full window",
        asyncLen >= 12 * HOUR, `${asyncLen / HOUR} hours`);

    console.log("\ncompleting");
    const {recordTournamentResult} = require("../tournament");
    r = await recordTournamentResult(
        {tournament: {tournamentId: LIVE_T, roundNumber: 2, matchupIndex: 0}},
        P[0]);
    check("the final result completes the tournament",
        r.applied === true && r.completed === true, JSON.stringify(r));
    const done = (await db.collection("tournaments").doc(LIVE_T).get()).data();
    check("...with the right winner",
        done.status === "completed" && done.winnerId === P[0],
        JSON.stringify({s: done.status, w: done.winnerId}));
    check("and no phantom round was appended",
        done.bracket.rounds.length === 2,
        String(done.bracket.rounds.length));
  } finally {
    for (const id of [LIVE_T, ASYNC_T]) {
      await db.recursiveDelete(db.collection("tournaments").doc(id))
          .catch(() => {});
    }
    for (const uid of P) {
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
