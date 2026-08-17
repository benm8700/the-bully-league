/**
 * ONE-OFF BACKFILL: create a usernames/{key} claim for every account that
 * already has a name.
 *
 * WHY THIS IS NOT OPTIONAL. Uniqueness is enforced entirely by the claim
 * collection, and every account that existed before setUsername shipped
 * has a name but no claim. Until this runs, those names read as FREE - so
 * a new signup could take the name of an established player, and on a
 * leaderboard the two would be indistinguishable. That is the exact
 * impersonation the claim collection exists to prevent, and it would be
 * introduced *by* adding the protection rather than in spite of it.
 *
 * Also backfills usernameLower where it is missing, since the player
 * directory's prefix search is blind to any account without it.
 *
 * Safe to re-run: it never overwrites a claim owned by someone else, and
 * reports collisions rather than resolving them silently - two legacy
 * accounts sharing a name is a real situation that wants a human answer.
 *
 * Run from functions/:  node live/backfillUsernameClaims.js [--apply]
 */
const fs = require("fs");
const {initializeApp, cert} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");

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
const APPLY = process.argv.includes("--apply");

/** Mirrors usernameKey in ../username.js. */
const keyOf = (name) => String(name ?? "").trim().toLowerCase();

(async () => {
  const users = await db.collection("users").get();
  const seen = new Map();
  const collisions = [];
  const toWrite = [];
  let noName = 0;

  for (const doc of users.docs) {
    const name = doc.data().username;
    if (typeof name !== "string" || !name.trim()) {
      noName++;
      continue;
    }
    const key = keyOf(name);
    if (seen.has(key)) {
      collisions.push({key, uids: [seen.get(key), doc.id]});
      continue;
    }
    seen.set(key, doc.id);

    const claim = await db.collection("usernames").doc(key).get();
    if (claim.exists) {
      if (claim.data().uid !== doc.id) {
        collisions.push({key, uids: [claim.data().uid, doc.id], existing: true});
      }
      continue;
    }
    toWrite.push({
      key,
      uid: doc.id,
      name,
      needsLower: doc.data().usernameLower !== key,
    });
  }

  console.log(`accounts: ${users.size}, without a name: ${noName}`);
  console.log(`claims to create: ${toWrite.length}`);
  for (const w of toWrite) {
    console.log(`  ${w.name}  ->  ${w.uid}${w.needsLower ? "  (+lower)" : ""}`);
  }
  if (collisions.length) {
    console.log("\nCOLLISIONS - resolve by hand, nothing written for these:");
    for (const c of collisions) console.log(" ", JSON.stringify(c));
  }

  if (!APPLY) {
    console.log("\nDry run. Re-run with --apply to write.");
    return;
  }

  for (const w of toWrite) {
    const batch = db.batch();
    batch.set(db.collection("usernames").doc(w.key), {
      uid: w.uid, username: w.name, claimedAt: Date.now(), backfilled: true,
    });
    if (w.needsLower) {
      batch.set(db.collection("users").doc(w.uid),
          {usernameLower: w.key}, {merge: true});
    }
    await batch.commit();
  }
  console.log(`\nwrote ${toWrite.length} claims.`);
})().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
