/**
 * LIVE checks for live tournaments, against the DEPLOYED backend.
 *
 * The scheduling rules are covered by test/liveTournament.test.js. What
 * only works here is the thing that actually matters: that a scheduled
 * tournament really starts, that the bracket really is built from who
 * checked in rather than who entered, and that too few arrivals really
 * cancels rather than running a show for two people.
 *
 * Run from functions/:  node live/liveTournamentChecks.js
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
const PLAYERS = ["a", "b", "c", "d", "e"].map((x) => `lt-${x}-${stamp}`);
const TOURNEY = `lt-${stamp}`;
const CANCELLED = `ltc-${stamp}`;

async function makeUser(uid, i) {
  await auth.createUser({uid, email: `${uid}@example.com`,
    password: "Test12345!"});
  await db.collection("users").doc(uid).set({
    username: `Lt${i}${stamp}`, usernameLower: `lt${i}${stamp}`,
    rating: 1200, rankTitle: "Average Joe", rankedMatchesPlayed: 0,
    wins: 0, losses: 0, accountStatus: "active", isAdmin: false,
    createdAt: Timestamp.now(),
  });
}

(async () => {
  try {
    for (const [i, uid] of PLAYERS.entries()) await makeUser(uid, i);

    // Starts in a few minutes, so check-in is open but the sweep will not
    // start it until we move the clock forward.
    const soon = Date.now() + 5 * 60 * 1000;
    await db.collection("tournaments").doc(TOURNEY).set({
      name: `Live Probe ${stamp}`, format: "live", status: "open",
      minEntrants: 4, startsAtMs: soon, prizeType: "points",
      createdAt: Timestamp.now(),
    });
    for (const uid of PLAYERS) {
      await db.collection("tournaments").doc(TOURNEY)
          .collection("entrants").doc(uid).set({joinedAt: Timestamp.now()});
    }

    console.log("\ncheck-in");
    let r = await call(PLAYERS[0], "checkInToTournament",
        {tournamentId: TOURNEY});
    check("an entrant can check in once the window is open",
        r.status === 200 && r.body.checkedIn === true,
        JSON.stringify(r.raw).slice(0, 160));

    const outsider = `lt-out-${stamp}`;
    await makeUser(outsider, 9);
    r = await call(outsider, "checkInToTournament", {tournamentId: TOURNEY});
    check("someone who never entered cannot check in", r.status !== 200,
        JSON.stringify(r.raw).slice(0, 120));

    // Four of the five arrive. The fifth is the one the bracket must
    // leave out.
    for (const uid of PLAYERS.slice(1, 4)) {
      await call(uid, "checkInToTournament", {tournamentId: TOURNEY});
    }
    const entrants = await db.collection("tournaments").doc(TOURNEY)
        .collection("entrants").get();
    const arrived = entrants.docs.filter((d) => d.data().checkedInAtMs > 0);
    check("four of five entrants are recorded as present",
        entrants.size === 5 && arrived.length === 4,
        `${arrived.length}/${entrants.size}`);

    console.log("\nstarting");
    const {startLiveTournament} = require("../liveTournament");
    let out = await startLiveTournament(TOURNEY);
    check("before the start time the sweep waits", out.action === "wait",
        JSON.stringify(out));

    // Move the start into the past, exactly as the clock would.
    await db.collection("tournaments").doc(TOURNEY)
        .update({startsAtMs: Date.now() - 1000});
    out = await startLiveTournament(TOURNEY);
    check("at the start time it starts", out.action === "start",
        JSON.stringify(out));

    const started = (await db.collection("tournaments").doc(TOURNEY).get()).data();
    check("the tournament is now running", started.status === "in_progress");
    const round1 = started.bracket?.rounds?.[0];
    const named = (round1?.matchups ?? [])
        .flatMap((m) => [m.player1Id, m.player2Id]).filter(Boolean);
    check("THE BRACKET CONTAINS ONLY PEOPLE WHO CHECKED IN",
        named.length === 4 && !named.includes(PLAYERS[4]),
        JSON.stringify(named));
    // Asserts on a NON-EMPTY bracket, or it passes vacuously whenever the
    // start failed - which is exactly how it read on the first run.
    check("...and the absentee is simply not in it",
        named.length > 0 && !named.includes(PLAYERS[4]),
        "a bracket of byes is not a show");
    check("the round has a window measured in minutes, not hours",
        round1.windowEndMs - round1.windowStartMs <= 60 * 60 * 1000,
        String((round1.windowEndMs - round1.windowStartMs) / 60000) + " min");

    out = await startLiveTournament(TOURNEY);
    check("starting twice is a no-op", out.action === "skip",
        JSON.stringify(out));

    console.log("\ngolden parachute");
    await db.collection("tournaments").doc(CANCELLED).set({
      name: `Live Empty ${stamp}`, format: "live", status: "open",
      minEntrants: 4, startsAtMs: Date.now() - 1000, prizeType: "points",
      createdAt: Timestamp.now(),
    });
    for (const uid of PLAYERS.slice(0, 2)) {
      await db.collection("tournaments").doc(CANCELLED)
          .collection("entrants").doc(uid).set({
            joinedAt: Timestamp.now(), checkedInAtMs: Date.now(),
          });
    }
    out = await startLiveTournament(CANCELLED);
    check("too few arrivals cancels rather than running a two-man show",
        out.action === "cancel", JSON.stringify(out));
    const dead = (await db.collection("tournaments").doc(CANCELLED).get()).data();
    check("...and the tournament is marked cancelled",
        dead.status === "cancelled" &&
        dead.cancelledReason === "too-few-checked-in");

    console.log("\nthe sweep itself");
    const {sweepLiveTournaments} = require("../liveTournament");
    const swept = await sweepLiveTournaments();
    check("the sweep runs without error and reports what it examined",
        typeof swept.examined === "number", JSON.stringify(swept));

    console.log("\nsettling a live match early is refused");
    r = await call(PLAYERS[0], "settleLiveMatch", {matchId: "nope-" + stamp});
    check("an unknown match is refused", r.status !== 200);
  } finally {
    for (const id of [TOURNEY, CANCELLED]) {
      await db.recursiveDelete(db.collection("tournaments").doc(id))
          .catch(() => {});
    }
    for (const uid of [...PLAYERS, `lt-out-${stamp}`]) {
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
