/**
 * LIVE checks: finalizing a match whose opponent DELETED THEIR ACCOUNT.
 *
 * CCPA deletion deliberately keeps the match document while removing the
 * user, precisely so the surviving opponent's history is not destroyed by
 * somebody else's erasure request. Until this fix, finalization threw on
 * a missing user document - so every deletion left a match that could
 * never settle, was retried and re-thrown by the hourly sweep forever,
 * and never recorded the result for the player who is still here. The
 * match document was being kept to protect a history that was then never
 * written.
 *
 * Run from functions/:  node live/deletedPlayerChecks.js
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

const stamp = Date.now().toString(36);
const SURVIVOR = `dp-live-${stamp}`;
const LEAVER = `dp-gone-${stamp}`;
const made = {matches: [], users: [SURVIVOR, LEAVER]};

async function makeUser(uid, rating) {
  await auth.createUser({uid, email: `${uid}@example.com`,
    password: "Test12345!"}).catch(() => {});
  await db.collection("users").doc(uid).set({
    username: `Dp${uid.slice(-6)}`, usernameLower: `dp${uid.slice(-6)}`,
    rating, rankTitle: "Average Joe", rankedMatchesPlayed: 4,
    careerRankedMatches: 4, wins: 2, losses: 2,
    accountStatus: "active", isAdmin: false, createdAt: Timestamp.now(),
  });
}

/** A completed, past-window ranked match with real ballots. */
async function makeSettledMatch({stampRatings}) {
  const old = Timestamp.fromMillis(Date.now() - 48 * 60 * 60 * 1000);
  const ref = db.collection("matches").doc();
  made.matches.push(ref.id);
  await ref.set({
    player1Id: SURVIVOR, player2Id: LEAVER, mode: "ranked",
    status: "completed", createdAt: old, completedAt: old,
    voteFinalized: false, winnerId: null, voteCount: 3,
    channelName: `match_${ref.id}`,
    ...(stampRatings ? {player1Rating: 1200, player2Rating: 1600} : {}),
  });
  // Three ballots for the survivor, so there is a real, decisive result.
  for (let i = 0; i < 3; i++) {
    await db.collection("votes").doc(ref.id).collection("ballots")
        .doc(`ghost-${stamp}-${i}`).set({
          votedForPlayerId: SURVIVOR, weight: 1, createdAt: old,
        });
  }
  return ref;
}

(async () => {
  try {
    const {finalizeMatch} = require("../matchFinalization");

    console.log("\nthe opponent deleted their account, ratings were stamped");
    await Promise.all([makeUser(SURVIVOR, 1200), makeUser(LEAVER, 1600)]);
    let ref = await makeSettledMatch({stampRatings: true});
    // The real deletion path keeps the match and removes the user.
    await db.recursiveDelete(db.collection("users").doc(LEAVER));

    let result = await finalizeMatch(ref.id).catch((e) => ({thrown: e.message}));
    check("FINALIZING NO LONGER THROWS", !result?.thrown,
        String(result?.thrown));

    let m = (await ref.get()).data();
    check("the match is finalized, so the sweep stops retrying it forever",
        m.voteFinalized === true);
    check("the real result is recorded", m.winnerId === SURVIVOR,
        String(m.winnerId));

    let s = (await db.collection("users").doc(SURVIVOR).get()).data();
    check("THE SURVIVOR STILL GETS THE RATING THEY EARNED",
        s.rating > 1200, `rating is ${s.rating}`);
    // Asserted against what an EQUAL opponent would have paid rather
    // than a hardcoded number: the gain here is also scaled down by vote
    // confidence (three ballots against a threshold of ten), so a bare
    // threshold would be testing the confidence curve by accident.
    const {applyEloChange, voteConfidence} = require("../rating");
    const conf = voteConfidence(3);
    const vsEqual = applyEloChange(1200, 1200, 1, conf) - 1200;
    check("...computed against the STAMPED opponent rating, so beating a " +
        "1600 pays MORE than beating an equal would",
        s.rating - 1200 > vsEqual,
        `gained ${s.rating - 1200}, an equal opponent would pay ${vsEqual}`);
    check("their win was recorded", s.wins === 3, String(s.wins));

    const hist = await db.collection("users").doc(SURVIVOR)
        .collection("ratingHistory").doc(ref.id).get();
    check("their rating history was written", hist.exists);

    const ghost = await db.collection("users").doc(LEAVER)
        .collection("ratingHistory").doc(ref.id).get();
    check("NOTHING WAS RESURRECTED UNDER THE DELETED ACCOUNT",
        !ghost.exists,
        "a subcollection write would recreate data erased on request");

    console.log("\nan older match with no stamped ratings");
    await makeUser(LEAVER, 1600);
    ref = await makeSettledMatch({stampRatings: false});
    await db.recursiveDelete(db.collection("users").doc(LEAVER));
    const before = (await db.collection("users").doc(SURVIVOR).get())
        .data().rating;

    result = await finalizeMatch(ref.id).catch((e) => ({thrown: e.message}));
    check("it still finalizes rather than jamming", !result?.thrown,
        String(result?.thrown));
    m = (await ref.get()).data();
    check("the result is still recorded", m.voteFinalized === true &&
        m.winnerId === SURVIVOR);
    s = (await db.collection("users").doc(SURVIVOR).get()).data();
    check("NO RATING IS FABRICATED against an unknowable opponent",
        s.rating === before, `${before} -> ${s.rating}`);
  } catch (err) {
    console.error("THREW:", err.message);
    failed++;
  } finally {
    for (const id of made.matches) {
      await db.recursiveDelete(db.collection("votes").doc(id)).catch(() => {});
      await db.collection("matches").doc(id).delete().catch(() => {});
    }
    for (const uid of made.users) {
      await db.recursiveDelete(db.collection("users").doc(uid)).catch(() => {});
      await auth.deleteUser(uid).catch(() => {});
    }
    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
  }
})();
