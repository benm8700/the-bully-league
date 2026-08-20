/**
 * Local tests for the Laugh Meter (functions/laughMeter.js).
 * Runs with `node test/laughMeter.test.js`.
 *
 * The two things worth pinning hardest are that it never leaks the hidden
 * thresholds, and that it never shows a FULL bar to somebody who is not
 * about to promote - a gauge that sits at 100% while nothing happens
 * reads as broken, and it is the natural failure of showing rating alone
 * when promotion also needs a minimum number of matches.
 */

const assert = require("assert");
const {laughMeter, GOAT_STATE, CONTENDER_STATE, CLIMBING_STATE} =
  require("../laughMeter");
const {RANK_TIERS, GOAT_TITLE, STARTING_RATING} = require("../rating");

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

const tier = (i) => RANK_TIERS[i];

// --- the binding constraint ---------------------------------------------

test("THE MATCHES REQUIREMENT CAN HOLD THE BAR BACK, not just rating", () => {
  // The failure this prevents: a player with the rating for the next tier
  // but not the matches would see a full bar and never promote, which
  // reads as a broken gauge rather than a missing requirement.
  const m = laughMeter({
    rankTitle: tier(1).title,
    rating: tier(2).minRating, // rating requirement already met
    rankedMatchesPlayed: tier(1).minMatches, // but no matches since
  });
  assert.ok(m.fill < 1, `bar was full at ${m.fill}`);
  assert.strictEqual(m.binding, "matches");
});

test("...and it says how many battles are left, because that is actionable",
    () => {
      const m = laughMeter({
        rankTitle: tier(1).title,
        rating: tier(2).minRating,
        rankedMatchesPlayed: tier(2).minMatches - 2,
      });
      assert.strictEqual(m.matchesRemaining, 2);
      assert.ok(/2 more ranked battles/.test(m.caption), m.caption);
    });

test("rating binds when matches are already comfortable", () => {
  const m = laughMeter({
    rankTitle: tier(1).title,
    rating: tier(1).minRating + 1,
    rankedMatchesPlayed: tier(2).minMatches + 50,
  });
  assert.strictEqual(m.binding, "rating");
  assert.ok(m.fill < 0.3, String(m.fill));
});

test("a match count remaining is never reported when rating is the "
    + "constraint", () => {
  // Otherwise it reads as "play two more and you promote", which is false.
  const m = laughMeter({
    rankTitle: tier(1).title,
    rating: tier(1).minRating,
    rankedMatchesPlayed: tier(2).minMatches + 5,
  });
  assert.strictEqual(m.matchesRemaining, 0);
});

// --- the thresholds stay hidden -----------------------------------------

test("THE CAPTION NEVER LEAKS A RATING NUMBER", () => {
  // The hidden-criteria decision is explicit that the exact thresholds
  // are not shown. A caption reading "38 rating to go" would hand them
  // over one match at a time.
  for (let i = 0; i < RANK_TIERS.length - 1; i++) {
    for (const r of [0, 500, 1100, 1500, 2000]) {
      const m = laughMeter({
        rankTitle: tier(i).title, rating: r,
        rankedMatchesPlayed: 999,
      });
      assert.ok(!/\d{3,}/.test(m.caption),
          `caption leaked a rating-sized number: ${m.caption}`);
    }
  }
});

test("the caption is qualitative as the bar fills", () => {
  const at = (r) => laughMeter({
    rankTitle: tier(4).title, rating: r, rankedMatchesPlayed: 999,
  }).caption;
  assert.notStrictEqual(at(tier(4).minRating), at(tier(5).minRating - 1));
});

// --- the ends of the ladder ---------------------------------------------

test("GOAT SHOWS NO PROGRESS, because there is nothing above it", () => {
  const m = laughMeter({rankTitle: GOAT_TITLE, rating: 2000,
    rankedMatchesPlayed: 99});
  assert.strictEqual(m.state, GOAT_STATE);
  assert.strictEqual(m.fill, 1);
  assert.strictEqual(m.nextTitle, null);
});

test("...and its copy is about HOLDING the slot, not climbing", () => {
  // GOAT is a live top-five position: a player can be demoted without
  // ever losing, purely because somebody else rose. Copy that talked
  // about progress would be lying about what the rank is.
  const m = laughMeter({rankTitle: GOAT_TITLE, rating: 2000,
    rankedMatchesPlayed: 99});
  assert.ok(!/climb|halfway|more ranked/i.test(m.caption), m.caption);
});

test("HALL OF FAMER DOES NOT FAKE PROGRESS TOWARD GOAT", () => {
  // GOAT cannot be reached by crossing a number, so a filling bar would
  // be inventing a threshold that does not exist.
  const top = RANK_TIERS[RANK_TIERS.length - 1];
  const m = laughMeter({rankTitle: top.title, rating: 5000,
    rankedMatchesPlayed: 999});
  assert.strictEqual(m.state, CONTENDER_STATE);
  assert.strictEqual(m.nextTitle, GOAT_TITLE);
  assert.strictEqual(m.binding, "leaderboard");
  assert.ok(/top \d/i.test(m.caption), m.caption);
});

test("the bottom of the ladder still shows a real climb", () => {
  const m = laughMeter({rankTitle: tier(0).title, rating: 900,
    rankedMatchesPlayed: 1});
  assert.strictEqual(m.state, CLIMBING_STATE);
  assert.strictEqual(m.nextTitle, tier(1).title);
});

// --- missing and hostile data -------------------------------------------

test("A BRAND NEW ACCOUNT gets a sensible meter, not an error", () => {
  // Every account predating a field reads this way, and this project has
  // met the missing-field trap repeatedly.
  for (const u of [undefined, null, {}, {rankTitle: "Nonsense Rank"}]) {
    const m = laughMeter(u);
    assert.ok(Number.isFinite(m.fill), JSON.stringify(m));
    assert.ok(m.fill >= 0 && m.fill <= 1);
    assert.ok(typeof m.caption === "string" && m.caption.length > 0);
  }
});

test("a junk rating falls back to the starting one rather than to zero", () => {
  // Zero would show every legacy account an empty bar and a demoralising
  // caption about being a long way off.
  const junk = laughMeter({rankTitle: tier(4).title, rating: "high",
    rankedMatchesPlayed: 999});
  const real = laughMeter({rankTitle: tier(4).title, rating: STARTING_RATING,
    rankedMatchesPlayed: 999});
  assert.strictEqual(junk.fill, real.fill);
});

test("the fill is always a clamped fraction, whatever goes in", () => {
  for (const r of [-9999, 0, 1e9, NaN]) {
    for (const p of [-5, 0, 1e9, NaN]) {
      for (let i = 0; i < RANK_TIERS.length; i++) {
        const m = laughMeter({rankTitle: tier(i).title, rating: r,
          rankedMatchesPlayed: p});
        assert.ok(m.fill >= 0 && m.fill <= 1,
            `fill ${m.fill} for ${r}/${p} at ${tier(i).title}`);
      }
    }
  }
});

test("every tier has a next title except the last", () => {
  for (let i = 0; i < RANK_TIERS.length; i++) {
    const m = laughMeter({rankTitle: tier(i).title, rating: 1200,
      rankedMatchesPlayed: 10});
    if (i < RANK_TIERS.length - 1) {
      assert.strictEqual(m.nextTitle, tier(i + 1).title);
    } else {
      assert.strictEqual(m.nextTitle, GOAT_TITLE);
    }
  }
});

console.log(`laughMeter: ${passed} checks passed`);
