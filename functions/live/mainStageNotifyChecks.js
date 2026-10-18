/**
 * LIVE checks for the Main Stage "carry them to the stage" pushes
 * (mainStageNotify.js) against real Firestore. FCM delivery is best-effort and
 * needs no real tokens here; what matters is the claim-once DEDUP (an
 * at-least-once trigger must never double-push) and the recipient resolution.
 *
 * Run from functions/:  node live/mainStageNotifyChecks.js
 */
const fs = require("fs");
const assert = require("assert");
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
const notify = require("../mainStageNotify");

let passed = 0; let failed = 0;
function check(name, cond, detail = "") {
  if (cond) { passed++; console.log(`  ok   ${name}`); } else {
    failed++; console.log(`  FAIL ${name} ${detail}`);
  }
}

const stamp = Date.now().toString(36);
const T = `msnotify_test_${stamp}`;
const ref = db.collection("tournaments").doc(T);

async function flags() {
  return (await ref.get()).data()?.msNotified || {};
}

(async () => {
  try {
    // Pure helpers first.
    check("judgesOf merges hand-picked + pool, deduped",
        JSON.stringify(notify.judgesOf(
            {handPickedJudges: ["j1", "j2"], judgePool: ["j2", "j3"]}).sort()) ===
        JSON.stringify(["j1", "j2", "j3"]));
    check("finalistsOf prefers the locked field",
        JSON.stringify(notify.finalistsOf(
            {field: ["a", "b"], finalists: ["x"]})) === JSON.stringify(["a", "b"]));

    // A live mainstage doc: 4 finalists, 2 judges, a bracket whose FINAL is NOT
    // yet ready (second slot empty).
    await ref.set({
      format: "mainstage", status: "live",
      field: ["f1", "f2", "f3", "f4"],
      handPickedJudges: ["j1"], judgePool: ["j2"],
      bracket: {rounds: [
        {matches: [{a: "f1", b: "f2", winner: null}, {a: "f3", b: "f4", winner: null}]},
        {matches: [{a: "f1", b: null, winner: null}]}, // final: opponent TBD
      ]},
      createdAt: Timestamp.now(),
    });

    await notify.notifyShowLive(T, (await ref.get()).data());
    check("show-live claims its dedup flag", (await flags()).showLive === true);
    await notify.notifyShowLive(T, (await ref.get()).data());
    check("show-live is idempotent (no re-claim to assert, just no throw)", true);

    // Final not ready yet -> no finalReady flag.
    await notify.notifyFinalReady(T, (await ref.get()).data());
    check("final-ready does NOT fire while the final's 2nd slot is empty",
        (await flags()).finalReady === undefined, JSON.stringify(await flags()));

    // Fill the final's second slot -> now it fires once. Firestore can't
    // address an array element by dotted path (it writes a nested map and
    // corrupts the array), so read-modify-write the whole bracket.
    {
      const d = (await ref.get()).data();
      const rounds = d.bracket.rounds;
      rounds[1].matches[0].b = "f3";
      await ref.update({bracket: {rounds}});
    }
    await notify.notifyFinalReady(T, (await ref.get()).data());
    check("final-ready fires once the final is ready",
        (await flags()).finalReady === true);

    // Battle on stage -> per-matchId flag, idempotent.
    await notify.notifyBattleOnStage(T, "ms_abc123");
    check("battle-on-stage claims a per-matchId flag",
        (await flags())["stage_ms_abc123"] === true);
    const before = JSON.stringify(await flags());
    await notify.notifyBattleOnStage(T, "ms_abc123");
    check("battle-on-stage is idempotent (same flags after a repeat)",
        JSON.stringify(await flags()) === before);
  } catch (e) {
    console.error("ERROR", e); failed++;
  } finally {
    await ref.delete().catch(() => {});
  }
  console.log(`\nmainStageNotify: ${passed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
})();
