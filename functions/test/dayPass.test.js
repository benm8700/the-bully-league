/**
 * Local tests for the day pass and the daily vote-points cap.
 * Runs with plain `node test/dayPass.test.js`.
 *
 * These two ship together because they only make sense together. The pass
 * is the points economy's recurring sink; the cap is what stops the
 * currency that buys it being farmable in an afternoon. Either one alone
 * is a worse design than neither.
 */

const assert = require("assert");
const {dayPassActive} = require("../dayPass");
const {dailyAwardBlocked, DEFAULTS, readPointsSettings} = require("../points");
const {battleEntitlement} = require("../entitlement");

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

// --- the pass itself ------------------------------------------------------

test("an unexpired pass is active", () => {
  assert.strictEqual(dayPassActive({dayPassExpiresAtMs: NOW + 1}, NOW), true);
});

test("an expired pass is not", () => {
  assert.strictEqual(dayPassActive({dayPassExpiresAtMs: NOW - 1}, NOW), false);
  assert.strictEqual(dayPassActive({dayPassExpiresAtMs: NOW}, NOW), false);
});

test("FAILS CLOSED on anything malformed", () => {
  // The safe direction here is the opposite of the trial check's. Getting
  // this wrong must mean "you don't have access you didn't buy", never
  // "you have access forever".
  for (const bad of [{}, {dayPassExpiresAtMs: null},
    {dayPassExpiresAtMs: "soon"}, {dayPassExpiresAtMs: NaN},
    {dayPassExpiresAtMs: Infinity}]) {
    assert.strictEqual(dayPassActive(bad, NOW), false,
        `expected inactive for ${JSON.stringify(bad)}`);
  }
});

// --- what it actually buys ------------------------------------------------

const LAPSED = {createdAt: 1, rankedMatchesPlayed: 5};
const CONFIG = {enabled: true, trialDays: 14};
const SHUT = {enabled: false};
const OPEN = {enabled: true, startHourPacific: 0, endHourPacific: 24, name: "W"};

const verdict = (user, mode, windowConfig = SHUT) => battleEntitlement({
  user, mode, nowMs: NOW, windowConfig, config: CONFIG,
});

test("a lapsed player cannot battle outside the window", () => {
  assert.strictEqual(verdict(LAPSED, "ranked").allowed, false);
});

test("THE PASS IS WHAT THEY ARE BUYING - ranked, any time", () => {
  const withPass = {...LAPSED, dayPassExpiresAtMs: NOW + 1000};
  const v = verdict(withPass, "ranked");
  assert.strictEqual(v.allowed, true);
  assert.strictEqual(v.state, "daypass");
});

test("it opens practice outside the window too", () => {
  const withPass = {...LAPSED, dayPassExpiresAtMs: NOW + 1000};
  assert.strictEqual(verdict(withPass, "exhibition").allowed, true);
});

test("A PASS CANNOT BUY AROUND THE WINDOW'S RANKED-ONLY RULE", () => {
  // That rule binds subscribers too, because it is a liquidity rule and
  // not a perk - the window exists to make one crowd, and a second queue
  // running alongside it defeats the point. If a pass could open Practice
  // during the hour, money would be splitting the pool.
  const withPass = {...LAPSED, dayPassExpiresAtMs: NOW + 1000};
  assert.strictEqual(verdict(withPass, "exhibition", OPEN).allowed, false);
  assert.strictEqual(verdict(withPass, "ranked", OPEN).allowed, true);
});

test("an expired pass grants nothing", () => {
  const stale = {...LAPSED, dayPassExpiresAtMs: NOW - 1};
  assert.strictEqual(verdict(stale, "ranked").allowed, false);
  assert.strictEqual(verdict(stale, "ranked").state, "lapsed");
});

test("a subscriber is still reported as a subscriber, not a pass holder", () => {
  const both = {createdAt: 1, subscription: {active: true},
    dayPassExpiresAtMs: NOW + 1000};
  assert.strictEqual(verdict(both, "ranked").state, "subscriber");
});

test("with enforcement OFF a pass changes nothing, because nothing is shut", () => {
  const v = battleEntitlement({
    user: LAPSED, mode: "ranked", nowMs: NOW,
    windowConfig: SHUT, config: {enabled: false, trialDays: 14},
  });
  assert.strictEqual(v.allowed, true);
});

// --- the vote cap ---------------------------------------------------------

test("under the cap, votes pay", () => {
  const user = {dailyAwards: {vote_cast: {day: "2026-08-17", count: 9}}};
  assert.strictEqual(
      dailyAwardBlocked(user, "vote_cast", "2026-08-17", 10), false);
});

test("at the cap, they stop paying", () => {
  const user = {dailyAwards: {vote_cast: {day: "2026-08-17", count: 10}}};
  assert.strictEqual(
      dailyAwardBlocked(user, "vote_cast", "2026-08-17", 10), true);
});

test("A NEW DAY RESETS, rather than carrying yesterday forward", () => {
  // The exact bug the vote reminders hit: an increment across a day
  // boundary meant being reminded once yesterday blocked you all of
  // today.
  const user = {dailyAwards: {vote_cast: {day: "2026-08-16", count: 999}}};
  assert.strictEqual(
      dailyAwardBlocked(user, "vote_cast", "2026-08-17", 10), false);
});

test("MIGRATION: an account with no counter is never blocked", () => {
  // Every existing account has no dailyAwards map. Reading a missing
  // record as "at the cap" would silently stop paying the entire
  // userbase - the missing-field trap this project keeps meeting.
  assert.strictEqual(dailyAwardBlocked({}, "vote_cast", "2026-08-17", 10), false);
  assert.strictEqual(
      dailyAwardBlocked({dailyAwards: {}}, "vote_cast", "2026-08-17", 10), false);
});

test("the cap is per reason, so one does not starve another", () => {
  const user = {dailyAwards: {vote_cast: {day: "2026-08-17", count: 50}}};
  assert.strictEqual(
      dailyAwardBlocked(user, "match_played", "2026-08-17", 10), false);
});

test("no cap configured means no cap applied", () => {
  const user = {dailyAwards: {vote_cast: {day: "2026-08-17", count: 999}}};
  for (const max of [undefined, null, 0, -1, NaN]) {
    assert.strictEqual(
        dailyAwardBlocked(user, "vote_cast", "2026-08-17", max), false);
  }
});

// --- config ---------------------------------------------------------------

test("the new rates are bounds-checked like every other", () => {
  assert.strictEqual(readPointsSettings({votePointsPerDay: 0}).votePointsPerDay,
      DEFAULTS.votePointsPerDay,
      "0 would switch judging's reward off entirely, which is not what a " +
      "cap is for");
  assert.strictEqual(readPointsSettings({dayPassPrice: -5}).dayPassPrice,
      DEFAULTS.dayPassPrice);
  assert.strictEqual(readPointsSettings({votePointsPerDay: 25})
      .votePointsPerDay, 25, "a sane override must still apply");
});

test("the kill switch needs an explicit false", () => {
  // A typo, a missing field or a stray string must never silently
  // disable a live feature - only a deliberate `false` does.
  assert.strictEqual(readPointsSettings({}).dayPassEnabled, true);
  assert.strictEqual(readPointsSettings({dayPassEnabled: "false"})
      .dayPassEnabled, true);
  assert.strictEqual(readPointsSettings({dayPassEnabled: 0})
      .dayPassEnabled, true);
  assert.strictEqual(readPointsSettings({dayPassEnabled: false})
      .dayPassEnabled, false);
});

test("the pass is priced well above a day's capped judging", () => {
  // The whole conversion argument rests on this: grinding a pass has to be
  // a plainly worse deal than subscribing, or it becomes a substitute for
  // the subscription rather than a sample of it.
  const dailyVoteCeiling = DEFAULTS.voteCast * DEFAULTS.votePointsPerDay;
  assert.ok(DEFAULTS.dayPassPrice > dailyVoteCeiling * 2,
      `a pass (${DEFAULTS.dayPassPrice}) must cost well over a day of ` +
      `capped judging (${dailyVoteCeiling})`);
});

console.log(`dayPass: ${passed} checks passed`);
