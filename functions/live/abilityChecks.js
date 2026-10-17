/**
 * Live check for MATCH ABILITIES against the DEPLOYED backend, with the
 * KILL SWITCH as the headline property: with config/abilities.enabled = false
 * the whole feature is off (no loadout, no selling, zero seeded counts) even
 * for a player who had already bought abilities - so flipping that one boolean
 * fully removes abilities at runtime, which is the safe-removability the
 * developer asked for.
 *
 * Also exercises the economy when ON: free allowance, buy spends points,
 * idempotent on requestId, the per-match cap, and that getMatchAbilities seeds
 * both players (what the host feeds the chess-clock engine).
 *
 * Mints real ID tokens per participant (createCustomToken ->
 * signInWithCustomToken) so the deployed callables run under genuine auth.
 * Toggles config/abilities for the ON phase and RESTORES it in a finally, so
 * the project is left exactly as found (gated off).
 *
 * Run from functions/:  node live/abilityChecks.js
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
});

const {getFirestore, FieldValue, Timestamp} = require("firebase-admin/firestore");
const {getAuth} = require("firebase-admin/auth");
const {DEFAULTS} = require("../abilities");

const db = getFirestore();
const API_KEY = "AIzaSyD-yeC1osuXpfwXWNZPnLEOq7yLviM7J0c";
const REGION = "https://us-central1-the-bully-league.cloudfunctions.net";

const PFX = "abck";
const uid = (s) => `${PFX}-${s}`;
const PA = uid("pA");
const PB = uid("pB");
const MATCH = "ability_abck_match";

let passed = 0;
async function check(name, fn) {
  await fn();
  passed++;
  console.log(`  ok - ${name}`);
}

async function idToken(u) {
  const custom = await getAuth().createCustomToken(u);
  const r = await fetch(
      `https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=${API_KEY}`,
      {method: "POST", headers: {"Content-Type": "application/json"},
        body: JSON.stringify({token: custom, returnSecureToken: true})});
  const j = await r.json();
  if (!j.idToken) throw new Error("token mint failed: " + JSON.stringify(j));
  return j.idToken;
}

async function callFn(name, token, data) {
  const r = await fetch(`${REGION}/${name}`, {
    method: "POST",
    headers: {"Content-Type": "application/json",
      "Authorization": "Bearer " + token},
    body: JSON.stringify({data}),
  });
  return {status: r.status, body: await r.json()};
}

async function setEnabled(enabled) {
  await db.collection("config").doc("abilities").set({enabled}, {merge: true});
}

let originalConfig = null;

async function seed() {
  originalConfig =
    (await db.collection("config").doc("abilities").get()).data() || null;
  // Old createdAt so neither is in the free-trial window: free allowance = 0,
  // so the per-match cap is reached by BUYING exactly maxPerMatch (what the cap
  // assertion below expects). A fresh account would be in trial and get a free
  // one, which counts toward the cap and would shift the math.
  const old = Timestamp.fromMillis(Date.now() - 100 * 24 * 60 * 60 * 1000);
  const batch = db.batch();
  // points (career XP) >= the highest ability unlockXp (2000) so the rank gate
  // added 2026-10-15 doesn't lock these probes out of buying interrupt etc.
  batch.set(db.collection("users").doc(PA),
      {username: "AbilityPA", pointsBalance: 5000, points: 5000, rating: 1200, createdAt: old});
  batch.set(db.collection("users").doc(PB),
      {username: "AbilityPB", pointsBalance: 5000, points: 5000, rating: 1200, createdAt: old});
  batch.set(db.collection("matches").doc(MATCH), {
    player1Id: PA, player2Id: PB, mode: "ranked", status: "pending",
    createdAt: FieldValue.serverTimestamp(),
  });
  await batch.commit();
}

async function cleanup() {
  // Restore the config EXACTLY as found (gated off), whatever happened.
  try {
    if (originalConfig) {
      await db.collection("config").doc("abilities").set(originalConfig);
    } else {
      await setEnabled(false);
    }
  } catch (_) { /* best effort */ }
  const dels = [
    db.collection("matches").doc(MATCH),
    db.collection("users").doc(PA),
    db.collection("users").doc(PB),
  ];
  for (const u of [PA, PB]) {
    const ledger = await db.collection("users").doc(u)
        .collection("pointsLedger").get().catch(() => ({docs: []}));
    ledger.docs.forEach((d) => dels.push(d.ref));
    dels.push(db.collection("matchLoadouts").doc(MATCH)
        .collection("players").doc(u));
  }
  await Promise.all(dels.map((r) => r.delete().catch(() => {})));
}

async function run() {
  await seed();
  const tokA = await idToken(PA);
  const interruptCost = DEFAULTS.interrupt.cost;
  const interruptCap = DEFAULTS.interrupt.maxPerMatch;

  // ---- KILL SWITCH: config/abilities.enabled = false ----
  await setEnabled(false);

  await check("OFF: getLoadout reports disabled", async () => {
    const r = await callFn("getLoadout", tokA, {matchId: MATCH});
    assert.strictEqual(r.status, 200, JSON.stringify(r.body));
    assert.strictEqual(r.body.result.enabled, false);
  });

  await check("OFF: purchaseAbility is refused", async () => {
    const r = await callFn("purchaseAbility", tokA,
        {matchId: MATCH, abilityId: "interrupt", requestId: "off-1"});
    // failed-precondition surfaces as HTTP 400 with an error body.
    assert.notStrictEqual(r.status, 200, JSON.stringify(r.body));
  });

  await check("OFF: getMatchAbilities returns zero counts for both", async () => {
    const r = await callFn("getMatchAbilities", tokA, {matchId: MATCH});
    assert.strictEqual(r.status, 200, JSON.stringify(r.body));
    assert.strictEqual(r.body.result.enabled, false);
    const p = r.body.result.players;
    assert.strictEqual(p[PA].interrupt, 0, "pA seeded 0 interrupts while OFF");
    assert.strictEqual(p[PB].interrupt, 0, "pB seeded 0 interrupts while OFF");
  });

  // ---- ON: config/abilities.enabled = true ----
  await setEnabled(true);

  await check("ON: getLoadout offers the catalog with costs", async () => {
    const r = await callFn("getLoadout", tokA, {matchId: MATCH});
    assert.strictEqual(r.status, 200, JSON.stringify(r.body));
    assert.strictEqual(r.body.result.enabled, true);
    const int = r.body.result.abilities.find((a) => a.id === "interrupt");
    assert.ok(int, "interrupt offered");
    assert.strictEqual(int.cost, interruptCost);
  });

  let balAfterOne;
  await check("ON: buying interrupt spends points", async () => {
    const r = await callFn("purchaseAbility", tokA,
        {matchId: MATCH, abilityId: "interrupt", requestId: "buy-1"});
    assert.strictEqual(r.status, 200, JSON.stringify(r.body));
    assert.strictEqual(r.body.result.ok, true);
    assert.strictEqual(r.body.result.bought, 1);
    balAfterOne = r.body.result.balance;
    assert.strictEqual(balAfterOne, 5000 - interruptCost);
  });

  await check("ON: repeating the requestId is an idempotent no-op", async () => {
    const r = await callFn("purchaseAbility", tokA,
        {matchId: MATCH, abilityId: "interrupt", requestId: "buy-1"});
    assert.strictEqual(r.status, 200, JSON.stringify(r.body));
    assert.strictEqual(r.body.result.duplicate, true);
    assert.strictEqual(r.body.result.bought, 1, "still 1, not double-charged");
    const u = (await db.collection("users").doc(PA).get()).data();
    assert.strictEqual(u.pointsBalance, balAfterOne, "balance unchanged");
  });

  await check("ON: the per-match cap is enforced", async () => {
    // pA is not a subscriber, so free=0; buy up to the cap, then refuse.
    for (let i = 2; i <= interruptCap; i++) {
      const r = await callFn("purchaseAbility", tokA,
          {matchId: MATCH, abilityId: "interrupt", requestId: `buy-${i}`});
      assert.strictEqual(r.status, 200, JSON.stringify(r.body));
      assert.strictEqual(r.body.result.bought, i);
    }
    const over = await callFn("purchaseAbility", tokA,
        {matchId: MATCH, abilityId: "interrupt", requestId: "buy-over"});
    assert.notStrictEqual(over.status, 200, "over the cap is refused");
  });

  await check("ON: getMatchAbilities seeds the buyer, not the opponent", async () => {
    const r = await callFn("getMatchAbilities", tokA, {matchId: MATCH});
    assert.strictEqual(r.status, 200, JSON.stringify(r.body));
    assert.strictEqual(r.body.result.players[PA].interrupt, interruptCap);
    assert.strictEqual(r.body.result.players[PB].interrupt, 0);
  });

  // ---- KILL SWITCH over purchased abilities: OFF neutralises them ----
  await setEnabled(false);
  await check("flipping OFF zeroes even already-bought abilities", async () => {
    const r = await callFn("getMatchAbilities", tokA, {matchId: MATCH});
    assert.strictEqual(r.status, 200, JSON.stringify(r.body));
    assert.strictEqual(r.body.result.enabled, false);
    assert.strictEqual(r.body.result.players[PA].interrupt, 0,
        "a player who BOUGHT interrupts seeds 0 once the feature is off");
  });
}

run()
    .then(() => console.log(`\n${passed} passed`))
    .catch((e) => {
      console.error("FAILED:", e.message);
      process.exitCode = 1;
    })
    .finally(cleanup);
