const assert = require("assert");
const {
  resolveClipGrant, clipDeliverable, spendableBalance,
  DENY, DEFAULT_CLIP_POINTS_PRICE,
} = require("../clipGrants");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

const NOW = 1_700_000_000_000;
const PRICE = 250;
const ME = "me";
const THEM = "them";

const matchOf = (extra = {}) => ({
  player1Id: ME,
  player2Id: THEM,
  status: "completed",
  // Voting closed a day ago, so the objection window is shut.
  completedAt: {toMillis: () => NOW - 48 * 60 * 60 * 1000},
  voteFinalized: true,
  highlight: {captioned: true},
  ...extra,
});

const grant = (over = {}) => resolveClipGrant({
  user: {points: 1000, pointsBalance: 1000},
  match: matchOf(),
  uid: ME,
  source: "points",
  price: PRICE,
  entitlement: {state: "lapsed"},
  ...over,
});

console.log("clipGrants");

// ------------------------------------------------------- who may claim
check("SAFETY: a non-participant is refused, whatever they offer", () => {
  for (const source of ["subscription", "points", "purchase"]) {
    const v = grant({uid: "stranger", source,
      entitlement: {state: "subscriber"}, user: {pointsBalance: 99999}});
    assert.strictEqual(v.allowed, false);
    assert.strictEqual(v.reason, DENY.notParticipant);
  }
});

check("either participant may claim", () => {
  assert.strictEqual(grant({uid: ME}).allowed, true);
  assert.strictEqual(grant({uid: THEM}).allowed, true);
});

check("an unfinished battle cannot be claimed", () => {
  const v = grant({match: matchOf({status: "pending"})});
  assert.strictEqual(v.allowed, false);
  assert.strictEqual(v.reason, DENY.matchNotReady);
});

check("an unknown source is refused rather than treated as free", () => {
  const v = grant({source: "free-please"});
  assert.strictEqual(v.allowed, false);
  assert.strictEqual(v.reason, DENY.unknownSource);
});

// ---------------------------------------------------------- by source
check("a subscriber pays nothing", () => {
  const v = grant({source: "subscription", entitlement: {state: "subscriber"}});
  assert.strictEqual(v.allowed, true);
  assert.strictEqual(v.cost, 0);
});

check("a trial user pays nothing either - the trial is full access", () => {
  const v = grant({source: "subscription", entitlement: {state: "trial"}});
  assert.strictEqual(v.allowed, true);
});

check("a lapsed user cannot claim via subscription", () => {
  const v = grant({source: "subscription", entitlement: {state: "lapsed"}});
  assert.strictEqual(v.allowed, false);
  assert.strictEqual(v.reason, DENY.subscriptionRequired);
});

check("points buy a clip when the balance covers it", () => {
  const v = grant({user: {pointsBalance: PRICE}});
  assert.strictEqual(v.allowed, true);
  assert.strictEqual(v.cost, PRICE);
});

check("one point short is refused, and says so", () => {
  const v = grant({user: {pointsBalance: PRICE - 1}});
  assert.strictEqual(v.allowed, false);
  assert.strictEqual(v.reason, DENY.insufficientPoints);
  assert.ok(v.message.includes(String(PRICE)));
});

check("purchase is refused explicitly - no IAP exists yet", () => {
  const v = grant({source: "purchase"});
  assert.strictEqual(v.allowed, false);
  assert.strictEqual(v.reason, DENY.paymentUnavailable);
});

// ------------------------------------------------------- double-charge
check("A REPEAT TAP NEVER CHARGES TWICE", () => {
  const owned = matchOf({clipGrants: {[ME]: {source: "points", cost: PRICE}}});
  const v = grant({match: owned});
  assert.strictEqual(v.allowed, false);
  assert.strictEqual(v.reason, DENY.alreadyGranted);
  assert.strictEqual(v.cost, 0);
});

check("one player's grant does not give the other player theirs", () => {
  const owned = matchOf({clipGrants: {[THEM]: {source: "points"}}});
  assert.strictEqual(grant({match: owned, uid: ME}).allowed, true);
});

// ------------------------------------------------- career vs balance
check("MIGRATION: a legacy account's balance is its career total", () => {
  // Reading a missing balance as zero would confiscate every point earned
  // before spending existed - the same missing-field trap as
  // accountStatus and createdAt.
  assert.strictEqual(spendableBalance({points: 800}), 800);
  assert.strictEqual(grant({user: {points: 800}}).allowed, true);
});

check("an explicit balance wins over the career total", () => {
  // Someone who has earned 800 lifetime and spent 700 has 100 to spend,
  // not 800 - otherwise spending would be free.
  assert.strictEqual(spendableBalance({points: 800, pointsBalance: 100}), 100);
  assert.strictEqual(grant({user: {points: 800, pointsBalance: 100}}).allowed, false);
});

check("a negative balance can never be spent from", () => {
  assert.strictEqual(spendableBalance({pointsBalance: -50}), 0);
});

// -------------------------------------------------------- delivery
check("THE RULE: nothing is delivered while the objection window is open", () => {
  const open = matchOf({
    completedAt: {toMillis: () => NOW - 60 * 1000},
    voteFinalized: false,
  });
  const d = clipDeliverable(open, NOW);
  assert.strictEqual(d.deliverable, false);
  assert.strictEqual(d.reason, "window-open");
  // Not refundable: nothing has gone wrong, it is simply not time yet.
  assert.strictEqual(d.refundable, false);
});

check("an objection blocks delivery AND is refundable", () => {
  const objected = matchOf({objections: {[THEM]: {channel: "preference"}}});
  const d = clipDeliverable(objected, NOW);
  assert.strictEqual(d.deliverable, false);
  assert.strictEqual(d.reason, "objected");
  assert.strictEqual(d.refundable, true, "a buyer must be made whole");
});

check("a clip still rendering is not deliverable, and not refundable", () => {
  const d = clipDeliverable(matchOf({highlight: {captioned: false}}), NOW);
  assert.strictEqual(d.deliverable, false);
  assert.strictEqual(d.reason, "rendering");
  assert.strictEqual(d.refundable, false);
});

check("past the window, captioned and unobjected, it is deliverable", () => {
  assert.strictEqual(clipDeliverable(matchOf(), NOW).deliverable, true);
});

check("the default price is sane", () => {
  assert.ok(DEFAULT_CLIP_POINTS_PRICE > 0);
  // At the default rates (10/match, 25/win, 5/vote) a clip should be a
  // real goal but not a month of grinding.
  assert.ok(DEFAULT_CLIP_POINTS_PRICE <= 1000,
      "a sink nobody can reach is not a sink");
});

console.log(`\n${passed} checks passed.`);
