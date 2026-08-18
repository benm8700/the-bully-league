/**
 * Local tests for judging rewards (functions/judgeRewards.js).
 * Runs with `node test/judgeRewards.test.js`.
 *
 * Weighted heavily toward the CEILING. Skips are worth more to a
 * rating-manipulator than to an honest player, so an uncapped mint here
 * would reintroduce exactly the opponent cherry-picking the daily cap
 * exists to prevent - and it would do it quietly, looking like a generous
 * reward rather than a hole.
 */

const assert = require("assert");
const {
  judgeVotesToday,
  earnedSkips,
  skipAllowance,
  priorityBonusMs,
  judgeVoteUpdate,
  VOTES_PER_EARNED_SKIP,
  MAX_EARNED_SKIPS,
  HARD_TOTAL_SKIP_CAP,
  MAX_PRIORITY_MS,
} = require("../judgeRewards");

const TODAY = "2026-08-18";
const YESTERDAY = "2026-08-17";

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

// --- the ceiling ---------------------------------------------------------

test("THE CEILING HOLDS however many votes are cast", () => {
  for (const votes of [10, 50, 1000, 1e9]) {
    const user = {judgeDayKey: TODAY, judgeVotesToday: votes};
    assert.strictEqual(earnedSkips(user, TODAY), MAX_EARNED_SKIPS,
        `${votes} votes minted more than the cap`);
    assert.ok(skipAllowance(user, TODAY, 3) <= HARD_TOTAL_SKIP_CAP);
  }
});

test("the hard cap binds even if the BASE allowance is raised later", () => {
  // The base is a separate constant that could plausibly be raised for
  // subscribers. The ceiling that protects ranked must not drift upward
  // as a side effect of that.
  const user = {judgeDayKey: TODAY, judgeVotesToday: 99};
  assert.strictEqual(skipAllowance(user, TODAY, 6), HARD_TOTAL_SKIP_CAP);
  assert.strictEqual(skipAllowance(user, TODAY, 100), HARD_TOTAL_SKIP_CAP);
});

test("earning is gradual, not all-or-nothing", () => {
  const at = (n) => earnedSkips({judgeDayKey: TODAY, judgeVotesToday: n}, TODAY);
  assert.strictEqual(at(0), 0);
  assert.strictEqual(at(VOTES_PER_EARNED_SKIP - 1), 0);
  assert.strictEqual(at(VOTES_PER_EARNED_SKIP), 1);
  assert.strictEqual(at(VOTES_PER_EARNED_SKIP * 2), 2);
});

// --- expiry --------------------------------------------------------------

test("EARNED SKIPS EXPIRE WITH THE DAY, they never bank up", () => {
  const user = {judgeDayKey: YESTERDAY, judgeVotesToday: 99};
  assert.strictEqual(earnedSkips(user, TODAY), 0);
  assert.strictEqual(skipAllowance(user, TODAY, 3), 3);
});

test("ONE DAY BOUNDARY: earning and spending cannot straddle two", () => {
  // Vote POINTS are keyed to the Pacific day; these are keyed to the same
  // UTC day the skip allowance resets on. Two boundaries would let
  // somebody earn at 4pm Pacific, watch the UTC day roll at 5pm, and
  // arrive at a fresh base allowance still holding the earned ones.
  const user = judgeVoteUpdate({}, TODAY);
  assert.strictEqual(user.judgeDayKey, TODAY,
      "the counter must be stamped with the day it will be spent against");
});

test("a new day RESETS rather than incrementing", () => {
  // An increment alongside a new day key is exactly the bug the vote
  // reminders hit at a day boundary - yesterday's count carrying into
  // today.
  const stale = {judgeDayKey: YESTERDAY, judgeVotesToday: 7};
  assert.deepStrictEqual(judgeVoteUpdate(stale, TODAY),
      {judgeDayKey: TODAY, judgeVotesToday: 1});
});

test("counting up through a day works", () => {
  let user = {};
  for (let i = 1; i <= 4; i++) {
    user = {...user, ...judgeVoteUpdate(user, TODAY)};
    assert.strictEqual(user.judgeVotesToday, i);
  }
});

// --- missing and hostile data -------------------------------------------

test("A MISSING COUNTER MEANS NOTHING EARNED, never an error", () => {
  // Every account predating this has no counter at all. This project has
  // met the missing-field trap four times already; here the safe reading
  // is zero, since the field only ever GRANTS something.
  for (const u of [undefined, null, {}, {judgeDayKey: TODAY}]) {
    assert.strictEqual(judgeVotesToday(u, TODAY), 0);
    assert.strictEqual(earnedSkips(u, TODAY), 0);
    assert.strictEqual(priorityBonusMs(u, TODAY), 0);
  }
});

test("junk in the counter cannot mint anything", () => {
  for (const bad of ["lots", -5, NaN, Infinity, {}, []]) {
    const user = {judgeDayKey: TODAY, judgeVotesToday: bad};
    assert.strictEqual(earnedSkips(user, TODAY), 0,
        `minted from ${String(bad)}`);
    assert.ok(priorityBonusMs(user, TODAY) >= 0);
  }
});

// --- priority ------------------------------------------------------------

test("priority is bounded, so it can never starve a non-judge", () => {
  const user = {judgeDayKey: TODAY, judgeVotesToday: 1e6};
  assert.strictEqual(priorityBonusMs(user, TODAY), MAX_PRIORITY_MS);
});

test("more judging means more priority, up to the bound", () => {
  const at = (n) => priorityBonusMs({judgeDayKey: TODAY, judgeVotesToday: n},
      TODAY);
  assert.ok(at(2) > at(1));
  assert.ok(at(1) > at(0));
});

test("THE BOUND STAYS UNDER THE STANDING THRESHOLD, or it stops being " +
    "a tiebreak", () => {
  // A queue entry becomes a standing challenge after 90 seconds and is
  // then sorted behind every live waiter. So the live candidates
  // competing on wait time span at most that window - and a bonus
  // larger than it would let an active judge beat every live non-judge
  // outright, which is a separate priority queue rather than a
  // tiebreak. Asserted against the real constant so the two cannot
  // drift apart silently.
  const {STANDING_AFTER_MS} = require("../standingChallenge");
  assert.ok(MAX_PRIORITY_MS < STANDING_AFTER_MS,
      `bonus ${MAX_PRIORITY_MS}ms must stay under the ` +
      `${STANDING_AFTER_MS}ms standing threshold`);
  // And meaningfully under, not merely a millisecond under.
  assert.ok(MAX_PRIORITY_MS <= STANDING_AFTER_MS / 2);
});

test("priority expires with the day too", () => {
  const user = {judgeDayKey: YESTERDAY, judgeVotesToday: 10};
  assert.strictEqual(priorityBonusMs(user, TODAY), 0);
});

console.log(`judgeRewards: ${passed} checks passed`);
