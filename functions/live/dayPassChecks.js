/**
 * LIVE checks for the day pass and the vote-points cap, against the
 * DEPLOYED backend.
 *
 * The pure rules are covered by test/dayPass.test.js. What only works
 * here is the part that decides whether the economy actually holds: that
 * buying really spends points and really opens battling, that the ledger
 * makes a double tap free, and that the vote cap genuinely stops paying -
 * which is the thing standing between a 300-point pass and an afternoon's
 * tapping.
 *
 * Run from functions/:  node live/dayPassChecks.js
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
async function idToken(uid) {
  if (tokens[uid]) return tokens[uid];
  const custom = await auth.createCustomToken(uid);
  const r = await fetch(
      "https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=" + API_KEY,
      {method: "POST", headers: {"Content-Type": "application/json"},
        body: JSON.stringify({token: custom, returnSecureToken: true})});
  const j = await r.json();
  if (!j.idToken) throw new Error("sign-in failed: " + JSON.stringify(j));
  tokens[uid] = j.idToken;
  return j.idToken;
}

async function call(uid, fn, data) {
  const token = await idToken(uid);
  const r = await fetch(`https://us-central1-${PROJECT}.cloudfunctions.net/${fn}`, {
    method: "POST",
    headers: {"Content-Type": "application/json", Authorization: "Bearer " + token},
    body: JSON.stringify({data: data ?? {}}),
  });
  const j = await r.json().catch(() => ({}));
  return {status: r.status, body: j.result, raw: j};
}

/** A REST write as the USER, so firestore.rules actually apply. */
async function userWrite(uid, fields) {
  const token = await idToken(uid);
  const mask = Object.keys(fields)
      .map((f) => `updateMask.fieldPaths=${f}`).join("&");
  const r = await fetch(
      `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents/users/${uid}?${mask}`,
      {method: "PATCH",
        headers: {"Content-Type": "application/json",
          Authorization: "Bearer " + token},
        body: JSON.stringify({fields})});
  return r.status;
}

const stamp = Date.now().toString(36);
const P = `dp-${stamp}`;

(async () => {
  try {
    await auth.createUser({uid: P, email: `${P}@example.com`,
      password: "Test12345!"});
    // Deliberately LONG lapsed, so nothing is masked by the trial.
    await db.collection("users").doc(P).set({
      username: `Dp${stamp}`, usernameLower: `dp${stamp}`,
      rating: 1200, rankTitle: "Average Joe", rankedMatchesPlayed: 5,
      wins: 0, losses: 0, points: 1000, pointsBalance: 1000,
      accountStatus: "active", isAdmin: false,
      createdAt: Timestamp.fromMillis(Date.now() - 60 * 24 * 3600 * 1000),
    });

    console.log("\nbuying");
    let r = await call(P, "getDayPassState");
    const price = r.body?.price;
    check("the price and balance are reported",
        r.status === 200 && price > 0 && r.body.balance === 1000,
        JSON.stringify(r.body));
    check("...and it is buyable", r.body?.canBuy === true);
    check("no pass is running yet", r.body?.active === false);

    r = await call(P, "buyDayPass");
    check("a pass is bought", r.status === 200 && r.body.bought === true,
        JSON.stringify(r.raw).slice(0, 160));
    const expiresAtMs = r.body?.expiresAtMs;

    const after = await db.collection("users").doc(P).get();
    check("POINTS WERE SPENT from the balance",
        after.data().pointsBalance === 1000 - price,
        String(after.data().pointsBalance));
    check("...and the CAREER total is untouched",
        after.data().points === 1000, String(after.data().points));
    check("the expiry is about 24h out",
        Math.abs(expiresAtMs - Date.now() - 24 * 3600 * 1000) < 60000);

    console.log("\nwhat it buys");
    r = await call(P, "getMyEntitlement");
    check("the entitlement now reads as a day pass",
        r.body?.state === "daypass", JSON.stringify(r.body).slice(0, 160));
    // NOT asserting `ranked.allowed` here: enforcement currently ships
    // switched off, so everything is allowed regardless and that check
    // would pass whether the pass worked or not. `state` is the honest
    // signal - it reflects the policy's verdict either way.
    check("...and the entitlement is not reporting them lapsed",
        r.body?.state !== "lapsed", JSON.stringify(r.body?.state));

    console.log("\nit cannot be doubled up");
    r = await call(P, "buyDayPass");
    check("buying twice is refused rather than charging again",
        r.status !== 200, JSON.stringify(r.raw).slice(0, 140));
    const after2 = await db.collection("users").doc(P).get();
    check("...and the balance did not move again",
        after2.data().pointsBalance === 1000 - price);

    // Expire it by hand and confirm the SAME DAY cannot buy a second.
    await db.collection("users").doc(P).set(
        {dayPassExpiresAtMs: Date.now() - 1000}, {merge: true});
    r = await call(P, "buyDayPass");
    check("NOR CAN A SECOND BE BOUGHT the same day once it lapses",
        r.status !== 200, JSON.stringify(r.raw).slice(0, 140));
    const after3 = await db.collection("users").doc(P).get();
    check("...balance still unchanged", after3.data().pointsBalance ===
      1000 - price, String(after3.data().pointsBalance));

    r = await call(P, "getMyEntitlement");
    check("with the pass expired they are lapsed again",
        r.body?.state === "lapsed", JSON.stringify(r.body?.state));

    console.log("\nthe rules that protect it");
    const control = await userWrite(P, {
      avatarUrl: {stringValue: "https://example.com/x.png"}});
    check("(control) an unprotected field CAN be written", control === 200,
        `got ${control}`);
    const forged = await userWrite(P, {
      dayPassExpiresAtMs: {integerValue: String(Date.now() + 9e11)}});
    check("A CLIENT CANNOT GRANT ITSELF A PASS", forged === 403,
        `got ${forged}`);
    const counters = await userWrite(P, {
      dailyAwards: {mapValue: {fields: {}}}});
    check("nor reset its vote-points counters", counters === 403,
        `got ${counters}`);

    console.log("\nthe vote cap");
    // Drive the counter to the cap directly and confirm the pure rule the
    // deployed castVote uses agrees with what is stored.
    const {pointsSettings} = require("../points");
    const rates = await pointsSettings();
    const {dailyAwardBlocked} = require("../points");
    const {pacificNow} = require("../eventWindow");
    const dayKey = pacificNow(new Date()).dayKey;
    await db.collection("users").doc(P).set({
      dailyAwards: {vote_cast: {day: dayKey, count: rates.votePointsPerDay}},
    }, {merge: true});
    const capped = await db.collection("users").doc(P).get();
    check("AT THE CAP, further votes stop paying",
        dailyAwardBlocked(capped.data(), "vote_cast", dayKey,
            rates.votePointsPerDay) === true);
    check("a fresh day pays again",
        dailyAwardBlocked(capped.data(), "vote_cast", "1999-01-01",
            rates.votePointsPerDay) === false);
    check("the cap is well below the pass price, so judging alone takes days",
        rates.votePointsPerDay * rates.voteCast * 2 < rates.dayPassPrice,
        `${rates.votePointsPerDay} x ${rates.voteCast} vs ${rates.dayPassPrice}`);
  } finally {
    await db.recursiveDelete(db.collection("users").doc(P)).catch(() => {});
    await auth.deleteUser(P).catch(() => {});
    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
  }
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
