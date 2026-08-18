/**
 * LIVE checks for the directory -> challenge path.
 *
 * The two halves were built separately and this is the seam between them:
 * searchPlayers hands back the DISPLAY-CASE username, while challengeFriend
 * resolves through usernameLower. If those ever disagree, the button in the
 * search results fails for every player whose name is not already lowercase
 * - which is almost all of them - and the failure would read as "that
 * player doesn't exist".
 *
 * Also asserts the property that makes blocking worth having: a blocked
 * player is not merely hidden from search, they are refused if challenged
 * anyway, and the refusal is worded identically to a missing player.
 *
 * Run from functions/:  node live/directoryChallengeChecks.js
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
    const r = await fetch("https://identitytoolkit.googleapis.com/v1/accounts:" +
        "signInWithCustomToken?key=" + API_KEY,
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
const SEEKER = `dc-seek-${stamp}`;
const TARGET = `dc-targ-${stamp}`;
const BLOCKER = `dc-block-${stamp}`;
// Deliberately MIXED CASE - a name stored and displayed exactly as typed.
const TARGET_NAME = `DcTarget${stamp}`;
const BLOCKER_NAME = `DcBlocker${stamp}`;
const users = [SEEKER, TARGET, BLOCKER];

async function makeUser(uid, name) {
  await auth.createUser({uid, email: `${uid}@example.com`,
    password: "Test12345!"});
  await db.collection("users").doc(uid).set({
    username: name, usernameLower: name.toLowerCase(),
    rating: 1200, rankTitle: "Average Joe", rankedMatchesPlayed: 0,
    wins: 0, losses: 0, accountStatus: "active", isAdmin: false,
    createdAt: Timestamp.now(),
  });
}

(async () => {
  try {
    await makeUser(SEEKER, `DcSeeker${stamp}`);
    await makeUser(TARGET, TARGET_NAME);
    await makeUser(BLOCKER, BLOCKER_NAME);

    console.log("\nfinding somebody, then challenging them");
    let r = await call(SEEKER, "searchPlayers", {query: `dctarget${stamp}`});
    const found = (r.body?.results ?? []).find((p) => p.uid === TARGET);
    check("the directory finds them", Boolean(found),
        JSON.stringify(r.body).slice(0, 200));
    check("...and returns the DISPLAY-CASE name the button will send",
        found?.username === TARGET_NAME, String(found?.username));

    // Exactly what the button does: pass the returned username straight
    // through, without lowercasing it on the client.
    r = await call(SEEKER, "challengeFriend", {username: found?.username});
    check("THE SEAM HOLDS: a mixed-case directory name challenges cleanly",
        r.status === 200, JSON.stringify(r.raw).slice(0, 200));

    const challengeId = r.body?.challengeId;
    check("a real challenge was created", Boolean(challengeId),
        JSON.stringify(r.body));

    console.log("\nunrated by design");
    if (challengeId) {
      const c = await db.collection("challenges").doc(challengeId).get();
      check("the challenge is for a FRIEND battle, which moves no rating",
          c.data()?.mode === "friend" || c.data()?.mode === undefined,
          `mode is ${c.data()?.mode}`);
    }

    console.log("\nblocking survives the new route in");
    await call(BLOCKER, "setBlocked", {userId: SEEKER, blocked: true});
    r = await call(SEEKER, "searchPlayers", {query: `dcblocker${stamp}`});
    const hidden = (r.body?.results ?? []).find((p) => p.uid === BLOCKER);
    check("a blocker is hidden from the blocked player's search", !hidden,
        JSON.stringify(r.body).slice(0, 160));

    // The real test: the name is knowable by other means, so the SERVER
    // has to refuse it rather than relying on the row being absent.
    const refused = await call(SEEKER, "challengeFriend",
        {username: BLOCKER_NAME});
    check("CHALLENGING THEM ANYWAY IS REFUSED, not merely hidden",
        refused.status !== 200, JSON.stringify(refused.raw).slice(0, 160));

    const missing = await call(SEEKER, "challengeFriend",
        {username: `NobodyAtAll${stamp}`});
    check("...and the refusal is WORD-FOR-WORD a missing player's",
        refused.raw?.error?.message === missing.raw?.error?.message,
        `blocked: "${refused.raw?.error?.message}" vs ` +
        `missing: "${missing.raw?.error?.message}"`);
  } catch (err) {
    console.error("THREW:", err.message);
    failed++;
  } finally {
    const cs = await db.collection("challenges")
        .where("fromUserId", "==", SEEKER).get().catch(() => ({docs: []}));
    for (const d of cs.docs) await d.ref.delete().catch(() => {});
    for (const uid of users) {
      await db.recursiveDelete(db.collection("users").doc(uid)).catch(() => {});
      await auth.deleteUser(uid).catch(() => {});
    }
    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
  }
})();
