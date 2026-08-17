const assert = require("assert");
const {
  resolveClipGrant, clipDeliverable, spendableBalance,
  DENY, DEFAULT_CLIP_POINTS_PRICE, hasUsedFreeClip,
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

// freeClipUsed is set here deliberately: everything below tests the PAID
// path, and the first clip being free would otherwise make every one of
// these cost nothing and assert nothing. The free clip has its own
// section at the end.
const grant = (over = {}) => resolveClipGrant({
  user: {points: 1000, pointsBalance: 1000, freeClipUsed: true},
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
  const v = grant({user: {pointsBalance: PRICE, freeClipUsed: true}});
  assert.strictEqual(v.allowed, true);
  assert.strictEqual(v.cost, PRICE);
});

check("one point short is refused, and says so", () => {
  const v = grant({user: {pointsBalance: PRICE - 1, freeClipUsed: true}});
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
  assert.strictEqual(grant({user: {points: 800, freeClipUsed: true}}).allowed, true);
});

check("an explicit balance wins over the career total", () => {
  // Someone who has earned 800 lifetime and spent 700 has 100 to spend,
  // not 800 - otherwise spending would be free.
  assert.strictEqual(spendableBalance({points: 800, pointsBalance: 100}), 100);
  assert.strictEqual(grant({user: {points: 800, pointsBalance: 100, freeClipUsed: true}}).allowed, false);
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

// ------------------------------------------------------ the first free
//
// The first captioned clip is free, and that is a distribution decision
// rather than a generous one: every clip a player posts is acquisition
// nobody paid for, and at 250 points almost nobody in a beta reaches one -
// so with no free clip the app would learn nothing about whether clips
// spread at all.
check("A BRAND-NEW PLAYER'S FIRST CLIP IS FREE, with no points at all", () => {
  const v = grant({user: {}, source: "points"});
  assert.strictEqual(v.allowed, true);
  assert.strictEqual(v.cost, 0);
  assert.strictEqual(v.source, "free");
});

check("MIGRATION: an existing account still has its free clip", () => {
  // Every account predating this has no freeClipUsed field. Reading a
  // missing field as "used" would silently deny the free clip to the
  // entire userbase - the fourth time this project has met that trap,
  // after accountStatus, createdAt and pointsBalance.
  assert.strictEqual(hasUsedFreeClip({}), false);
  assert.strictEqual(hasUsedFreeClip({points: 900, wins: 12}), false);
});

check("only an explicit true counts as used", () => {
  assert.strictEqual(hasUsedFreeClip({freeClipUsed: true}), true);
  assert.strictEqual(hasUsedFreeClip({freeClipUsed: "true"}), false);
  assert.strictEqual(hasUsedFreeClip({freeClipUsed: 1}), false);
});

check("the SECOND clip costs the full price", () => {
  const v = grant({user: {freeClipUsed: true, pointsBalance: PRICE}});
  assert.strictEqual(v.cost, PRICE);
  assert.strictEqual(v.source, "points");
});

check("and is refused outright with no points", () => {
  const v = grant({user: {freeClipUsed: true, pointsBalance: 0}});
  assert.strictEqual(v.allowed, false);
  assert.strictEqual(v.reason, DENY.insufficientPoints);
});

check("A SUBSCRIBER DOES NOT BURN THEIR FREE CLIP", () => {
  // It is included for them anyway, so consuming it here would silently
  // spend something valuable on nothing - and it would be gone the day
  // their subscription lapsed.
  const v = grant({user: {}, source: "subscription",
    entitlement: {state: "subscriber"}});
  assert.strictEqual(v.source, "subscription");
  assert.notStrictEqual(v.source, "free");
});

check("nor does a trial user, who also gets it included", () => {
  const v = grant({user: {}, source: "subscription",
    entitlement: {state: "trial"}});
  assert.strictEqual(v.source, "subscription");
});

check("the free clip does NOT bypass the participant boundary", () => {
  // The safety rule outranks the giveaway: a stranger must never get a
  // clip of two other people's battle, free or otherwise.
  const v = grant({uid: "stranger", user: {}, source: "points"});
  assert.strictEqual(v.allowed, false);
  assert.strictEqual(v.reason, DENY.notParticipant);
});

check("nor does it resurrect an unfinished battle", () => {
  const v = grant({user: {}, match: matchOf({status: "pending"})});
  assert.strictEqual(v.allowed, false);
  assert.strictEqual(v.reason, DENY.matchNotReady);
});

check("a repeat tap on an already-granted clip stays idempotent", () => {
  const owned = matchOf({clipGrants: {[ME]: {source: "free", cost: 0}}});
  const v = grant({user: {}, match: owned});
  assert.strictEqual(v.reason, DENY.alreadyGranted);
  assert.strictEqual(v.cost, 0);
});

console.log(`\n${passed} checks passed.`);
