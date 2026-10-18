/**
 * LIVE check for the Main Stage auto-start backstop (time enforcement). Stages
 * a LOCKED show whose 6pm+grace is already past and runs autoStartDueShows
 * against real Firestore: it should go LIVE with a built bracket, and a second
 * run must be a no-op (idempotent). Cleans up after itself.
 *
 * Run from functions/:  node live/mainStageAutoStartChecks.js
 */
const fs = require("fs");
const {initializeApp, cert} = require("firebase-admin/app");
const {getFirestore, Timestamp} = require("firebase-admin/firestore");

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
const {autoStartDueShows, AUTO_START_GRACE_MS} = require("../mainStageTournament");

let passed = 0; let failed = 0;
function check(name, cond, detail = "") {
  if (cond) { passed++; console.log(`  ok   ${name}`); } else {
    failed++; console.log(`  FAIL ${name} ${detail}`);
  }
}

const stamp = Date.now().toString(36);
const T = `mainstage_autostart_test_${stamp}`;
const ref = db.collection("tournaments").doc(T);

(async () => {
  try {
    const now = Date.now();
    await ref.set({
      format: "mainstage", status: "locked",
      showAtMs: now - AUTO_START_GRACE_MS - 60000, // 6pm + grace already past
      field: ["asf1", "asf2", "asf3", "asf4"],
      judgePool: ["asj1"], handPickedJudges: [],
      createdAt: Timestamp.now(),
    });

    const r1 = await autoStartDueShows(db, now);
    const d1 = (await ref.get()).data();
    const rounds = d1.bracket?.rounds;
    check("an overdue locked show auto-starts -> live",
        d1.status === "live" && d1.autoStarted === true,
        `status=${d1.status} autoStarted=${d1.autoStarted}`);
    check("a bracket was built (2 semis + a final)",
        Array.isArray(rounds) && rounds.length === 2 &&
        rounds[0].matches.length === 2 && rounds[1].matches.length === 1,
        JSON.stringify(rounds));
    check("standard seeding: #1 (field[0]) vs the bottom seed (field[3])",
        rounds?.[0]?.matches?.[0]?.a === "asf1" &&
        rounds?.[0]?.matches?.[0]?.b === "asf4",
        JSON.stringify(rounds?.[0]?.matches?.[0]));
    check("the run reported the auto-start",
        r1.some((x) => x.id === T && x.autoStarted));

    const r2 = await autoStartDueShows(db, Date.now());
    check("a second run is a no-op (already live, not re-started)",
        !r2.some((x) => x.id === T && x.autoStarted));
  } catch (e) {
    console.error("ERROR", e); failed++;
  } finally {
    await ref.delete().catch(() => {});
  }
  console.log(`\nmainStageAutoStart: ${passed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
})();
