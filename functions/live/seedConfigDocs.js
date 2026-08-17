/**
 * Creates the config documents the code reads but nobody had written.
 *
 * WHY THIS IS WORTH DOING even though the code already falls back to
 * defaults: the whole point of putting these in Firestore rather than in
 * code is that the developer can retune them from the console without
 * shipping an app version. A document that does not exist cannot be
 * found, so in practice the switch may as well have been hardcoded. Each
 * one is written at EXACTLY the documented default, so nothing behaves
 * differently - this only makes the dials visible, and carries a _note
 * explaining what each does, the same way config/eventWindow already does.
 *
 * Only writes documents that are missing. Never overwrites a tuned value.
 *
 * Run from functions/:  node live/seedConfigDocs.js [--apply]
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

const DOCS = {
  monetization: {
    enabled: false,
    trialDays: 14,
    _note: "THE MASTER SWITCH for the whole paywall. enabled:false means " +
      "every entitlement check passes and nothing is restricted - which " +
      "is correct while there is no way to pay. Turning it on enforces: " +
      "free accounts battle RANKED only during the event window, Practice " +
      "is closed to everyone during the window (except players who have " +
      "never played ranked), and stats/directory/auto-clips become " +
      "subscriber features. trialDays is full access after signup; " +
      "accounts with no createdAt are treated as in-trial forever rather " +
      "than locked out.",
  },
  serviceStatus: {
    active: false,
    severity: "info",
    message: "",
    updatedAtMs: 0,
    _note: "A notice shown at the top of every screen in the app. Set " +
      "active:true and write a message when Agora or Firebase is down, or " +
      "to broadcast anything (\"no Sixes and Sevens tonight\"). severity " +
      "is info | warning | outage and only changes the colour. IMPORTANT: " +
      "set updatedAtMs to the current epoch millis whenever you edit the " +
      "message - a notice with no timestamp is not shown at all, and one " +
      "with no expiresAtMs disappears on its own 24h after updatedAtMs so " +
      "a forgotten banner cannot become permanent. Set expiresAtMs " +
      "explicitly for anything shorter or longer.",
  },
  usernamePolicy: {
    changeCooldownDays: 30,
    extraBlocked: [],
    _note: "changeCooldownDays: how long after CHANGING a username before " +
      "it can change again. The first change is always free - the clock " +
      "starts on the first change, not at signup, so a typo during " +
      "onboarding is fixable. extraBlocked: extra terms refused in " +
      "usernames, matched as substrings after confusable mapping " +
      "(n1gg3r and nigger are the same string by then). Add a term here " +
      "rather than redeploying. To UNBLOCK a false positive the code must " +
      "change - report it rather than editing this.",
  },
};

const APPLY = process.argv.includes("--apply");

(async () => {
  const db = getFirestore();
  for (const [id, data] of Object.entries(DOCS)) {
    const ref = db.collection("config").doc(id);
    const snap = await ref.get();
    if (snap.exists) {
      console.log(`config/${id}: already exists, left alone`);
      continue;
    }
    console.log(`config/${id}: MISSING -> ${JSON.stringify(data).slice(0, 80)}...`);
    if (APPLY) {
      await ref.set(data);
      console.log(`  written`);
    }
  }
  if (!APPLY) console.log("\nDry run. Re-run with --apply to write.");
})().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
