/**
 * LIVE checks for the season reset, against the DEPLOYED backend.
 *
 * This is the most destructive callable in the project - it rewrites the
 * rating of every account at once - so the checks that matter most are
 * the ones that prove it REFUSES: a non-admin, a season already closed,
 * and a missing season number. The dry run is checked against real
 * accounts so the numbers can be inspected before anything is written.
 *
 * It deliberately never runs a real reset against the live userbase.
 *
 * Run from functions/:  node live/seasonResetChecks.js
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
const PLAIN = `sr-plain-${stamp}`;
const ADMIN = `sr-admin-${stamp}`;
// A season number far outside anything real, so a mistake here can never
// collide with a genuine season.
const SEASON = 9000 + Math.floor(Date.now() % 900);

async function makeUser(uid, extra = {}) {
  await auth.createUser({uid, email: `${uid}@example.com`,
    password: "Test12345!"});
  await db.collection("users").doc(uid).set({
    username: `Sr${uid.slice(-6)}`, usernameLower: `sr${uid.slice(-6)}`,
    rating: 1200, rankTitle: "Average Joe", rankedMatchesPlayed: 0,
    wins: 0, losses: 0, accountStatus: "active", isAdmin: false,
    createdAt: Timestamp.now(), ...extra,
  });
}

(async () => {
  try {
    await makeUser(PLAIN);
    await makeUser(ADMIN, {isAdmin: true});

    console.log("\nwho may close a season");
    let r = await call(PLAIN, "runSeasonReset",
        {seasonNumber: SEASON, dryRun: true});
    check("A NON-ADMIN CANNOT RESET THE LADDER", r.status !== 200,
        JSON.stringify(r.raw).slice(0, 120));

    console.log("\narguments");
    r = await call(ADMIN, "runSeasonReset", {dryRun: true});
    check("a missing season number is refused", r.status !== 200,
        JSON.stringify(r.raw).slice(0, 120));
    r = await call(ADMIN, "runSeasonReset",
        {seasonNumber: 0, dryRun: true});
    check("a nonsense season number is refused", r.status !== 200);

    console.log("\ndry run against real accounts");
    r = await call(ADMIN, "runSeasonReset",
        {seasonNumber: SEASON, dryRun: true});
    check("a dry run reports what it would do",
        r.status === 200 && r.body?.dryRun === true && r.body.accounts > 0,
        JSON.stringify(r.body).slice(0, 200));
    const sample = r.body?.sample ?? [];
    check("...with real before and after ratings",
        sample.length > 0 && sample.every((s) =>
          Number.isFinite(s.from) && Number.isFinite(s.to)),
        JSON.stringify(sample.slice(0, 2)));
    check("...and it pulls toward the centre, never past it",
        sample.every((s) => (s.from >= 1200 ? s.to <= s.from && s.to >= 1200 :
          s.to >= s.from && s.to <= 1200)),
        JSON.stringify(sample.slice(0, 3)));

    const archived = await db.collection("seasons")
        .doc(String(SEASON)).get();
    check("A DRY RUN WRITES NOTHING - no season document was created",
        !archived.exists);

    console.log("\nthe guard against running it twice");
    // Written by hand rather than by a real reset, so the live userbase is
    // never actually reset by this check.
    await db.collection("seasons").doc(String(SEASON)).set({
      seasonNumber: SEASON, note: "probe - not a real season",
      closedAt: Timestamp.now(),
    });
    r = await call(ADMIN, "runSeasonReset",
        {seasonNumber: SEASON, dryRun: true});
    check("A SEASON ALREADY CLOSED CANNOT BE CLOSED AGAIN",
        r.status !== 200,
        "otherwise a repeated call pulls every rating toward the centre twice");
  } catch (err) {
    console.error('THREW:', err.message);
    failed++;
  } finally {
    await db.collection("seasons").doc(String(SEASON)).delete().catch(() => {});
    for (const uid of [PLAIN, ADMIN]) {
      await db.recursiveDelete(db.collection("users").doc(uid)).catch(() => {});
      await auth.deleteUser(uid).catch(() => {});
    }
    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
  }
})().catch((e) => {
  console.error("THREW:", e.message);
  process.exit(1);
});
