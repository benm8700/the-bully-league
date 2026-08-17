/**
 * LIVE checks for usernames against the DEPLOYED backend.
 *
 * The pure filter is covered by test/username.test.js. What can only be
 * checked here is the part that involves other people and other writes:
 * that a claim actually reserves a name, that the cooldown survives a
 * round trip, and - most importantly - that a client cannot simply write
 * `username` on its own document and skip all of it. That last one is the
 * whole point of the feature; if the rule is wrong, everything above it
 * is decoration.
 *
 * Run from functions/:  node live/usernameChecks.js
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

async function idToken(uid) {
  const custom = await auth.createCustomToken(uid);
  const r = await fetch(
      "https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=" + API_KEY,
      {method: "POST", headers: {"Content-Type": "application/json"},
        body: JSON.stringify({token: custom, returnSecureToken: true})});
  const j = await r.json();
  if (!j.idToken) throw new Error("sign-in failed: " + JSON.stringify(j));
  return j.idToken;
}

async function callable(fn, token, data) {
  const r = await fetch(`https://us-central1-${PROJECT}.cloudfunctions.net/${fn}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(token ? {Authorization: "Bearer " + token} : {}),
    },
    body: JSON.stringify({data: data ?? {}}),
  });
  const j = await r.json().catch(() => ({}));
  return {status: r.status, body: j};
}

/** A direct REST write as the USER, so firestore.rules actually apply -
 * the Admin SDK bypasses them and would prove nothing. */
async function userWrite(token, uid, fields) {
  const doc = {fields};
  const mask = Object.keys(fields).map((f) => `updateMask.fieldPaths=${f}`).join("&");
  const r = await fetch(
      `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents/users/${uid}?${mask}`,
      {method: "PATCH",
        headers: {"Content-Type": "application/json", Authorization: "Bearer " + token},
        body: JSON.stringify(doc)});
  return r.status;
}

(async () => {
  const stamp = Date.now().toString(36);
  const aUid = `un-a-${stamp}`;
  const bUid = `un-b-${stamp}`;
  const nameA = `Probe${stamp}`.slice(0, 20);

  for (const uid of [aUid, bUid]) {
    await auth.createUser({uid, email: `${uid}@example.com`, password: "Test12345!"});
    await db.collection("users").doc(uid).set({
      rating: 1200, rankTitle: "Average Joe", rankedMatchesPlayed: 0,
      wins: 0, losses: 0, accountStatus: "active", isAdmin: false,
      createdAt: Timestamp.now(),
    });
  }
  const aTok = await idToken(aUid);
  const bTok = await idToken(bUid);

  console.log("\nfilter and shape");
  let r = await callable("checkUsername", null, {username: "n1gg3r"});
  check("a slur is refused, and to an UNAUTHENTICATED caller too",
      r.status === 200 && r.body.result?.available === false,
      JSON.stringify(r.body));
  check("the refusal does not quote the term back",
      !/nig/i.test(JSON.stringify(r.body.result?.reason ?? "")));

  r = await callable("checkUsername", null, {username: "Nigeria"});
  check("an innocent name that trips a naive filter is allowed",
      r.body.result?.available === true, JSON.stringify(r.body));

  r = await callable("checkUsername", null, {username: "ab"});
  check("a too-short name is refused with a shape message",
      r.body.result?.available === false &&
      /3 characters/.test(r.body.result?.reason ?? ""));

  console.log("\nclaiming");
  r = await callable("setUsername", aTok, {username: nameA});
  check("a valid name is claimed", r.body.result?.username === nameA,
      JSON.stringify(r.body));
  const claim = await db.collection("usernames").doc(nameA.toLowerCase()).get();
  check("the claim document names the owner", claim.exists &&
      claim.data().uid === aUid);
  const aDoc = await db.collection("users").doc(aUid).get();
  check("the user document carries name and lowercase copy",
      aDoc.data().username === nameA &&
      aDoc.data().usernameLower === nameA.toLowerCase());
  check("the FIRST set does not start the cooldown",
      aDoc.data().usernameChangedAt === undefined,
      "a typo at signup must be fixable");

  console.log("\nuniqueness");
  r = await callable("setUsername", bTok, {username: nameA.toLowerCase()});
  check("another account cannot take it, even in different case",
      r.status !== 200 || r.body.error, JSON.stringify(r.body).slice(0, 120));
  r = await callable("checkUsername", bTok, {username: nameA});
  check("and it reads as unavailable to them",
      r.body.result?.available === false);
  r = await callable("checkUsername", aTok, {username: nameA});
  check("but reads as available to its OWNER, so a retry is not refused",
      r.body.result?.available === true);

  console.log("\nthe rule that makes all of the above real");
  // Control first. Without this, a 403 below would also be what a
  // malformed request produces, and the two most important checks in this
  // file would pass for the wrong reason.
  const control = await userWrite(aTok, aUid,
      {avatarUrl: {stringValue: "https://example.com/x.png"}});
  check("(control) the same write path CAN set an unprotected field",
      control === 200, `got ${control}`);

  const st = await userWrite(aTok, aUid, {username: {stringValue: "Admin"}});
  check("a client CANNOT write its own username directly", st === 403,
      `got ${st}`);
  const st2 = await userWrite(aTok, aUid, {usernameLower: {stringValue: "admin"}});
  check("nor the lowercase copy", st2 === 403, `got ${st2}`);
  const after = await db.collection("users").doc(aUid).get();
  check("and the stored name is untouched", after.data().username === nameA);

  console.log("\ncooldown");
  const nameA2 = `Probe2${stamp}`.slice(0, 20);
  r = await callable("setUsername", aTok, {username: nameA2});
  check("the first real change is allowed", r.body.result?.changed === true,
      JSON.stringify(r.body));
  const freed = await db.collection("usernames").doc(nameA.toLowerCase()).get();
  check("the old name is released back into the pool", !freed.exists);
  r = await callable("setUsername", aTok, {username: `Probe3${stamp}`.slice(0, 20)});
  check("a second change is refused by the cooldown",
      r.status !== 200 || r.body.error,
      JSON.stringify(r.body).slice(0, 140));
  r = await callable("setUsername", aTok, {username: nameA2});
  check("but re-submitting the SAME name is not treated as a change",
      r.body.result?.username === nameA2, JSON.stringify(r.body));

  r = await callable("getUsernameState", aTok);
  check("the state reports the lock and phrases it as a wait",
      r.body.result?.canChange === false &&
      /\d+ days|tomorrow/.test(r.body.result?.message ?? ""),
      JSON.stringify(r.body.result));

  console.log("\ndeletion releases the name");
  const cUid = `un-c-${stamp}`;
  const nameC = `Gone${stamp}`.slice(0, 20);
  await auth.createUser({uid: cUid, email: `${cUid}@example.com`,
    password: "Test12345!"});
  await db.collection("users").doc(cUid).set({
    rating: 1200, rankTitle: "Average Joe", rankedMatchesPlayed: 0,
    wins: 0, losses: 0, accountStatus: "active", isAdmin: false,
    createdAt: Timestamp.now(),
  });
  const cTok = await idToken(cUid);
  await callable("setUsername", cTok, {username: nameC});
  const held = await db.collection("usernames").doc(nameC.toLowerCase()).get();
  check("the name is held while the account exists", held.exists);

  r = await callable("deleteMyAccount", cTok, {});
  check("deletion reports the name was released",
      r.body.result?.summary?.usernameReleased === true,
      JSON.stringify(r.body).slice(0, 200));
  const released = await db.collection("usernames")
      .doc(nameC.toLowerCase()).get();
  check("the claim is gone", !released.exists);
  r = await callable("checkUsername", null, {username: nameC});
  check("and somebody else can now take it",
      r.body.result?.available === true, JSON.stringify(r.body));

  // Cleanup.
  await db.collection("usernames").doc(nameC.toLowerCase())
      .delete().catch(() => {});
  for (const uid of [aUid, bUid]) {
    await db.collection("users").doc(uid).delete().catch(() => {});
    await auth.deleteUser(uid).catch(() => {});
  }
  for (const n of [nameA, nameA2]) {
    await db.collection("usernames").doc(n.toLowerCase()).delete().catch(() => {});
  }

  console.log(`\n${passed} passed, ${failed} failed`);
  if (failed) process.exitCode = 1;
})().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
