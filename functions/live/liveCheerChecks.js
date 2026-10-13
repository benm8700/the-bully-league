/**
 * LIVE rule checks for ephemeral live cheers (firestore.rules
 * liveReactions/{matchId}/cheers). Run from functions/:
 *   node live/liveCheerChecks.js
 *
 * A cheer is pure vibe - a floating emoji, no identity, no verdict - so the
 * rule is light (signed-in read, own-uid create). But "own-uid create" still
 * has to actually hold, and a rule is only real if it is exercised as a CLIENT
 * (the Admin SDK bypasses rules entirely).
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

const stamp = Date.now().toString(36);
const UID = `lc-${stamp}`;
const M = `lcm-${stamp}`;

function cheerFields(uid) {
  return {
    emoji: {stringValue: "fire"},
    uid: {stringValue: uid},
    atMs: {integerValue: String(Date.now())},
    expireAt: {timestampValue: new Date(Date.now() + 300000).toISOString()},
  };
}

async function createCheer(token, cheerId, dataUid) {
  const r = await fetch(`${BASE}/liveReactions/${M}/cheers/${cheerId}`, {
    method: "PATCH",
    headers: {"Content-Type": "application/json", Authorization: "Bearer " + token},
    body: JSON.stringify({fields: cheerFields(dataUid)}),
  });
  return r.status;
}

(async () => {
  try {
    await auth.createUser({uid: UID, email: `${UID}@example.com`, password: "Test12345!"});
    const tok = await idToken(UID);

    const own = await createCheer(tok, "c1", UID);
    check("a signed-in viewer can create a cheer with their OWN uid", own === 200, `status ${own}`);

    const forged = await createCheer(tok, "c2", "someone-else");
    check("a cheer FORGED with another uid is refused", forged === 403, `status ${forged}`);

    const read = await fetch(`${BASE}/liveReactions/${M}/cheers`, {
      headers: {Authorization: "Bearer " + tok},
    });
    check("any signed-in viewer can read the cheer stream", read.status === 200, `status ${read.status}`);
  } catch (e) {
    console.error("FAILED:", e.message);
    failed++;
  } finally {
    await db.recursiveDelete(db.collection("liveReactions").doc(M)).catch(() => {});
    await auth.deleteUser(UID).catch(() => {});
    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed > 0 ? 1 : 0);
  }
})();
