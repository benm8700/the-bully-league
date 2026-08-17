/**
 * One-off backfill: writes `usernameLower` for accounts created before
 * the player directory existed.
 *
 * WHY IT IS NEEDED. The directory does a prefix query on that field, and
 * a Firestore range query matches only documents where the field EXISTS -
 * so without this, every pre-existing player would be silently
 * unsearchable while appearing perfectly normal everywhere else. The same
 * missing-field trap this project has now hit with accountStatus,
 * createdAt, pointsBalance and the vote-reminder preference query.
 *
 * Idempotent: an account that already has a correct value is skipped, so
 * this can be re-run safely.
 *
 *   cd functions && node live/backfillUsernameLower.js
 */
const fs = require("fs");
const {initializeApp, cert} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");

const E = fs.readFileSync("../website/.env.local", "utf8");
function val(k) {
  const line = E.split(/\r?\n/).find((l) => l.startsWith(k + "="));
  let v = line.slice(k.length + 1).trim();
  if (v.startsWith('"') && v.endsWith('"')) v = v.slice(1, -1);
  return v.replace(/\\n/g, "\n");
}
initializeApp({credential: cert({
  projectId: "the-bully-league",
  clientEmail: val("FIREBASE_CLIENT_EMAIL"),
  privateKey: val("FIREBASE_PRIVATE_KEY"),
})});

(async () => {
  const snap = await getFirestore().collection("users").get();
  let written = 0; let skipped = 0; let nameless = 0;
  for (const doc of snap.docs) {
    const username = doc.get("username");
    if (typeof username !== "string" || !username.trim()) {
      nameless++;
      continue;
    }
    const expected = username.trim().toLowerCase();
    if (doc.get("usernameLower") === expected) {
      skipped++;
      continue;
    }
    await doc.ref.update({usernameLower: expected});
    written++;
  }
  console.log(`accounts: ${snap.size}`);
  console.log(`backfilled: ${written}, already correct: ${skipped}, ` +
    `no username: ${nameless}`);
})();
