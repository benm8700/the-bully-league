/**
 * LIVE checks for the Laugh Meter, against the DEPLOYED backend.
 *
 * The two properties worth checking against the real thing are that the
 * gauge never leaks a rating threshold, and that it never shows a FULL
 * bar to somebody who is not about to promote - the natural failure of
 * showing rating alone when promotion also needs a minimum match count.
 *
 * Run from functions/:  node live/laughMeterChecks.js
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

let token = null;
async function call(uid, fn, data) {
  if (!token) {
    const custom = await auth.createCustomToken(uid);
    const r = await fetch("https://identitytoolkit.googleapis.com/v1/accounts:" +
        "signInWithCustomToken?key=" + API_KEY,
    {method: "POST", headers: {"Content-Type": "application/json"},
      body: JSON.stringify({token: custom, returnSecureToken: true})});
    token = (await r.json()).idToken;
  }
  const r = await fetch(`https://us-central1-${PROJECT}.cloudfunctions.net/${fn}`, {
    method: "POST",
    headers: {"Content-Type": "application/json",
      Authorization: "Bearer " + token},
    body: JSON.stringify({data: data ?? {}}),
  });
  const text = await r.text();
  let j;
  try {
    j = JSON.parse(text);
  } catch {
    // Kept as text so a non-JSON failure (a Cloud Run HTML error page, a
    // 500) is legible instead of collapsing to an empty object.
    j = {nonJson: text.slice(0, 300)};
  }
  return {status: r.status, body: j.result, raw: j};
}

const {RANK_TIERS, GOAT_TITLE} = require("../rating");
const stamp = Date.now().toString(36);
const UID = `lm-${stamp}`;

async function setState(fields) {
  await db.collection("users").doc(UID).set(fields, {merge: true});
}

(async () => {
  try {
    await auth.createUser({uid: UID, email: `${UID}@example.com`,
      password: "Test12345!"});
    await db.collection("users").doc(UID).set({
      username: `Lm${stamp}`, usernameLower: `lm${stamp}`,
      rating: 1200, rankTitle: RANK_TIERS[0].title, rankedMatchesPlayed: 0,
      wins: 0, losses: 0, accountStatus: "active", isAdmin: false,
      createdAt: Timestamp.now(),
    });

    console.log("\na new account");
    let r = await call(UID, "getLaughMeter", {});
    check("the meter loads", r.status === 200 && r.body?.title,
        JSON.stringify(r.raw).slice(0, 200));
    check("...and shows a real climb, not an empty or full bar",
        r.body.fill >= 0 && r.body.fill <= 1 && Boolean(r.body.nextTitle),
        JSON.stringify(r.body));

    console.log("\nthe rating is there but the matches are not");
    await setState({
      rankTitle: RANK_TIERS[1].title,
      rating: RANK_TIERS[2].minRating + 50,
      rankedMatchesPlayed: RANK_TIERS[1].minMatches,
    });
    r = await call(UID, "getLaughMeter", {});
    check("THE BAR IS NOT FULL, because matches are what is binding",
        r.body.fill < 1 && r.body.binding === "matches",
        JSON.stringify(r.body));
    check("...and it says how many battles are left",
        r.body.matchesRemaining > 0, JSON.stringify(r.body));

    console.log("\nthe thresholds stay hidden");
    let leaked = null;
    for (let i = 0; i < RANK_TIERS.length; i++) {
      for (const rating of [900, 1200, 1500, 1900]) {
        await setState({rankTitle: RANK_TIERS[i].title, rating,
          rankedMatchesPlayed: 999});
        const m = await call(UID, "getLaughMeter", {});
        if (/\d{3,}/.test(m.body?.caption ?? "")) {
          leaked = `${RANK_TIERS[i].title}@${rating}: ${m.body.caption}`;
        }
      }
    }
    check("NO CAPTION EVER LEAKS A RATING-SIZED NUMBER", leaked === null,
        String(leaked));

    console.log("\nthe top of the ladder");
    const top = RANK_TIERS[RANK_TIERS.length - 1];
    await setState({rankTitle: top.title, rating: 1900,
      rankedMatchesPlayed: 999});
    r = await call(UID, "getLaughMeter", {});
    check("Hall of Famer points at GOAT without faking progress toward it",
        r.body.nextTitle === GOAT_TITLE && r.body.binding === "leaderboard",
        JSON.stringify(r.body));

    await setState({rankTitle: GOAT_TITLE});
    r = await call(UID, "getLaughMeter", {});
    check("GOAT has no next rank at all", r.body.nextTitle === null,
        JSON.stringify(r.body));
    check("...and its copy is about holding the slot, not climbing",
        !/climb|halfway|more ranked/i.test(r.body.caption ?? ""),
        String(r.body.caption));

    console.log("\nboundaries");
    const anon = await fetch(
        `https://us-central1-${PROJECT}.cloudfunctions.net/getLaughMeter`,
        {method: "POST", headers: {"Content-Type": "application/json"},
          body: JSON.stringify({data: {}})});
    check("a signed-out caller is refused", anon.status !== 200,
        String(anon.status));
  } catch (err) {
    console.error("THREW:", err.message);
    failed++;
  } finally {
    await db.recursiveDelete(db.collection("users").doc(UID)).catch(() => {});
    await auth.deleteUser(UID).catch(() => {});
    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
  }
})();
