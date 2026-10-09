/**
 * Live check for the weekly-Elo qualifier sweep against the DEPLOYED backend.
 *
 * The pure ranking/boundary logic is proven in test/weeklyQualifier.test.js.
 * This proves the SEAM the unit tests can't see: the collection-group read of
 * everyone's ratingHistory, the write to the stats docs, and - most important -
 * that the failsafe flag (config/tournament.enabled) actually gates it.
 *
 * It seeds throwaway ratingHistory entries in the most-recently-closed week,
 * drives the sweep with a synthetic `now` just past that cutoff (so the
 * snapshot path fires deterministically whatever day this is run), and asserts
 * the frozen field. Probe gains are deliberately huge so they dominate any real
 * beta data. Everything it creates is torn down in a finally, and the launch
 * flag is restored OFF.
 *
 * Run from functions/:  node live/weeklyQualifierChecks.js
 */
const fs = require("fs");
const assert = require("assert");
const {initializeApp, cert} = require("firebase-admin/app");

const E = fs.readFileSync("../website/.env.local", "utf8");
function val(k) {
  const line = E.split(/\r?\n/).find((l) => l.startsWith(k + "="));
  let v = line.slice(k.length + 1).trim();
  if (v.startsWith("\"") && v.endsWith("\"")) v = v.slice(1, -1);
  return v.replace(/\\n/g, "\n");
}
initializeApp({
  credential: cert({
    projectId: val("FIREBASE_PROJECT_ID"),
    clientEmail: val("FIREBASE_CLIENT_EMAIL"),
    privateKey: val("FIREBASE_PRIVATE_KEY"),
  }),
  databaseURL: "https://the-bully-league-default-rtdb.firebaseio.com",
  storageBucket: "the-bully-league.firebasestorage.app",
});

const {getFirestore, Timestamp} = require("firebase-admin/firestore");
const {sweepWeeklyQualifier} = require("../weeklyTournament");
const {mostRecentlyClosedWeek, qualifyingWeek} = require("../weeklyQualifier");

const db = getFirestore();
let passed = 0;
async function check(name, fn) {
  await fn();
  passed++;
  console.log(`  ok - ${name}`);
}

const PFX = "wqcheck";
const uid = (s) => `${PFX}-${s}`;

// Probes in the most-recently-closed week. Huge gains so they top any real
// data. `low` has a massive gain but too few games (excluded by min-5);
// `friend` is non-ladder (excluded by mode).
const closed = mostRecentlyClosedWeek(Date.now());
const atMid = Math.round((closed.startMs + closed.cutoffMs) / 2);
const PROBES = [
  {u: uid("a"), mode: "ranked", deltas: [100, 100, 100, 100, 100, 100]}, // +600
  {u: uid("b"), mode: "ranked", deltas: [100, 100, 100, 100, 100, 0]}, //   +500
  {u: uid("c"), mode: "tournament", deltas: [100, 100, 100, 50, 30, 20]}, // +400
  {u: uid("low"), mode: "ranked", deltas: [300, 300, 300]}, // +900 but 3 games
  {u: uid("friend"), mode: "friend", deltas: [200, 200, 200, 200]}, // non-ladder
];

async function seed() {
  const batch = db.batch();
  for (const p of PROBES) {
    p.deltas.forEach((delta, i) => {
      const ref = db.collection("users").doc(p.u)
          .collection("ratingHistory").doc(`${p.u}-m${i}`);
      batch.set(ref, {
        delta, mode: p.mode, at: Timestamp.fromMillis(atMid + i),
        ratingBefore: 1200, ratingAfter: 1200 + delta, won: delta > 0,
      });
    });
  }
  await batch.commit();
}

async function cleanup() {
  for (const p of PROBES) {
    const snap = await db.collection("users").doc(p.u)
        .collection("ratingHistory").get();
    const batch = db.batch();
    snap.forEach((d) => batch.delete(d.ref));
    await batch.commit();
  }
  await db.collection("stats").doc("weeklyQualifier").delete().catch(() => {});
  await db.collection("stats").doc("weeklyQualifierSnapshot").delete()
      .catch(() => {});
  // Restore the launch flag OFF (the documented failsafe default).
  await db.collection("config").doc("tournament").set({enabled: false});
}

function uidsOf(list) {
  return (list || []).map((p) => p.uid);
}

async function main() {
  console.log("weekly qualifier - live (deployed backend)");
  await seed();
  const now = closed.cutoffMs + 5 * 60 * 1000; // 5 min past the cutoff

  await check("FAILSAFE: disabled flag -> sweep no-ops", async () => {
    await db.collection("config").doc("tournament").set({enabled: false});
    const r = await sweepWeeklyQualifier(now);
    assert.strictEqual(r.skipped, "disabled");
  });

  await check("enabled -> snapshot freezes the just-closed week", async () => {
    await db.collection("config").doc("tournament").set({enabled: true});
    const r = await sweepWeeklyQualifier(now);
    assert.ok(!r.skipped, "sweep ran");
    const snap = (await db.collection("stats")
        .doc("weeklyQualifierSnapshot").get()).data();
    assert.ok(snap, "snapshot written");
    assert.strictEqual(snap.tournamentDayKey, closed.cutoffDayKey);
  });

  await check("probes appear ranked by Elo gain (a > b > c)", async () => {
    const snap = (await db.collection("stats")
        .doc("weeklyQualifierSnapshot").get()).data();
    const all = uidsOf([...(snap.finalists || []), ...(snap.alternates || [])]);
    const ia = all.indexOf(uid("a"));
    const ib = all.indexOf(uid("b"));
    const ic = all.indexOf(uid("c"));
    assert.ok(ia >= 0 && ib >= 0 && ic >= 0, "a,b,c all present");
    assert.ok(ia < ib && ib < ic, "ordered by gain");
  });

  await check("min-5-games excludes the huge-but-tiny-sample probe",
      async () => {
        const snap = (await db.collection("stats")
            .doc("weeklyQualifierSnapshot").get()).data();
        const all = uidsOf([
          ...(snap.finalists || []), ...(snap.alternates || [])]);
        assert.ok(!all.includes(uid("low")), "3-game +900 probe excluded");
      });

  await check("non-ladder (friend) entries never count", async () => {
    const snap = (await db.collection("stats")
        .doc("weeklyQualifierSnapshot").get()).data();
    const all = uidsOf([...(snap.finalists || []), ...(snap.alternates || [])]);
    assert.ok(!all.includes(uid("friend")), "friend-mode probe excluded");
  });

  await check("live board written for the CURRENT week", async () => {
    const live = (await db.collection("stats")
        .doc("weeklyQualifier").get()).data();
    assert.ok(live, "live board written");
    assert.strictEqual(live.tournamentDayKey, qualifyingWeek(now).cutoffDayKey);
  });

  await check("re-running does not re-snapshot (idempotent)", async () => {
    const before = (await db.collection("stats")
        .doc("weeklyQualifierSnapshot").get()).data().snapshotAt;
    await sweepWeeklyQualifier(now);
    const after = (await db.collection("stats")
        .doc("weeklyQualifierSnapshot").get()).data().snapshotAt;
    assert.deepStrictEqual(after, before, "snapshot unchanged on re-run");
  });
}

main()
    .then(() => console.log(`\n${passed} passed`))
    .catch((e) => {
      console.error("FAILED:", e.message);
      process.exitCode = 1;
    })
    .finally(cleanup);
