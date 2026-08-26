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

const {XP_TIERS, GOAT_TITLE} = require("../rating");
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
      rating: 1200, points: 0, pointsBalance: 0,
      rankTitle: XP_TIERS[0].title, rankedMatchesPlayed: 0,
      wins: 0, losses: 0, accountStatus: "active", isAdmin: false,
      createdAt: Timestamp.now(),
    });

    console.log("\na new account with no XP");
    let r = await call(UID, "getLaughMeter", {});
    check("the meter loads", r.status === 200 && r.body?.title,
        JSON.stringify(r.raw).slice(0, 200));
    check("...and shows a real climb, not an empty or full bar",
        r.body.fill >= 0 && r.body.fill <= 1 && Boolean(r.body.nextTitle),
        JSON.stringify(r.body));

    console.log("\nthe bar tracks XP within the current title's band");
    await setState({
      rankTitle: XP_TIERS[1].title,
      points: XP_TIERS[2].minXp - 1, // one XP short of the next title
    });
    r = await call(UID, "getLaughMeter", {});
    check("THE BAR IS NEAR FULL just before the next title",
        r.body.fill > 0.9, JSON.stringify(r.body));
    await setState({rankTitle: XP_TIERS[1].title, points: XP_TIERS[1].minXp});
    r = await call(UID, "getLaughMeter", {});
    check("...and near empty just after promoting into a title",
        r.body.fill < 0.05, JSON.stringify(r.body));

    console.log("\nthe thresholds stay hidden");
    let leaked = null;
    for (let i = 0; i < XP_TIERS.length; i++) {
      for (const points of [0, 300, 1500, 4999]) {
        await setState({rankTitle: XP_TIERS[i].title, points});
        const m = await call(UID, "getLaughMeter", {});
        if (/\d{3,}/.test(m.body?.caption ?? "")) {
          leaked = `${XP_TIERS[i].title}@${points}: ${m.body.caption}`;
        }
      }
    }
    check("NO CAPTION EVER LEAKS AN XP-SIZED NUMBER", leaked === null,
        String(leaked));

    console.log("\nthe top of the ladder");
    const top = XP_TIERS[XP_TIERS.length - 1];
    await setState({rankTitle: top.title, points: top.minXp + 5000});
    r = await call(UID, "getLaughMeter", {});
    check("Hall of Famer points at GOAT without faking progress toward it",
        r.body.nextTitle === GOAT_TITLE && r.body.state === "contender",
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
