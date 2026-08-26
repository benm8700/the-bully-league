/**
 * Local tests for the Laugh Meter (functions/laughMeter.js).
 * Runs with `node test/laughMeter.test.js`.
 *
 * As of the XP ladder (2026-08-25) the meter fills by career XP toward the
 * next earned title, not by the hidden Elo rating. The two things worth
 * pinning hardest are that it never leaks the hidden XP thresholds, and
 * that the fill honestly tracks XP within the current title's band -
 * including the two ends of the ladder, where there is no numeric "next".
 */

const assert = require("assert");
const {laughMeter, GOAT_STATE, CONTENDER_STATE, CLIMBING_STATE} =
  require("../laughMeter");
const {XP_TIERS, GOAT_TITLE} = require("../rating");

let passed = 0;
function test(name, fn) {
  try {
    fn();
    passed++;
  } catch (e) {
    console.error(`FAIL: ${name}\n  ${e.message}`);
    process.exitCode = 1;
  }
}

const tier = (i) => XP_TIERS[i];

// --- the fill tracks XP within the current band -------------------------

test("the bar starts near empty just after promoting into a title", () => {
  const m = laughMeter({rankTitle: tier(1).title, points: tier(1).minXp});
  assert.strictEqual(m.state, CLIMBING_STATE);
  assert.strictEqual(m.nextTitle, tier(2).title);
  assert.ok(m.fill < 0.05, `bar should be near empty, was ${m.fill}`);
});

test("the bar is near full just before the next title", () => {
  const m = laughMeter({rankTitle: tier(1).title, points: tier(2).minXp - 1});
  assert.ok(m.fill > 0.9, `bar should be near full, was ${m.fill}`);
});

test("halfway through a band reads about half full", () => {
  const mid = Math.round((tier(3).minXp + tier(4).minXp) / 2);
  const m = laughMeter({rankTitle: tier(3).title, points: mid});
  assert.ok(m.fill > 0.4 && m.fill < 0.6, `expected ~0.5, got ${m.fill}`);
});

// --- the thresholds stay hidden -----------------------------------------

test("THE CAPTION NEVER LEAKS AN XP NUMBER", () => {
  // The hidden-criteria decision is explicit that the exact thresholds are
  // not shown. A caption reading "180 XP to go" would hand them over one
  // match at a time.
  for (let i = 0; i < XP_TIERS.length; i++) {
    for (const xp of [0, 40, 300, 1500, 4999, 9000]) {
      const m = laughMeter({rankTitle: tier(i).title, points: xp});
      assert.ok(!/\d{3,}/.test(m.caption),
          `caption leaked an XP-sized number: ${m.caption}`);
    }
  }
});

test("the caption is qualitative as the bar fills", () => {
  const at = (xp) => laughMeter({rankTitle: tier(4).title, points: xp}).caption;
  assert.notStrictEqual(at(tier(4).minXp), at(tier(5).minXp - 1));
});

// --- the ends of the ladder ---------------------------------------------

test("GOAT SHOWS NO PROGRESS, because there is nothing above it", () => {
  const m = laughMeter({rankTitle: GOAT_TITLE, points: 9000});
  assert.strictEqual(m.state, GOAT_STATE);
  assert.strictEqual(m.fill, 1);
  assert.strictEqual(m.nextTitle, null);
});

test("...and its copy is about HOLDING the slot, not climbing", () => {
  // GOAT is a live top-five position: a player can be demoted without ever
  // losing, purely because somebody else's hidden rating rose. Copy about
  // progress would be lying about what the rank is.
  const m = laughMeter({rankTitle: GOAT_TITLE, points: 9000});
  assert.ok(!/climb|halfway|more ranked/i.test(m.caption), m.caption);
});

test("HALL OF FAMER DOES NOT FAKE PROGRESS TOWARD GOAT", () => {
  // GOAT cannot be reached by crossing an XP number - it is top-five by
  // hidden skill - so a filling bar would invent a threshold that does not
  // exist. The bar is full and the copy points at out-battling a GOAT.
  const top = XP_TIERS[XP_TIERS.length - 1];
  const m = laughMeter({rankTitle: top.title, points: top.minXp + 5000});
  assert.strictEqual(m.state, CONTENDER_STATE);
  assert.strictEqual(m.nextTitle, GOAT_TITLE);
  assert.strictEqual(m.fill, 1);
  assert.ok(/top \d/i.test(m.caption), m.caption);
});

test("the bottom of the ladder shows a real climb from zero XP", () => {
  const m = laughMeter({rankTitle: tier(0).title, points: 0});
  assert.strictEqual(m.state, CLIMBING_STATE);
  assert.strictEqual(m.nextTitle, tier(1).title);
  assert.strictEqual(m.fill, 0);
});

// --- title derived from XP when it has not been written -----------------

test("a missing title is derived from XP rather than erroring", () => {
  // Every account predating the stored title reads this way; deriving from
  // XP keeps the meter honest instead of pinning everyone to the floor.
  const m = laughMeter({points: tier(4).minXp});
  assert.strictEqual(m.title, tier(4).title);
  assert.strictEqual(m.state, CLIMBING_STATE);
});

// --- missing and hostile data -------------------------------------------

test("A BRAND NEW ACCOUNT gets a sensible meter, not an error", () => {
  for (const u of [undefined, null, {}, {rankTitle: "Nonsense Rank"}]) {
    const m = laughMeter(u);
    assert.ok(Number.isFinite(m.fill), JSON.stringify(m));
    assert.ok(m.fill >= 0 && m.fill <= 1);
    assert.ok(typeof m.caption === "string" && m.caption.length > 0);
  }
});

test("junk XP falls back to zero rather than to NaN", () => {
  const junk = laughMeter({rankTitle: tier(2).title, points: "lots"});
  assert.ok(Number.isFinite(junk.fill) && junk.fill >= 0 && junk.fill <= 1);
});

test("the fill is always a clamped fraction, whatever goes in", () => {
  for (const xp of [-9999, 0, 1e9, NaN, "x"]) {
    for (let i = 0; i < XP_TIERS.length; i++) {
      const m = laughMeter({rankTitle: tier(i).title, points: xp});
      assert.ok(m.fill >= 0 && m.fill <= 1,
          `fill ${m.fill} for ${xp} at ${tier(i).title}`);
    }
  }
});

test("every tier has a next title except the last, which points at GOAT", () => {
  for (let i = 0; i < XP_TIERS.length; i++) {
    const m = laughMeter({rankTitle: tier(i).title, points: tier(i).minXp});
    if (i < XP_TIERS.length - 1) {
      assert.strictEqual(m.nextTitle, tier(i + 1).title);
    } else {
      assert.strictEqual(m.nextTitle, GOAT_TITLE);
    }
  }
});

console.log(`laughMeter: ${passed} checks passed`);
