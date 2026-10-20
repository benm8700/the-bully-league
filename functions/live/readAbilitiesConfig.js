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
(async () => {
  const snap = await db.collection("config").doc("abilities").get();
  console.log("config/abilities exists:", snap.exists);
  console.log(JSON.stringify(snap.data() || {}, null, 2));
  process.exit(0);
})();
