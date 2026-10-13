/**
 * LIVE checks for castLiveReaction against the DEPLOYED backend.
 *
 * The crowd's live reaction feeds a PUBLIC identity number (emojiCounts), so
 * the guard that matters - one reaction per account, the emoji increments, the
 * participant refusal, the Crowd Favourite tally - is worth proving on the real
 * server, not just in the pure test.
 *
 * It seeds a voteSessions/{uid} doc directly (the same shape a Turnstile solve
 * writes) so the session gate passes without a CAPTCHA, exactly as a real
 * session would.
 *
 * Run from functions/:  node live/liveReactionChecks.js
 */
const fs = require("fs");
const {initializeApp, cert} = require("firebase-admin/app");
const {getFirestore, Timestamp, FieldValue} = require("firebase-admin/firestore");
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

/** Calls a deployed callable as `uid` (a fresh ID token each time, so several
 * different callers work). Returns {status, result, errStatus, errMessage}. */
async function callAs(uid, fn, data) {
  const custom = await auth.createCustomToken(uid);
  const r = await fetch(
      "https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=" + API_KEY,
      {method: "POST", headers: {"Content-Type": "application/json"},
        body: JSON.stringify({token: custom, returnSecureToken: true})});
  const idToken = (await r.json()).idToken;
  const resp = await fetch(`https://us-central1-${PROJECT}.cloudfunctions.net/${fn}`, {
    method: "POST",
    headers: {"Content-Type": "application/json", Authorization: "Bearer " + idToken},
    body: JSON.stringify({data: data ?? {}}),
  });
  const j = await resp.json().catch(() => ({}));
  return {
    status: resp.status,
    result: j.result,
    errStatus: j.error?.status,
    errMessage: j.error?.message,
  };
}

const stamp = Date.now().toString(36);
const R = `lr-r-${stamp}`;
const R2 = `lr-r2-${stamp}`;
const P1 = `lr-p1-${stamp}`;
const P2 = `lr-p2-${stamp}`;
const M = `lrm-${stamp}`;
const MNO = `lrmno-${stamp}`; // a non-mainStage match

async function mkUser(uid) {
  await auth.createUser({uid, email: `${uid}@example.com`, password: "testpass123"})
      .catch(() => {});
  await db.collection("users").doc(uid).set({username: uid, createdAt: FieldValue.serverTimestamp()});
}
async function mkSession(uid) {
  await db.collection("voteSessions").doc(uid).set({
    votesRemaining: 25,
    expiresAt: Timestamp.fromMillis(Date.now() + 20 * 60 * 1000),
    startedAt: FieldValue.serverTimestamp(),
  });
}

async function cleanup() {
  for (const uid of [R, R2, P1, P2]) {
    await auth.deleteUser(uid).catch(() => {});
    await db.collection("users").doc(uid).delete().catch(() => {});
    await db.collection("voteSessions").doc(uid).delete().catch(() => {});
  }
  for (const m of [M, MNO]) {
    await db.recursiveDelete(db.collection("liveReactions").doc(m)).catch(() => {});
    await db.collection("matches").doc(m).delete().catch(() => {});
  }
}

async function run() {
  await Promise.all([mkUser(R), mkUser(R2), mkUser(P1), mkUser(P2)]);
  await Promise.all([mkSession(R), mkSession(R2), mkSession(P1)]);
  await db.collection("matches").doc(M).set({
    status: "in_progress", mode: "tournament",
    player1Id: P1, player2Id: P2,
    mainStage: {tournamentId: "lr-t", roundIdx: 0, matchIdx: 0},
  });
  await db.collection("matches").doc(MNO).set({
    status: "in_progress", mode: "ranked", player1Id: P1, player2Id: P2,
  });

  // 1. A spectator reacts to a live Main Stage battle.
  const r1 = await callAs(R, "castLiveReaction",
      {matchId: M, emojiRatings: {[P1]: "fire", [P2]: "clever"}, favorite: P1});
  check("a spectator can react to a live Main Stage battle",
      r1.status === 200 && r1.result?.ok === true, JSON.stringify(r1));

  // 2. The two permanent emoji identity counts moved.
  const p1 = (await db.collection("users").doc(P1).get()).data();
  const p2 = (await db.collection("users").doc(P2).get()).data();
  check("roaster 1's permanent emojiCounts.fire incremented",
      (p1?.emojiCounts?.fire ?? 0) === 1, JSON.stringify(p1?.emojiCounts));
  check("roaster 2's permanent emojiCounts.clever incremented",
      (p2?.emojiCounts?.clever ?? 0) === 1, JSON.stringify(p2?.emojiCounts));

  // 3. The live Crowd Favourite tally + reactor record.
  const tally = (await db.collection("liveReactions").doc(M).get()).data();
  check("the Crowd Favourite tally credited the chosen roaster",
      (tally?.favorites?.[P1] ?? 0) === 1 && (tally?.reactorCount ?? 0) === 1,
      JSON.stringify(tally));
  const reactor = await db.collection("liveReactions").doc(M)
      .collection("reactors").doc(R).get();
  check("the reactor record was written (one-per-account guard)", reactor.exists);

  // 4. A second reaction from the same account is refused.
  const r2 = await callAs(R, "castLiveReaction",
      {matchId: M, emojiRatings: {[P1]: "trash", [P2]: "trash"}, favorite: P2});
  check("a second reaction from the same account is refused",
      r2.status !== 200 && /already/i.test(r2.errMessage || ""),
      JSON.stringify(r2));
  const p1b = (await db.collection("users").doc(P1).get()).data();
  check("...and the refused reaction did NOT move the counts again",
      (p1b?.emojiCounts?.fire ?? 0) === 1 && (p1b?.emojiCounts?.trash ?? 0) === 0,
      JSON.stringify(p1b?.emojiCounts));

  // 5. A participant can't react to their own battle.
  const rp = await callAs(P1, "castLiveReaction",
      {matchId: M, emojiRatings: {[P1]: "fire", [P2]: "fire"}, favorite: P1});
  check("a participant can't react to their own battle",
      rp.status === 403 && rp.errStatus === "PERMISSION_DENIED" &&
        /battle/i.test(rp.errMessage || ""),
      JSON.stringify(rp));

  // 6. A non-Main-Stage match is not reactable.
  const rno = await callAs(R2, "castLiveReaction",
      {matchId: MNO, emojiRatings: {[P1]: "fire", [P2]: "clever"}, favorite: P1});
  check("a non-Main-Stage match is refused",
      rno.status !== 200 && /live main stage/i.test(rno.errMessage || ""),
      JSON.stringify(rno));

  // 7. No session -> refused (the Turnstile/session guard holds).
  await db.collection("voteSessions").doc(R2).delete();
  const rns = await callAs(R2, "castLiveReaction",
      {matchId: M, emojiRatings: {[P1]: "fire", [P2]: "clever"}, favorite: P1});
  check("no session and no Turnstile -> refused",
      rns.status !== 200 && /session|captcha/i.test(rns.errMessage || ""),
      JSON.stringify(rns));
}

run()
    .then(() => console.log(`\n${passed} passed, ${failed} failed`))
    .catch((e) => {
      console.error("FAILED:", e.message);
      failed++;
    })
    .finally(async () => {
      await cleanup();
      console.log("cleanup done");
      process.exit(failed > 0 ? 1 : 0);
    });
