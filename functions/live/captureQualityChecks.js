/**
 * LIVE checks for capture-quality persistence, against the DEPLOYED
 * backend.
 *
 * The check that actually matters is that BOTH players' reports land.
 * Only one device wins the settle claim, so the natural place to write
 * the report - inside that transaction - would silently keep whichever
 * player raced faster and discard the other, who is often the one who
 * actually had the problem. That failure looks completely normal from
 * the outside: the match settles, a report exists, and half the evidence
 * is simply missing.
 *
 * Run from functions/:  node live/captureQualityChecks.js
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
const P1 = `cq1-${stamp}`;
const P2 = `cq2-${stamp}`;
const OUT = `cqx-${stamp}`;
const matchIds = [];

async function makeUser(uid) {
  await auth.createUser({uid, email: `${uid}@example.com`,
    password: "Test12345!"});
  await db.collection("users").doc(uid).set({
    username: `Cq${uid.slice(-6)}`, usernameLower: `cq${uid.slice(-6)}`,
    rating: 1200, rankTitle: "Average Joe", rankedMatchesPlayed: 0,
    wins: 0, losses: 0, accountStatus: "active", isAdmin: false,
    createdAt: Timestamp.now(),
  });
}

/** A pending match between the two probe accounts. */
async function makeMatch() {
  const ref = db.collection("matches").doc();
  matchIds.push(ref.id);
  await ref.set({
    player1Id: P1, player2Id: P2, mode: "ranked", status: "pending",
    channelName: `match_${ref.id}`, createdAt: Timestamp.now(),
    voteCount: 0,
  });
  return ref;
}

(async () => {
  try {
    await Promise.all([makeUser(P1), makeUser(P2), makeUser(OUT)]);

    console.log("\nboth players' reports survive the settle race");
    let ref = await makeMatch();
    // P1 wins the claim, P2 arrives second and is told alreadySettled.
    const first = await call(P1, "completeMatch", {matchId: ref.id,
      quality: {darkEpisodes: 2, quietEpisodes: 0}});
    const second = await call(P2, "completeMatch", {matchId: ref.id,
      quality: {darkEpisodes: 0, quietEpisodes: 3}});
    check("the second caller is told it was already settled",
        second.body?.alreadySettled === true,
        JSON.stringify(second.raw).slice(0, 160));
    check("the match settled normally", first.status === 200,
        JSON.stringify(first.raw).slice(0, 160));

    let cq = (await ref.get()).data()?.captureQuality ?? {};
    check("the SETTLING player's report was kept",
        cq[P1]?.darkEpisodes === 2, JSON.stringify(cq));
    check("THE LOSER OF THE RACE WAS NOT DISCARDED",
        cq[P2]?.quietEpisodes === 3,
        "written inside the claim, this is the report that vanishes: " +
        JSON.stringify(cq));

    console.log("\nwhat a hostile or absent report can do");
    ref = await makeMatch();
    await call(P1, "completeMatch", {matchId: ref.id,
      quality: {darkEpisodes: 1e9, quietEpisodes: -40}});
    cq = (await ref.get()).data()?.captureQuality ?? {};
    check("an absurd count is clamped rather than stored",
        cq[P1]?.darkEpisodes > 0 && cq[P1]?.darkEpisodes <= 50,
        JSON.stringify(cq));
    check("a negative count cannot buy back rank",
        cq[P1]?.quietEpisodes === 0, JSON.stringify(cq));

    ref = await makeMatch();
    const noReport = await call(P2, "completeMatch", {matchId: ref.id});
    check("a client that reports nothing still settles the match",
        noReport.status === 200, JSON.stringify(noReport.raw).slice(0, 160));
    check("...and NO REPORT IS RECORDED, not a zero one",
        (await ref.get()).data()?.captureQuality === undefined,
        "silence must stay distinguishable from a clean capture");

    ref = await makeMatch();
    const junk = await call(P1, "completeMatch", {matchId: ref.id,
      quality: "very dark"});
    check("a malformed report never blocks the settle",
        junk.status === 200, JSON.stringify(junk.raw).slice(0, 160));

    console.log("\nboundaries");
    ref = await makeMatch();
    const outsider = await call(OUT, "completeMatch", {matchId: ref.id,
      quality: {darkEpisodes: 9, quietEpisodes: 9}});
    check("A NON-PARTICIPANT CANNOT REPORT ON SOMEONE ELSE'S MATCH",
        outsider.status !== 200 &&
        (await ref.get()).data()?.captureQuality === undefined,
        JSON.stringify(outsider.raw).slice(0, 160));

    console.log("\nthe ranking actually reads it");
    const {captionScore} = require("../autoRender");
    if (typeof captionScore === "function") {
      const clean = captionScore({voteCount: 10}, 5);
      const rough = captionScore(
          {voteCount: 10, captureQuality: {[P1]: {darkEpisodes: 3}}}, 5);
      check("a broken capture ranks below an identical clean clip",
          rough < clean, `${rough} vs ${clean}`);
    } else {
      check("captionScore is exported for this check", false,
          "not exported - the ranking effect was not verified live");
    }
  } catch (err) {
    console.error("THREW:", err.message);
    failed++;
  } finally {
    for (const id of matchIds) {
      await db.collection("matches").doc(id).delete().catch(() => {});
    }
    for (const uid of [P1, P2, OUT]) {
      await db.recursiveDelete(db.collection("users").doc(uid)).catch(() => {});
      await auth.deleteUser(uid).catch(() => {});
    }
    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
  }
})();
