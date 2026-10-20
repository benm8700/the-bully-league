// TEST SETUP: unlock every ability (unlockXp 0) via config so both phone
// accounts can equip them regardless of XP. Reverted after the 2-phone test.
// Touches ONLY config/abilities - no account XP/rank changes.
const fs = require("fs");
const {initializeApp, cert} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");
const E = fs.readFileSync("../website/.env.local", "utf8");
function v(k) {
  const l = E.split(/\r?\n/).find((x) => x.startsWith(k + "="));
  let s = l.slice(k.length + 1).trim();
  if (s.startsWith("\"")) s = s.slice(1, -1);
  return s.replace(/\\n/g, "\n");
}
initializeApp({credential: cert({
  projectId: v("FIREBASE_PROJECT_ID"),
  clientEmail: v("FIREBASE_CLIENT_EMAIL"),
  privateKey: v("FIREBASE_PRIVATE_KEY"),
})});
const db = getFirestore();
const IDS = ["interrupt", "instantInterrupt", "tomato", "fart", "extend",
  "goFirst", "goSecond", "skipWarmup"];
const mode = process.argv[2]; // "unlock" or "restore"
(async () => {
  const ref = db.collection("config").doc("abilities");
  if (mode === "restore") {
    // Delete the per-ability overrides, keep enabled + _note.
    const {FieldValue} = require("firebase-admin/firestore");
    const patch = {};
    for (const id of IDS) patch[id] = FieldValue.delete();
    await ref.set(patch, {merge: true});
    console.log("restored: per-ability overrides removed");
  } else {
    const patch = {enabled: true};
    for (const id of IDS) patch[id] = {unlockXp: 0};
    await ref.set(patch, {merge: true});
    console.log("unlocked all abilities for testing (unlockXp 0)");
  }
  console.log(JSON.stringify((await ref.get()).data(), null, 1));
  process.exit(0);
})();
