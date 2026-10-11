const assert = require("assert");
const {
  resolveAbilityConfig, purchasePlan, freeAllowance, DEFAULTS, ABILITY_CATALOG,
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
      ["extend", "goFirst", "instantInterrupt", "interrupt", "tomato"].sort());
  for (const id of ids) {
    assert.ok(c[id], `${id} resolves`);
    assert.strictEqual(typeof c[id].cost, "number");
    assert.ok(["controls", "bar", "prematch"].includes(ABILITY_CATALOG[id].deploy),
        `${id} has a valid deploy surface`);
  }
  assert.strictEqual(c.goFirst.maxPerMatch, 1, "go-first is one-per-match");
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
