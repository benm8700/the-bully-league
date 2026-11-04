const assert = require("assert");
const {
  WILDCARD_DEFAULTS, sanitiseWildcardConfig, rankedGamesOf,
  wildcardBidEligibility, isValidBid, resolveWildcardAuction, DENY,
} = require("../wildcardAuction");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

console.log("wildcardAuction");

// A config with the wildcard turned on, for the eligibility tests (it is off
// by default, like the whole tournament system).
const ON = {...WILDCARD_DEFAULTS, enabled: true};

// --------------------------------------------------------- config bounds
check("enabled is only an explicit true", () => {
  assert.strictEqual(sanitiseWildcardConfig({}).enabled, false);
  assert.strictEqual(sanitiseWildcardConfig({enabled: "yes"}).enabled, false);
  assert.strictEqual(sanitiseWildcardConfig({enabled: true}).enabled, true);
});

check("a bad field falls back per-field, keeping the good ones", () => {
  const c = sanitiseWildcardConfig({entryFee: 250, bidFloor: -5, minGames: "x"});
  assert.strictEqual(c.entryFee, 250); // good, kept
  assert.strictEqual(c.bidFloor, WILDCARD_DEFAULTS.bidFloor); // negative -> default
  assert.strictEqual(c.minGames, WILDCARD_DEFAULTS.minGames); // NaN -> default
});

check("a non-object config is all defaults", () => {
  assert.deepStrictEqual(sanitiseWildcardConfig(null), WILDCARD_DEFAULTS);
  assert.deepStrictEqual(sanitiseWildcardConfig("nope"), WILDCARD_DEFAULTS);
});

// --------------------------------------------------------- games count
check("ranked games tolerates both field names and a missing value", () => {
  assert.strictEqual(rankedGamesOf({careerRankedMatches: 8}), 8);
  assert.strictEqual(rankedGamesOf({rankedMatchesPlayed: 3}), 3);
  assert.strictEqual(rankedGamesOf({}), 0);
  assert.strictEqual(rankedGamesOf({careerRankedMatches: -2}), 0);
});

// --------------------------------------------------------- eligibility
const goodUser = {
  accountStatus: "active",
  careerRankedMatches: 10,
  profile: {introVideoUrl: "i.mp4", facePhotoUrl: "f.jpg"},
};

check("a complete, active account may bid when the wildcard is on", () => {
  const v = wildcardBidEligibility(goodUser, ON);
  assert.strictEqual(v.eligible, true);
});

check("nobody may bid while the wildcard is off (the default)", () => {
  const v = wildcardBidEligibility(goodUser, WILDCARD_DEFAULTS);
  assert.strictEqual(v.eligible, false);
  assert.strictEqual(v.reason, DENY.disabled);
});

check("an ABSENT accountStatus counts as active (missing-field trap)", () => {
  const {accountStatus, ...noStatus} = goodUser;
  void accountStatus;
  assert.strictEqual(wildcardBidEligibility(noStatus, ON).eligible, true);
});

check("a banned account is refused", () => {
  const v = wildcardBidEligibility({...goodUser, accountStatus: "banned"}, ON);
  assert.strictEqual(v.eligible, false);
  assert.strictEqual(v.reason, DENY.notActive);
});

check("no intro video is refused", () => {
  const v = wildcardBidEligibility(
      {...goodUser, profile: {facePhotoUrl: "f.jpg"}}, ON);
  assert.strictEqual(v.eligible, false);
  assert.strictEqual(v.reason, DENY.noIntro);
});

check("no face photo is refused (the gate requires BOTH)", () => {
  const v = wildcardBidEligibility(
      {...goodUser, profile: {introVideoUrl: "i.mp4"}}, ON);
  assert.strictEqual(v.eligible, false);
  assert.strictEqual(v.reason, DENY.noPhoto);
});

check("too few ranked games is refused", () => {
  const v = wildcardBidEligibility({...goodUser, careerRankedMatches: 2}, ON);
  assert.strictEqual(v.eligible, false);
  assert.strictEqual(v.reason, DENY.tooFewGames);
});

// --------------------------------------------------------- bid validity
check("a bid must clear the floor", () => {
  assert.strictEqual(isValidBid(50, ON), true);
  assert.strictEqual(isValidBid(49, ON), false);
  assert.strictEqual(isValidBid(0, ON), false);
  assert.strictEqual(isValidBid("200", ON), true);
  assert.strictEqual(isValidBid("nope", ON), false);
  assert.strictEqual(isValidBid(null, ON), false);
});

// --------------------------------------------------------- the auction
check("the highest bid wins", () => {
  const r = resolveWildcardAuction([
    {uid: "a", amount: 100, enteredAtMs: 1},
    {uid: "b", amount: 300, enteredAtMs: 2},
    {uid: "c", amount: 200, enteredAtMs: 3},
  ], {config: ON});
  assert.strictEqual(r.winnerUid, "b");
  assert.strictEqual(r.winningBid, 300);
});

check("a tie on amount is broken by who committed it FIRST", () => {
  const r = resolveWildcardAuction([
    {uid: "late", amount: 300, enteredAtMs: 99},
    {uid: "early", amount: 300, enteredAtMs: 5},
  ], {config: ON});
  assert.strictEqual(r.winnerUid, "early");
});

check("a tie on amount AND time falls to uid, deterministically", () => {
  const r = resolveWildcardAuction([
    {uid: "zed", amount: 300, enteredAtMs: 5},
    {uid: "abe", amount: 300, enteredAtMs: 5},
  ], {config: ON});
  assert.strictEqual(r.winnerUid, "abe");
});

check("below-floor and malformed bids are ignored", () => {
  const r = resolveWildcardAuction([
    {uid: "a", amount: 10, enteredAtMs: 1}, // below floor 50
    {uid: "b", amount: 60, enteredAtMs: 2},
    {uid: "", amount: 500, enteredAtMs: 3}, // no uid
    {amount: 500}, // no uid
    null,
  ], {config: ON});
  assert.strictEqual(r.winnerUid, "b");
  assert.strictEqual(r.winningBid, 60);
});

check("one bidder's highest bid is the one that counts", () => {
  const r = resolveWildcardAuction([
    {uid: "a", amount: 100, enteredAtMs: 1},
    {uid: "a", amount: 400, enteredAtMs: 2}, // same uid raises
    {uid: "b", amount: 300, enteredAtMs: 3},
  ], {config: ON});
  assert.strictEqual(r.winnerUid, "a");
  assert.strictEqual(r.winningBid, 400);
});

check("no valid bids leaves the seat unsold", () => {
  assert.strictEqual(resolveWildcardAuction([], {config: ON}).winnerUid, null);
  const r = resolveWildcardAuction([{uid: "a", amount: 1}], {config: ON});
  assert.strictEqual(r.winnerUid, null); // below floor
});

check("a top bidder who can no longer afford their bid is skipped", () => {
  // Between bidding and close they spent those points elsewhere; the seat
  // falls to the next highest who can still pay.
  const r = resolveWildcardAuction([
    {uid: "broke", amount: 500, enteredAtMs: 1},
    {uid: "ready", amount: 300, enteredAtMs: 2},
  ], {balanceOf: {broke: 120, ready: 9999}, config: ON});
  assert.strictEqual(r.winnerUid, "ready");
  assert.strictEqual(r.winningBid, 300);
  assert.strictEqual(r.skippedInsolvent, 1);
});

check("everyone insolvent leaves the seat unsold", () => {
  const r = resolveWildcardAuction([
    {uid: "a", amount: 500, enteredAtMs: 1},
    {uid: "b", amount: 300, enteredAtMs: 2},
  ], {balanceOf: {a: 0, b: 0}, config: ON});
  assert.strictEqual(r.winnerUid, null);
  assert.strictEqual(r.skippedInsolvent, 2);
});

check("an unknown balance is treated as solvent (the charge is the real gate)", () => {
  const r = resolveWildcardAuction([
    {uid: "a", amount: 300, enteredAtMs: 1},
  ], {balanceOf: {}, config: ON});
  assert.strictEqual(r.winnerUid, "a");
});

console.log(`\n${passed} checks passed.`);
