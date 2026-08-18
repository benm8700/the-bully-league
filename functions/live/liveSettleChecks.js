/**
 * LIVE check: does a live tournament match actually get settled during the
 * event?
 *
 * THIS IS THE BUG THIS FILE EXISTS FOR. finalizeExpiredMatches queries
 * createdAt <= now - 24h, so a match played five minutes ago is invisible
 * to it for a day. Nothing else settled live matches - settleLiveMatch
 * existed but was only ever a client nudge, and the client was not calling
 * it. The consequence was not a slow result: no winner was ever recorded,
 * so recordTournamentResult never fired, so the bracket never advanced and
 * an event would stall after its first match with the audience watching.
 * Nothing would have logged an error.
 *
 * Run from functions/:  node live/liveSettleChecks.js
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
const P = ["a", "b", "c", "d"].map((x) => `ls-${x}-${stamp}`);
const JUDGE = `ls-j-${stamp}`;
const T = `ls-t-${stamp}`;

async function makeUser(uid, i) {
  await auth.createUser({uid, email: `${uid}@example.com`,
    password: "Test12345!"});
  await db.collection("users").doc(uid).set({
    username: `Ls${i}${stamp}`, usernameLower: `ls${i}${stamp}`,
    rating: 1200, rankTitle: "Average Joe", rankedMatchesPlayed: 0,
    wins: 0, losses: 0, accountStatus: "active", isAdmin: false,
    createdAt: Timestamp.now(),
  });
}

const matchId = (r, i) => `t_${T}_r${r}_m${i}`;

(async () => {
  try {
    for (const [i, uid] of P.entries()) await makeUser(uid, i);
    await makeUser(JUDGE, 9);

    // A running live bracket: two first-round matchups.
    await db.collection("tournaments").doc(T).set({
      name: `Settle Probe ${stamp}`, format: "live", status: "in_progress",
      minEntrants: 4, prizeType: "points", createdAt: Timestamp.now(),
      bracket: {rounds: [{
        roundNumber: 1,
        windowStartMs: Date.now(),
        windowEndMs: Date.now() + 30 * 60 * 1000,
        matchups: [
          {player1Id: P[0], player2Id: P[1]},
          {player1Id: P[2], player2Id: P[3]},
        ],
      }]},
    });

    // Both battles finished a moment ago, with a live-length vote window
    // that has already elapsed - exactly the state an event produces.
    for (const [i, pair] of [[P[0], P[1]], [P[2], P[3]]].entries()) {
      await db.collection("matches").doc(matchId(1, i)).set({
        player1Id: pair[0], player2Id: pair[1], mode: "tournament",
        status: "completed",
        channelName: `match_${matchId(1, i)}`,
        tournament: {tournamentId: T, roundNumber: 1, matchupIndex: i},
        // Completed two minutes ago with a 90-second window: closed.
        completedAt: Timestamp.fromMillis(Date.now() - 2 * 60 * 1000),
        voteWindowMs: 90 * 1000,
        createdAt: Timestamp.fromMillis(Date.now() - 5 * 60 * 1000),
        voteFinalized: false, winnerId: null, voteCount: 0,
      });
      await db.collection("votes").doc(matchId(1, i)).collection("ballots")
          .doc(JUDGE).set({
            votedForPlayerId: pair[0], weight: 1, timestamp: Timestamp.now(),
          });
    }

    console.log("\nthe bug, demonstrated");
    // The hourly sweep selects on createdAt <= now - 24h. A match played
    // minutes ago is simply outside that range, which is the whole reason
    // nothing settled these before the fix. Asserted on the arithmetic
    // rather than by issuing the query, so this does not depend on an
    // index that is incidental to the point being made.
    const {VOTE_WINDOW_MS} = require("../matchFinalization");
    const cutoffMs = Date.now() - VOTE_WINDOW_MS;
    const created = (await db.collection("matches").doc(matchId(1, 0)).get())
        .data().createdAt.toMillis();
    check("THE HOURLY SWEEP CANNOT SEE A MATCH PLAYED MINUTES AGO",
        created > cutoffMs,
        "createdAt is newer than the 24h cutoff, so the sweep's query " +
        "excludes it - which is why nothing settled these before the fix");

    // And the query it runs needed an index that was never declared, so
    // it threw on every run and was swallowed by its own try/catch. Kept
    // as a check because a missing index is invisible until something
    // asks.
    let indexed = true;
    try {
      await db.collection("matches")
          .where("createdAt", "<=", new Date(cutoffMs))
          .where("voteFinalized", "==", false).limit(1).get();
    } catch (e) {
      indexed = false;
      console.log("      (hourly sweep query still unusable:",
          e.message.slice(0, 60) + "...)");
    }
    check("the hourly sweep's own query is usable at all", indexed,
        "it needs a composite index on voteFinalized + createdAt");

    console.log("\nthe fix");
    const {sweepLiveTournaments} = require("../liveTournament");
    const result = await sweepLiveTournaments();
    check("the per-minute sweep settles them",
        (result.settled ?? []).length === 2,
        JSON.stringify(result.settled ?? []).slice(0, 200));

    const m0 = (await db.collection("matches").doc(matchId(1, 0)).get()).data();
    const m1 = (await db.collection("matches").doc(matchId(1, 1)).get()).data();
    check("both matches now have a winner",
        m0.winnerId === P[0] && m1.winnerId === P[2],
        JSON.stringify({a: m0.winnerId, b: m1.winnerId}));
    check("...and are marked finalized",
        m0.voteFinalized === true && m1.voteFinalized === true);

    console.log("\nand the bracket actually moves");
    const t = (await db.collection("tournaments").doc(T).get()).data();
    const rounds = t.bracket?.rounds ?? [];
    check("A SECOND ROUND EXISTS - the event did not stall",
        rounds.length === 2, `${rounds.length} round(s)`);
    check("...pairing the two real winners",
        rounds[1]?.matchups?.[0]?.player1Id === P[0] &&
        rounds[1]?.matchups?.[0]?.player2Id === P[2],
        JSON.stringify(rounds[1]?.matchups));
    const len = rounds[1] ?
      rounds[1].windowEndMs - rounds[1].windowStartMs : 0;
    check("...with a live-length window", len > 0 && len <= 60 * 60 * 1000,
        `${len / 60000} minutes`);

    console.log("\nidempotence");
    const again = await sweepLiveTournaments();
    check("a second sweep settles nothing again",
        (again.settled ?? []).length === 0,
        JSON.stringify(again.settled ?? []));
  } catch (err) {
    console.error('THREW:', err.message);
    failed++;
  } finally {
    await db.recursiveDelete(db.collection("tournaments").doc(T))
        .catch(() => {});
    for (let r = 1; r <= 2; r++) {
      for (let i = 0; i < 2; i++) {
        const id = matchId(r, i);
        const b = await db.collection("votes").doc(id)
            .collection("ballots").get();
        await Promise.all(b.docs.map((d) => d.ref.delete()));
        await db.collection("matches").doc(id).delete().catch(() => {});
      }
    }
    for (const uid of [...P, JUDGE]) {
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
