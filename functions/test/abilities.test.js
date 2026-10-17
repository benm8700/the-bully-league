const assert = require("assert");
const {
  resolveAbilityConfig, purchasePlan, freeAllowance, isUnlocked,
  DEFAULTS, ABILITY_CATALOG,
} = require("../abilities");

let passed = 0;
function check(name, fn) { fn(); passed++; console.log(`  ok - ${name}`); }

const DAY = 86400000;
const now = Date.now();

console.log("abilities - economy layer");

check("config falls back to defaults when empty", () => {
  const c = resolveAbilityConfig(undefined);
  assert.strictEqual(c.enabled, true);
  assert.strictEqual(c.interrupt.cost, DEFAULTS.interrupt.cost);
  assert.strictEqual(c.interrupt.subFree, DEFAULTS.interrupt.subFree);
  assert.strictEqual(c.interrupt.maxPerMatch, DEFAULTS.interrupt.maxPerMatch);
});

check("every catalog ability resolves config + has a deploy surface", () => {
  const c = resolveAbilityConfig(undefined);
  const ids = Object.keys(ABILITY_CATALOG);
  assert.deepStrictEqual(ids.sort(),
      ["extend", "fart", "goFirst", "goSecond", "instantInterrupt", "interrupt",
        "skipWarmup", "tomato"].sort());
  for (const id of ids) {
    assert.ok(c[id], `${id} resolves`);
    assert.strictEqual(typeof c[id].cost, "number");
    assert.strictEqual(typeof c[id].unlockXp, "number");
    assert.ok(["controls", "bar", "prematch", "warmup"].includes(ABILITY_CATALOG[id].deploy),
        `${id} has a valid deploy surface`);
  }
  assert.strictEqual(c.goFirst.maxPerMatch, 1, "go-first is one-per-match");
  assert.strictEqual(c.skipWarmup.maxPerMatch, 1, "skip-warmup is one-per-match");
});

check("unlockXp overrides are bounds-checked", () => {
  assert.strictEqual(resolveAbilityConfig({tomato: {unlockXp: 25}}).tomato.unlockXp, 25);
  // Negative/garbage -> the default.
  assert.strictEqual(
      resolveAbilityConfig({tomato: {unlockXp: -10}}).tomato.unlockXp,
      DEFAULTS.tomato.unlockXp);
});

check("rank gate: locked below unlockXp, unlocked at/above it (every mode)", () => {
  const interrupt = resolveAbilityConfig(undefined).interrupt; // unlockXp 1200
  assert.strictEqual(isUnlocked({points: 0}, interrupt), false);
  assert.strictEqual(isUnlocked({points: 1199}, interrupt), false);
  assert.strictEqual(isUnlocked({points: 1200}, interrupt), true);
  assert.strictEqual(isUnlocked({points: 9999}, interrupt), true);
  // Missing/garbage XP reads as 0 (locked), never crashes.
  assert.strictEqual(isUnlocked({}, interrupt), false);
});

check("friend battles do NOT unlock locked abilities (rank gate still binds)", () => {
  // Reversed 2026-10-16: friend mode no longer auto-unlocks. The gate is
  // mode-independent; friend mode only makes UNLOCKED ones free (below).
  const interrupt = resolveAbilityConfig(undefined).interrupt; // unlockXp 1200
  assert.strictEqual(isUnlocked({points: 0}, interrupt), false);
  assert.strictEqual(isUnlocked({points: 2000}, interrupt), true);
});

check("friend mode frees the per-match stock (for UNLOCKED abilities)", () => {
  const cfg = resolveAbilityConfig(undefined).tomato; // max 5
  assert.strictEqual(freeAllowance({points: 0}, now, cfg, 14, true), cfg.maxPerMatch);
  // Ranked, lapsed (past trial, no sub) -> no free allowance.
  assert.strictEqual(
      freeAllowance({createdAt: now - 100 * DAY}, now, cfg, 14, false), 0);
});

check("config overrides are applied and bounds-checked", () => {
  const c = resolveAbilityConfig({interrupt: {cost: 250, subFree: 2, maxPerMatch: 5}});
  assert.strictEqual(c.interrupt.cost, 250);
  assert.strictEqual(c.interrupt.subFree, 2);
  assert.strictEqual(c.interrupt.maxPerMatch, 5);
  const bad = resolveAbilityConfig({interrupt: {cost: -5, subFree: 99}});
  assert.strictEqual(bad.interrupt.cost, DEFAULTS.interrupt.cost, "bad cost -> default");
  assert.strictEqual(bad.interrupt.subFree, DEFAULTS.interrupt.subFree, "out-of-range -> default");
});

check("disabled flags are respected", () => {
  assert.strictEqual(resolveAbilityConfig({enabled: false}).enabled, false);
  assert.strictEqual(
      resolveAbilityConfig({interrupt: {enabled: false}}).interrupt.enabled, false);
});

check("purchasePlan allows a buy under the cap and affordable", () => {
  const p = purchasePlan({free: 0, bought: 0, maxPerMatch: 3, cost: 500, balance: 500});
  assert.strictEqual(p.ok, true);
  assert.strictEqual(p.cost, 500);
  assert.strictEqual(p.newBought, 1);
});

check("the free allowance counts toward the per-match cap", () => {
  // subscriber: 1 free + 2 bought = 3 = cap, so no more
  const p = purchasePlan({free: 1, bought: 2, maxPerMatch: 3, cost: 500, balance: 9999});
  assert.strictEqual(p.ok, false);
  assert.strictEqual(p.reason, "max");
});

check("purchasePlan refuses when the balance can't afford it", () => {
  const p = purchasePlan({free: 0, bought: 0, maxPerMatch: 3, cost: 500, balance: 100});
  assert.strictEqual(p.ok, false);
  assert.strictEqual(p.reason, "insufficient");
});

check("free allowance: subscriber & trial get subFree, lapsed gets 0", () => {
  const cfg = {subFree: 1};
  assert.strictEqual(freeAllowance({subscription: {active: true}}, now, cfg, 14), 1);
  assert.strictEqual(freeAllowance({createdAt: now - 100 * DAY}, now, cfg, 14), 0);
  assert.strictEqual(freeAllowance({createdAt: now - 2 * DAY}, now, cfg, 14), 1);
});

console.log(`\n${passed} passed`);
