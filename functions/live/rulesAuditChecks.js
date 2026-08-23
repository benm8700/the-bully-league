/**
 * LIVE security audit of firestore.rules for the users document, run as a
 * real CLIENT (ID token over REST) rather than through the Admin SDK,
 * which bypasses rules entirely.
 *
 * Two questions:
 *   1. Can a client WRITE the fields that grant it things? The update rule
 *      is an immutability list, so anything not named in it is freely
 *      writable - which is easy to miss when adding a field.
 *   2. Can a client SEED those fields at CREATE? The create rule pins only
 *      a handful of values, so a field that is immutable afterwards could
 *      still be set to anything at signup and then frozen there, which is
 *      worse than being mutable.
 *
 * Every refusal check is paired with a CONTROL write proving the same
 * request path succeeds for an unprotected field - otherwise a check can
 * "pass" merely because the request was malformed.
 *
 * Run from functions/:  node live/rulesAuditChecks.js
 */
const fs = require("fs");
const {initializeApp, cert} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");
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

const BASE = `https://firestore.googleapis.com/v1/projects/${PROJECT}` +
  "/databases/(default)/documents";

async function idToken(uid) {
  const custom = await auth.createCustomToken(uid);
  const r = await fetch("https://identitytoolkit.googleapis.com/v1/accounts:" +
      "signInWithCustomToken?key=" + API_KEY,
  {method: "POST", headers: {"Content-Type": "application/json"},
    body: JSON.stringify({token: custom, returnSecureToken: true})});
  return (await r.json()).idToken;
}

/** PATCH one or more fields as the CLIENT, honouring firestore.rules. */
async function clientWrite(token, uid, fields) {
  const mask = Object.keys(fields)
      .map((f) => `updateMask.fieldPaths=${f}`).join("&");
  const r = await fetch(`${BASE}/users/${uid}?${mask}`, {
    method: "PATCH",
    headers: {"Content-Type": "application/json",
      Authorization: "Bearer " + token},
    body: JSON.stringify({fields}),
  });
  return r.status;
}

const num = (n) => ({integerValue: String(n)});
const str = (s) => ({stringValue: s});

const stamp = Date.now().toString(36);
const UID = `ra-${stamp}`;
const NEW = `ra-new-${stamp}`;
const made = [UID, NEW];

(async () => {
  try {
    // NOTE: every refusal below must write a CHANGED value. The rule pins
    // fields by immutability, so re-writing the SAME value is legitimately
    // allowed - two checks here first passed for that reason rather than
    // because the field was protected.
    // --- an EXISTING account trying to grant itself things -------------
    await auth.createUser({uid: UID, email: `${UID}@example.com`,
      password: "Test12345!"});
    await db.collection("users").doc(UID).set({
      username: `Ra${stamp}`, usernameLower: `ra${stamp}`,
      rating: 1200, rankTitle: "Average Joe", rankedMatchesPlayed: 0,
      wins: 0, losses: 0, accountStatus: "active", isAdmin: false,
      points: 0, pointsBalance: 0,
      judgeDayKey: "2020-01-01", judgeVotesToday: 0,
      careerRankedMatches: 25,
    });
    const tok = await idToken(UID);

    console.log("\nthe control: an ordinary field IS writable");
    check("a client can write its own profile",
        await clientWrite(tok, UID,
            {favouriteColour: str("blue")}) === 200,
        "if this fails, every refusal below proves nothing");

    console.log("\nfields that grant matchmaking advantages");
    let s = await clientWrite(tok, UID, {judgeVotesToday: num(9999)});
    check("a client CANNOT fake how much it judged today", s !== 200,
        `status ${s} - writing this mints earned skips and queue priority`);
    s = await clientWrite(tok, UID, {judgeDayKey: str("2099-01-01")});
    check("...nor the day that counter belongs to", s !== 200, `status ${s}`);

    console.log("\nfields that decide entitlement");
    s = await clientWrite(tok, UID, {careerRankedMatches: num(0)});
    check("a client CANNOT reset its career match count", s !== 200,
        `status ${s} - zero grants the new-player practice carve-out`);

    console.log("\nalready-protected fields, re-checked");
    for (const [field, value] of [
      ["pointsBalance", num(999999)],
      ["rating", num(9999)],
      ["isAdmin", {booleanValue: true}],
      ["accountStatus", str("banned")],
      ["skipsUsedToday", num(0)],
    ]) {
      s = await clientWrite(tok, UID, {[field]: value});
      check(`${field} is refused`, s !== 200, `status ${s}`);
    }

    // --- SEEDING at create, which the update rule cannot undo ----------
    console.log("\nseeding protected fields at SIGNUP");
    await auth.createUser({uid: NEW, email: `${NEW}@example.com`,
      password: "Test12345!"});
    const newTok = await idToken(NEW);
    // The exact shape signup writes, plus a subscription it should not
    // be able to grant itself.
    const r = await fetch(`${BASE}/users?documentId=${NEW}`, {
      method: "POST",
      headers: {"Content-Type": "application/json",
        Authorization: "Bearer " + newTok},
      body: JSON.stringify({fields: {
        rating: num(1200), rankTitle: str("Average Joe"),
        rankedMatchesPlayed: num(0), wins: num(0), losses: num(0),
        accountStatus: str("active"), isAdmin: {booleanValue: false},
        subscription: {mapValue: {fields: {
          active: {booleanValue: true},
        }}},
        pointsBalance: num(999999),
        judgeVotesToday: num(9999),
      }}),
    });
    check("A CLIENT CANNOT SEED ITSELF A SUBSCRIPTION AT SIGNUP",
        r.status !== 200,
        `status ${r.status} - if this succeeds, the update rule then ` +
        "FREEZES the forged values in place, which is worse than mutable");
    // --- THE CONTROL THAT MATTERS MOST --------------------------------
    // Tightening the create rule is worthless if it also breaks signup.
    // This writes EXACTLY what signup_screen.dart writes, as a client.
    console.log("\na real signup still works");
    const GOOD = `ra-ok-${stamp}`;
    await auth.createUser({uid: GOOD, email: `${GOOD}@example.com`,
      password: "Test12345!"});
    made.push(GOOD);
    const goodTok = await idToken(GOOD);
    const ok = await fetch(`${BASE}/users?documentId=${GOOD}`, {
      method: "POST",
      headers: {"Content-Type": "application/json",
        Authorization: "Bearer " + goodTok},
      body: JSON.stringify({fields: {
        rating: num(1200), rankTitle: str("Average Joe"),
        rankedMatchesPlayed: num(0), wins: num(0), losses: num(0),
        accountStatus: str("active"), isAdmin: {booleanValue: false},
        createdAt: {timestampValue: "2026-08-23T00:00:00Z"},
      }}),
    });
    check("SIGNUP IS NOT BROKEN by the tightened create rule",
        ok.status === 200,
        `status ${ok.status} - ${(await ok.text()).slice(0, 200)}`);

  } catch (err) {
    console.error("THREW:", err.message);
    failed++;
  } finally {
    for (const uid of made) {
      await db.recursiveDelete(db.collection("users").doc(uid))
          .catch(() => {});
      await auth.deleteUser(uid).catch(() => {});
    }
    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
  }
})();
