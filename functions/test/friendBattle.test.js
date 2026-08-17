/**
 * Local tests for friend-battle challenge rules (functions/friendBattle.js).
 * Runs with plain `node test/friendBattle.test.js`.
 *
 * The interesting rules here are all about who may be put in front of
 * whom. Challenging is the first mechanism in this app that lets one user
 * choose another - every other path pairs strangers - so the safety rules
 * that were implicit in random matchmaking have to be explicit here, and
 * getting one wrong means someone can reach a person who blocked them.
 */

const assert = require("assert");
const {
  challengeProblem, isPending, isExpired, friendMatchId,
  MAX_OUTSTANDING, CHALLENGE_TTL_MS,
} = require("../friendBattle");

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

const NOW = 1_700_000_000_000;
const ME = "me";
const THEM = "them";

const problem = (over = {}) => challengeProblem({
  fromUid: ME,
  from: {},
  toUid: THEM,
  to: {accountStatus: "active"},
  outstanding: 0,
  nowMs: NOW,
  ...over,
});

// --- who may be challenged ------------------------------------------------

test("an ordinary player can be challenged", () => {
  assert.strictEqual(problem(), null);
});

test("you cannot challenge yourself", () => {
  assert.ok(problem({toUid: ME}) !== null);
});

test("an unknown username is refused", () => {
  assert.ok(problem({to: null, toUid: null}) !== null);
});

test("a missing accountStatus does NOT block a challenge", () => {
  // Legacy accounts have no accountStatus at all. Treating absent as
  // not-active would make every pre-existing account unchallengeable -
  // the same missing-field trap as accountStatus in enterQueue, which
  // this project has already been bitten by once.
  assert.strictEqual(problem({to: {}}), null);
});

// --- blocking -------------------------------------------------------------

test("someone who blocked me cannot be challenged by me", () => {
  assert.ok(problem({to: {blockedUserIds: [ME]}}) !== null);
});

test("someone I blocked cannot be challenged by me either", () => {
  // Two-way, like matchmaking and the directory. A block that only
  // stopped the blocked party from initiating would be useless.
  assert.ok(problem({from: {blockedUserIds: [THEM]}}) !== null);
});

test("A BLOCK IS NEVER REVEALED - the message is the not-found one", () => {
  // Telling someone "they blocked you" invites exactly the retaliation
  // blocking exists to prevent, which is why blocking is silent
  // everywhere else in the app.
  const blocked = problem({to: {blockedUserIds: [ME]}});
  const missing = problem({to: null, toUid: null});
  assert.strictEqual(blocked, missing);
});

test("a banned account is indistinguishable from a missing one", () => {
  const banned = problem({to: {accountStatus: "banned"}});
  const missing = problem({to: null, toUid: null});
  assert.strictEqual(banned, missing,
      "confirming a named account is banned is none of a stranger's business");
});

// --- spam -----------------------------------------------------------------

test("the outstanding cap is on the SENDER", () => {
  assert.strictEqual(problem({outstanding: MAX_OUTSTANDING - 1}), null);
  assert.ok(problem({outstanding: MAX_OUTSTANDING}) !== null);
  // Capping what you can RECEIVE would let one determined person fill
  // your quota and lock out your actual friends.
});

test("the cap message says what to do about it", () => {
  const msg = problem({outstanding: MAX_OUTSTANDING});
  assert.ok(msg.includes(String(MAX_OUTSTANDING)));
});

// --- lifecycle ------------------------------------------------------------

test("a fresh challenge is pending", () => {
  const c = {status: "pending", expiresAtMs: NOW + CHALLENGE_TTL_MS};
  assert.strictEqual(isPending(c, NOW), true);
  assert.strictEqual(isExpired(c, NOW), false);
});

test("an old challenge is expired even though its status still says pending", () => {
  // Expiry is applied on read rather than by a sweep, so status alone is
  // never enough - anything asking "can this be answered" must ask
  // isPending, not status.
  const c = {status: "pending", expiresAtMs: NOW - 1};
  assert.strictEqual(isExpired(c, NOW), true);
  assert.strictEqual(isPending(c, NOW), false);
});

test("a challenge with no expiry is treated as expired, not as eternal", () => {
  assert.strictEqual(isExpired({status: "pending"}, NOW), true);
});

test("an answered challenge is not pending", () => {
  for (const status of ["accepted", "declined"]) {
    assert.strictEqual(
        isPending({status, expiresAtMs: NOW + 1000}, NOW), false);
  }
});

test("the TTL is an hour - an invitation, not an appointment", () => {
  assert.strictEqual(CHALLENGE_TTL_MS, 60 * 60 * 1000);
});

// --- match id -------------------------------------------------------------

test("the match id is DERIVED from the challenge, not generated", () => {
  // Two taps must not produce two documents for one challenge, which
  // would leave each player alone in a different channel waiting for
  // someone who is never coming. Same reasoning as tournament matches.
  assert.strictEqual(friendMatchId("abc"), friendMatchId("abc"));
  assert.notStrictEqual(friendMatchId("abc"), friendMatchId("abd"));
});

console.log(`friendBattle: ${passed} checks passed`);
