const assert = require("assert");
const {
  JUDGE_SEAT_DEFAULTS, sanitiseJudgeSeatConfig, votesCastOf,
  judgeSeatEligibility, maxPaidSeats, seatsRemaining, DENY,
} = require("../judgeSeat");
const {selectPanel} = require("../judgePanel");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

console.log("judgeSeat");

const ON = {...JUDGE_SEAT_DEFAULTS, enabled: true};

// --------------------------------------------------------- config bounds
check("enabled is only an explicit true", () => {
  assert.strictEqual(sanitiseJudgeSeatConfig({}).enabled, false);
  assert.strictEqual(sanitiseJudgeSeatConfig({enabled: "yes"}).enabled, false);
  assert.strictEqual(sanitiseJudgeSeatConfig({enabled: true}).enabled, true);
});

check("a bad field falls back per-field, keeping the good ones", () => {
  const c = sanitiseJudgeSeatConfig({price: 750, seats: 9, minVotes: -1});
  assert.strictEqual(c.price, 750); // good, kept
  assert.strictEqual(c.seats, JUDGE_SEAT_DEFAULTS.seats); // 9 > max(2) -> default
  assert.strictEqual(c.minVotes, JUDGE_SEAT_DEFAULTS.minVotes); // negative -> default
});

check("seats is hard-capped at 2 in config bounds", () => {
  assert.strictEqual(sanitiseJudgeSeatConfig({seats: 2}).seats, 2);
  assert.strictEqual(sanitiseJudgeSeatConfig({seats: 3}).seats,
      JUDGE_SEAT_DEFAULTS.seats); // out of bounds -> default
  assert.strictEqual(sanitiseJudgeSeatConfig({seats: 0}).seats, 0);
});

check("a non-object config is all defaults", () => {
  assert.deepStrictEqual(sanitiseJudgeSeatConfig(null), JUDGE_SEAT_DEFAULTS);
});

// --------------------------------------------------------- votes count
check("votesCast tolerates a missing/garbage value", () => {
  assert.strictEqual(votesCastOf({votesCast: 42}), 42);
  assert.strictEqual(votesCastOf({}), 0);
  assert.strictEqual(votesCastOf({votesCast: "x"}), 0);
  assert.strictEqual(votesCastOf({votesCast: -3}), 0);
});

// --------------------------------------------------------- eligibility
check("disabled config blocks everyone", () => {
  const r = judgeSeatEligibility({votesCast: 999}, JUDGE_SEAT_DEFAULTS);
  assert.strictEqual(r.eligible, false);
  assert.strictEqual(r.reason, DENY.disabled);
});

check("a banned account can't buy", () => {
  const r = judgeSeatEligibility(
      {accountStatus: "banned", votesCast: 999}, ON);
  assert.strictEqual(r.eligible, false);
  assert.strictEqual(r.reason, DENY.notActive);
});

check("absent accountStatus counts as active", () => {
  const r = judgeSeatEligibility({votesCast: 10}, ON);
  assert.strictEqual(r.eligible, true);
});

check("too few votes blocks (buyers must be active judges)", () => {
  const r = judgeSeatEligibility({votesCast: 9}, ON); // floor is 10
  assert.strictEqual(r.eligible, false);
  assert.strictEqual(r.reason, DENY.tooFewVotes);
});

check("an active judge over the floor is eligible", () => {
  assert.strictEqual(judgeSeatEligibility({votesCast: 10}, ON).eligible, true);
});

// --------------------------------------------------------- minority math
check("maxPaidSeats never exceeds a minority of the panel", () => {
  assert.strictEqual(maxPaidSeats({...ON, seats: 2}, 5), 2); // 2 of 5 is minority
  assert.strictEqual(maxPaidSeats({...ON, seats: 2}, 3), 1); // floor((3-1)/2)
  assert.strictEqual(maxPaidSeats({...ON, seats: 0}, 5), 0);
});

check("seatsRemaining counts down from the minority cap", () => {
  assert.strictEqual(seatsRemaining(0, {...ON, seats: 2}, 5), 2);
  assert.strictEqual(seatsRemaining(1, {...ON, seats: 2}, 5), 1);
  assert.strictEqual(seatsRemaining(2, {...ON, seats: 2}, 5), 0);
  assert.strictEqual(seatsRemaining(5, {...ON, seats: 2}, 5), 0); // never negative
});

// --------------------------------------------------- selectPanel integration
check("paid seats sit AFTER hand-picks and BEFORE the pool", () => {
  const {judges} = selectPanel({
    handPicked: ["founder"],
    paidSeats: ["buyer1"],
    paidSeatCap: 2,
    rankedPool: ["pool1", "pool2", "pool3", "pool4"],
    panelSize: 5,
  });
  assert.deepStrictEqual(judges,
      ["founder", "buyer1", "pool1", "pool2", "pool3"]);
});

check("bought seats are capped to a minority even if more bought", () => {
  // 3 buyers offered, but floor((5-1)/2)=2 is the hard ceiling.
  const {judges} = selectPanel({
    paidSeats: ["b1", "b2", "b3"],
    paidSeatCap: 2,
    rankedPool: ["p1", "p2", "p3", "p4", "p5"],
    panelSize: 5,
  });
  const paidOnPanel = judges.filter((u) => u.startsWith("b"));
  assert.deepStrictEqual(paidOnPanel, ["b1", "b2"]); // b3 dropped
  assert.strictEqual(judges.length, 5);
});

check("paidSeatCap 0 seats no buyers", () => {
  const {judges} = selectPanel({
    paidSeats: ["b1", "b2"],
    paidSeatCap: 0,
    rankedPool: ["p1", "p2", "p3", "p4", "p5"],
    panelSize: 5,
  });
  assert.ok(!judges.some((u) => u.startsWith("b")));
});

check("a paid buyer who is a FINALIST is never seated", () => {
  const {judges} = selectPanel({
    paidSeats: ["buyer1"],
    paidSeatCap: 2,
    finalists: ["buyer1"], // they qualified -> conflict of interest
    rankedPool: ["p1", "p2", "p3", "p4", "p5"],
    panelSize: 5,
  });
  assert.ok(!judges.includes("buyer1")); // wiring refunds them
});

check("a banned paid buyer (in exclude) is never seated", () => {
  const {judges} = selectPanel({
    paidSeats: ["buyer1"],
    paidSeatCap: 2,
    exclude: ["buyer1"],
    rankedPool: ["p1", "p2", "p3", "p4", "p5"],
    panelSize: 5,
  });
  assert.ok(!judges.includes("buyer1"));
});

check("a paid buyer already hand-picked isn't double-seated", () => {
  const {judges} = selectPanel({
    handPicked: ["x"],
    paidSeats: ["x"],
    paidSeatCap: 2,
    rankedPool: ["p1", "p2", "p3", "p4"],
    panelSize: 5,
  });
  assert.strictEqual(judges.filter((u) => u === "x").length, 1);
  assert.strictEqual(judges.length, 5);
});

check("no paid args leaves the panel exactly as before", () => {
  const {judges} = selectPanel({
    handPicked: ["founder"],
    rankedPool: ["p1", "p2", "p3", "p4", "p5"],
    panelSize: 5,
  });
  assert.deepStrictEqual(judges, ["founder", "p1", "p2", "p3", "p4"]);
});

console.log(`\n${passed} checks passed`);
