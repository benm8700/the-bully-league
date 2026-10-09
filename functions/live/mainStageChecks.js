/**
 * Live check for the Main Stage (weekly finals) lifecycle against the DEPLOYED
 * backend. The pure decisions are proven in test/mainStageLifecycle.test.js;
 * this proves the SEAMS those can't see:
 *   - createFromSnapshot reading stats/weeklyQualifierSnapshot and writing the
 *     tournament doc (shape + idempotency);
 *   - lockDueTournaments' real query (format==mainstage, status==accepting) and
 *     its per-user accountStatus read that excludes a banned judge;
 *   - recordBattleResult's transaction advancing a real bracket to a champion;
 *   - and the cross-module completion seam: a Main Stage win grants the
 *     permanent Champion badge (tournamentWins++) but must NOT move the daily
 *     belt (the bug this session fixed in belt.js's isGauntlet).
 *
 * It backs up and restores the shared snapshot doc and the belt doc, drives the
 * module functions with explicit `now` values relative to a chosen cutoff day,
 * waits for the deployed onTournamentCompleted trigger, and tears everything
 * down in a finally.
 *
 * Run from functions/:  node live/mainStageChecks.js
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

const {getFirestore} = require("firebase-admin/firestore");
const {
  createFromSnapshot, lockDueTournaments, recordBattleResult, scheduleFor,
  docIdFor,
} = require("../mainStageTournament");
const {createBracket} = require("../mainStageBracket");
const {storeBracket} = require("../mainStageLifecycle");

const db = getFirestore();
let passed = 0;
async function check(name, fn) {
  await fn();
  passed++;
  console.log(`  ok - ${name}`);
}

const PFX = "mscheck";
const uid = (s) => `${PFX}-${s}`;
// A cutoff day far in the future so this never collides with a real snapshot's
// derived doc id, and the schedule maths is exercised for real.
const DAY = "2099-10-15";
const {lockAtMs} = scheduleFor(DAY);
const TID = docIdFor(DAY);

const FIN = [uid("f1"), uid("f2"), uid("f3"), uid("f4")];
const ALT = [uid("a1"), uid("a2"), uid("a3"), uid("a4")];
const POOL = [uid("j1"), uid("j2"), uid("j3"), uid("j4"), uid("j5")];

let snapBackup; let snapExisted = false;
let beltBackup; let beltExisted = false;

async function seed() {
  // Back up the shared docs we touch, so a real snapshot/belt is never lost.
  const snapRef = db.collection("stats").doc("weeklyQualifierSnapshot");
  const snap = await snapRef.get();
  snapExisted = snap.exists;
  snapBackup = snap.exists ? snap.data() : null;
  const beltRef = db.collection("stats").doc("belt");
  const belt = await beltRef.get();
  beltExisted = belt.exists;
  beltBackup = belt.exists ? belt.data() : null;

  await snapRef.set({
    tournamentDayKey: DAY,
    finalists: FIN.map((u, i) => ({uid: u, gain: 100 - i})),
    alternates: ALT.map((u, i) => ({uid: u, gain: 50 - i})),
    judgePool: POOL.map((u, i) => ({uid: u, judged: 50 - i})),
  });
  // Real user docs so excludedJudgeUids reads something: j5 is BANNED, so it
  // must be dropped from the panel. The champion (f1) needs a doc so the
  // Champion-badge increment lands.
  const batch = db.batch();
  for (const u of [...FIN, ...ALT, ...POOL]) {
    batch.set(db.collection("users").doc(u),
        {username: u, accountStatus: u === uid("j5") ? "banned" : "active"});
  }
  await batch.commit();
}

async function cleanup() {
  const dels = [db.collection("tournaments").doc(TID)];
  for (const u of [...FIN, ...ALT, ...POOL]) {
    dels.push(db.collection("users").doc(u));
  }
  await Promise.all(dels.map((r) => r.delete().catch(() => {})));
  const snapRef = db.collection("stats").doc("weeklyQualifierSnapshot");
  if (snapExisted) await snapRef.set(snapBackup);
  else await snapRef.delete().catch(() => {});
  const beltRef = db.collection("stats").doc("belt");
  if (beltExisted) await beltRef.set(beltBackup);
  else await beltRef.delete().catch(() => {});
}

async function run() {
  await seed();

  await check("createFromSnapshot writes an accepting doc with pending invites",
      async () => {
        const r = await createFromSnapshot(db, lockAtMs - 60 * 60 * 1000);
        assert.strictEqual(r.created, true, "should create");
        const t = (await db.collection("tournaments").doc(TID).get()).data();
        assert.strictEqual(t.format, "mainstage");
        assert.strictEqual(t.status, "accepting");
        assert.strictEqual(t.createdBy, "auto");
        assert.deepStrictEqual(t.finalists, FIN);
        assert.strictEqual(Object.keys(t.invites).length, 8);
        assert.ok(Object.values(t.invites).every((s) => s === "pending"));
      });

  await check("createFromSnapshot is idempotent (doc already exists)",
      async () => {
        const r = await createFromSnapshot(db, lockAtMs - 60 * 60 * 1000);
        assert.strictEqual(r.created, false);
        assert.strictEqual(r.reason, "exists");
      });

  // f2 declines, top alternate a1 confirms -> field [f1,f3,f4,a1].
  await check("invites recorded; a decline promotes a confirmed alternate",
      async () => {
        await db.collection("tournaments").doc(TID).update({
          ["invites." + uid("f1")]: "accepted",
          ["invites." + uid("f2")]: "declined",
          ["invites." + uid("f3")]: "accepted",
          ["invites." + uid("f4")]: "accepted",
          ["invites." + uid("a1")]: "accepted",
        });
        // (no assertion here beyond the write succeeding; the field is resolved
        // at lock, checked next)
      });

  await check("lock resolves the field + a 5-seat panel, dropping the banned j5",
      async () => {
        const res = await lockDueTournaments(db, lockAtMs + 60 * 1000);
        const mine = res.find((r) => r.id === TID);
        assert.ok(mine && mine.locked, "should lock");
        const t = (await db.collection("tournaments").doc(TID).get()).data();
        assert.strictEqual(t.status, "locked");
        assert.deepStrictEqual(t.field, [uid("f1"), uid("f3"), uid("f4"), uid("a1")]);
        // pool is j1..j5 but j5 is banned -> 4 judges, shortfall 1.
        assert.ok(!t.judges.includes(uid("j5")), "banned judge excluded");
        assert.strictEqual(t.judges.length, 4);
        assert.strictEqual(t.judgeShortfall, 1);
      });

  await check("lock is idempotent (a locked doc isn't re-touched)", async () => {
    const res = await lockDueTournaments(db, lockAtMs + 120 * 1000);
    assert.ok(!res.find((r) => r.id === TID), "already locked -> not in sweep");
  });

  // Simulate the #1's live callout: f1 calls out f3. (The callable's auth path
  // is pure-tested; here we just need a real live bracket to advance.)
  await check("callout writes a bracket and goes live", async () => {
    const field = [uid("f1"), uid("f3"), uid("f4"), uid("a1")];
    const bracket = createBracket(field, uid("f3"));
    await db.collection("tournaments").doc(TID)
        .update({bracket: storeBracket(bracket), status: "live"});
    const t = (await db.collection("tournaments").doc(TID).get()).data();
    assert.strictEqual(t.status, "live");
    assert.strictEqual(t.bracket.pick, uid("f3"));
  });

  await check("recordBattleResult advances semis then crowns a champion",
      async () => {
        // semi 0: f1 beats f3 (the callout). semi 1: f4 beats a1.
        let r = await recordBattleResult(db, TID, 0, 0, uid("f1"));
        assert.strictEqual(r.ok, true);
        assert.strictEqual(r.completed, false);
        r = await recordBattleResult(db, TID, 0, 1, uid("f4"));
        assert.strictEqual(r.completed, false);
        // final: f1 beats f4.
        r = await recordBattleResult(db, TID, 1, 0, uid("f1"));
        assert.strictEqual(r.completed, true);
        assert.strictEqual(r.champion, uid("f1"));
        const t = (await db.collection("tournaments").doc(TID).get()).data();
        assert.strictEqual(t.status, "completed");
        assert.strictEqual(t.winnerId, uid("f1"));
      });

  await check("completion grants the Champion badge but NOT the daily belt",
      async () => {
        // Wait for the deployed onTournamentCompleted trigger.
        let recorded = false;
        for (let i = 0; i < 20 && !recorded; i++) {
          await new Promise((res) => setTimeout(res, 1000));
          const t = (await db.collection("tournaments").doc(TID).get()).data();
          recorded = t.championRecorded === true;
        }
        assert.ok(recorded, "championRecorded should flip via the trigger");
        // Champion badge counter incremented (permanent, every tournament).
        const champ = (await db.collection("users").doc(uid("f1")).get()).data();
        assert.strictEqual(champ.tournamentWins, 1, "Champion badge counted");
        // The DAILY belt must be untouched - a mainstage win is not a gauntlet.
        const beltNow = (await db.collection("stats").doc("belt").get()).data();
        const beltHolderNow = beltNow ? beltNow.holderUid : null;
        const beltHolderBefore = beltBackup ? beltBackup.holderUid : null;
        assert.strictEqual(beltHolderNow, beltHolderBefore,
            "belt holder must be unchanged by a Main Stage win");
      });
}

run()
    .then(() => console.log(`\n${passed} passed`))
    .catch((e) => {
      console.error("FAILED:", e.message);
      process.exitCode = 1;
    })
    .finally(cleanup);
