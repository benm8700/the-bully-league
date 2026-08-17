const assert = require("assert");
const {careerStanding, CAREER_TITLES} = require("../careerTrack");
const {RANK_TIERS, GOAT_TITLE} = require("../rating");
const {DEFAULTS: POINT_RATES} = require("../points");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

console.log("careerTrack");

check("a brand-new account already has a title, not a blank", () => {
  // An empty slot where a title should be reads as broken, and the first
  // impression of a progression track should be that it exists.
  const s = careerStanding({});
  assert.strictEqual(s.title, "Walk-In");
  assert.strictEqual(s.tier, 0);
  assert.strictEqual(s.points, 0);
});

check("a title is earned exactly AT its threshold, not one past it", () => {
  const at = careerStanding({points: 250});
  assert.strictEqual(at.title, "Two-Drink Minimum");
  const justUnder = careerStanding({points: 249});
  assert.strictEqual(justUnder.title, "Walk-In");
});

check("THE POINT: spending never demotes anyone", () => {
  // Career standing reads the career total, never the spendable balance.
  // If it read the balance, buying a clip would cost someone a title -
  // turning the permanent ladder into a second rating, which is the exact
  // thing the two-number split exists to prevent.
  const spender = {points: 3000, pointsBalance: 0};
  assert.strictEqual(careerStanding(spender).title, "Every Night");
});

check("progress runs 0..1 through the current band", () => {
  const start = careerStanding({points: 750});
  assert.ok(Math.abs(start.progress - 0) < 1e-9, `got ${start.progress}`);
  const halfway = careerStanding({points: (750 + 1500) / 2});
  assert.ok(Math.abs(halfway.progress - 0.5) < 1e-9, `got ${halfway.progress}`);
});

check("the top title has no next, and no progress to fill", () => {
  const top = careerStanding({points: 999999});
  assert.strictEqual(top.title, CAREER_TITLES[CAREER_TITLES.length - 1].title);
  assert.strictEqual(top.nextTitle, null);
  assert.strictEqual(top.pointsToNext, null);
  assert.strictEqual(top.progress, null);
});

check("pointsToNext counts down honestly", () => {
  const s = careerStanding({points: 700});
  assert.strictEqual(s.nextTitle, "Road Dog");
  assert.strictEqual(s.pointsToNext, 50);
});

check("garbage and negative balances degrade to zero, not to NaN", () => {
  for (const points of [null, undefined, "lots", NaN, -500]) {
    const s = careerStanding({points});
    assert.strictEqual(s.points, 0, `points=${points}`);
    assert.strictEqual(s.tier, 0);
  }
});

check("thresholds only ever increase", () => {
  for (let i = 1; i < CAREER_TITLES.length; i++) {
    assert.ok(CAREER_TITLES[i].threshold > CAREER_TITLES[i - 1].threshold,
        `${CAREER_TITLES[i].title} does not exceed ${CAREER_TITLES[i - 1].title}`);
  }
});

check("NO CAREER TITLE COLLIDES WITH A RANK TITLE", () => {
  // The two ladders answer different questions - how good you are now
  // versus everything you have ever done - and sharing a name between them
  // would make both meaningless. "Regular" and "Legend" are rank titles,
  // so they can never be career ones.
  const rankTitles = new Set([...RANK_TIERS.map((t) => t.title), GOAT_TITLE]);
  for (const {title} of CAREER_TITLES) {
    assert.ok(!rankTitles.has(title),
        `"${title}" is already a rank title - the two ladders must not share names`);
  }
});

check("the first title is reachable in a session or two", () => {
  // A progression track nobody sees move is not a progression track.
  const perMatch = POINT_RATES.matchPlayed + POINT_RATES.matchWon;
  const matchesToSecondTitle = CAREER_TITLES[1].threshold / perMatch;
  assert.ok(matchesToSecondTitle <= 15,
      `${matchesToSecondTitle.toFixed(1)} wins to the second title is too far`);
});

check("the top title is a long haul, not a fortnight", () => {
  const perMatch = POINT_RATES.matchPlayed + POINT_RATES.matchWon;
  const top = CAREER_TITLES[CAREER_TITLES.length - 1].threshold;
  assert.ok(top / perMatch >= 200,
      "the last title should represent real mileage");
});

console.log(`\n${passed} checks passed.`);
