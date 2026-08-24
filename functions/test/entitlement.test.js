const assert = require("assert");
const {
  DEFAULTS, DENY, DAY_MS, battleEntitlement, isSubscriber, isInTrial, toMillis,
} = require("../entitlement");
const {DEFAULTS: WINDOW_DEFAULTS} = require("../eventWindow");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

// 6:30pm Pacific on a summer day (PDT, UTC-7) => 01:30 UTC next day.
const IN_WINDOW = Date.UTC(2026, 6, 15, 1, 30);
// 2:00pm Pacific the same day.
const OUT_OF_WINDOW = Date.UTC(2026, 6, 15, 21, 0);

const WINDOW = {...WINDOW_DEFAULTS, enabled: true};
const ON = {trialDays: 14, enabled: true};
const OFF = {trialDays: 14, enabled: false};

const userAgedDays = (days, extra = {}) => ({
  createdAt: IN_WINDOW - days * DAY_MS,
  rankedMatchesPlayed: 5,
  ...extra,
});

function verdict(user, mode, nowMs, config = ON) {
  return battleEntitlement({user, mode, nowMs, windowConfig: WINDOW, config});
}

console.log("entitlement");

// ---------------------------------------------------------------- window
check("the window really is detected as open and closed", () => {
  assert.strictEqual(verdict(userAgedDays(1), "ranked", IN_WINDOW).inWindow, true);
  assert.strictEqual(
      verdict(userAgedDays(1), "ranked", OUT_OF_WINDOW).inWindow, false);
});

// ------------------------------------------------------------ master off
check("enforcement off allows everything, including a lapsed account", () => {
  const lapsed = userAgedDays(60);
  for (const mode of ["ranked", "exhibition", "tournament"]) {
    for (const now of [IN_WINDOW, OUT_OF_WINDOW]) {
      assert.strictEqual(verdict(lapsed, mode, now, OFF).allowed, true);
    }
  }
});

// ----------------------------------------------------------------- trial
check("a fresh account is in trial and may do anything outside the window", () => {
  const v = verdict(userAgedDays(1), "exhibition", OUT_OF_WINDOW);
  assert.strictEqual(v.allowed, true);
  assert.strictEqual(v.state, "trial");
});

check("the trial expires exactly at trialDays, not before", () => {
  // Ages measured from the moment being judged, not from IN_WINDOW - the
  // two clock points here are ~19.5h apart, which is enough to push a
  // "13.9 day old" account over a 14-day boundary.
  const agedFrom = (now, days) => ({createdAt: now - days * DAY_MS});
  assert.strictEqual(
      verdict(agedFrom(OUT_OF_WINDOW, 13.9), "ranked", OUT_OF_WINDOW).state,
      "trial");
  assert.strictEqual(
      verdict(agedFrom(OUT_OF_WINDOW, 14.1), "ranked", OUT_OF_WINDOW).state,
      "lapsed");
  // And exactly at the boundary the trial is over, not still running.
  assert.strictEqual(
      verdict(agedFrom(OUT_OF_WINDOW, 14), "ranked", OUT_OF_WINDOW).state,
      "lapsed");
});

// ------------------------------------------------------------ subscriber
check("a subscriber battles any mode outside the window", () => {
  const sub = userAgedDays(60, {subscription: {active: true}});
  assert.strictEqual(verdict(sub, "ranked", OUT_OF_WINDOW).allowed, true);
  assert.strictEqual(verdict(sub, "exhibition", OUT_OF_WINDOW).allowed, true);
  assert.strictEqual(verdict(sub, "ranked", OUT_OF_WINDOW).state, "subscriber");
});

check("an expired subscription is not a subscription", () => {
  const expired = userAgedDays(60, {
    subscription: {active: true, expiresAtMs: OUT_OF_WINDOW - 1},
  });
  assert.strictEqual(verdict(expired, "ranked", OUT_OF_WINDOW).allowed, false);
});

check("a subscription with no expiry is open-ended, not lapsed", () => {
  const granted = userAgedDays(60, {subscription: {active: true}});
  assert.strictEqual(isSubscriber(granted, OUT_OF_WINDOW), true);
});

check("active must be exactly true", () => {
  for (const active of ["true", 1, undefined, null]) {
    assert.strictEqual(
        isSubscriber(userAgedDays(60, {subscription: {active}}), IN_WINDOW),
        false, `active=${JSON.stringify(active)} must not subscribe`);
  }
});

// ---------------------------------------------------------------- lapsed
check("THE MODEL: lapsed plays ranked in the window and nothing outside", () => {
  const lapsed = userAgedDays(60);
  assert.strictEqual(verdict(lapsed, "ranked", IN_WINDOW).allowed, true);

  const outside = verdict(lapsed, "ranked", OUT_OF_WINDOW);
  assert.strictEqual(outside.allowed, false);
  assert.strictEqual(outside.reason, DENY.subscriptionRequired);

  assert.strictEqual(
      verdict(lapsed, "exhibition", OUT_OF_WINDOW).allowed, false);
});

// ------------------------------------------------- ranked-only in window
check("practice is closed during the window even for a subscriber", () => {
  const sub = userAgedDays(60, {subscription: {active: true}});
  const v = verdict(sub, "exhibition", IN_WINDOW);
  assert.strictEqual(v.allowed, false);
  assert.strictEqual(v.reason, DENY.practiceClosedDuringWindow);
});

check("practice is closed during the window for a trial user too", () => {
  assert.strictEqual(
      verdict(userAgedDays(1), "exhibition", IN_WINDOW).allowed, false);
});

check("CARVE-OUT: someone who has never played ranked may still practice", () => {
  const newcomer = userAgedDays(0, {rankedMatchesPlayed: 0});
  assert.strictEqual(verdict(newcomer, "exhibition", IN_WINDOW).allowed, true);
});

check("the carve-out closes as soon as they have played one ranked match", () => {
  const one = userAgedDays(0, {rankedMatchesPlayed: 1});
  assert.strictEqual(verdict(one, "exhibition", IN_WINDOW).allowed, false);
});

check("a missing rankedMatchesPlayed counts as never having played", () => {
  const legacy = {createdAt: IN_WINDOW};
  assert.strictEqual(verdict(legacy, "exhibition", IN_WINDOW).allowed, true);
});

// ------------------------------------------------------------ tournament
check("tournament entry is never blocked - the fee already bought it", () => {
  const lapsed = userAgedDays(60);
  assert.strictEqual(verdict(lapsed, "tournament", OUT_OF_WINDOW).allowed, true);
  assert.strictEqual(verdict(lapsed, "tournament", IN_WINDOW).allowed, true);
});

// ------------------------------------------------------------- fail open
check("REGRESSION: a legacy account with no createdAt is treated as in trial", () => {
  // Every account predating this feature has no usable signup date.
  // Reading that as "trial long over" would lock the entire existing
  // userbase out of battling the moment enforcement was switched on -
  // the same trap as the missing accountStatus field.
  const legacy = {rankedMatchesPlayed: 9};
  const v = verdict(legacy, "ranked", OUT_OF_WINDOW);
  assert.strictEqual(v.allowed, true);
  assert.strictEqual(v.state, "trial");
});

check("createdAt is read from a Firestore Timestamp, a Date, or millis", () => {
  const ms = IN_WINDOW - 1 * DAY_MS;
  for (const createdAt of [ms, new Date(ms), {toMillis: () => ms}]) {
    assert.strictEqual(
        isInTrial({createdAt}, IN_WINDOW, 14), true,
        `${createdAt} should read as a 1-day-old account`);
  }
});

check("toMillis refuses 0 and null rather than reading them as the epoch", () => {
  assert.strictEqual(toMillis(0), null);
  assert.strictEqual(toMillis(null), null);
  assert.strictEqual(toMillis(undefined), null);
});

check("a disabled event window cannot make practice unavailable", () => {
  // If the window is switched off there is no ranked-only hour, so a
  // subscriber must be able to practice at any time of day.
  const sub = userAgedDays(60, {subscription: {active: true}});
  const v = battleEntitlement({
    user: sub, mode: "exhibition", nowMs: IN_WINDOW,
    windowConfig: {...WINDOW_DEFAULTS, enabled: false}, config: ON,
  });
  assert.strictEqual(v.allowed, true);
  assert.strictEqual(v.inWindow, false);
});

check("defaults are the documented ones and ship switched OFF", () => {
  assert.strictEqual(DEFAULTS.trialDays, 14);
  assert.strictEqual(DEFAULTS.enabled, false);
});

// ------------------------------------------------- friend battles are free
check("A FRIEND BATTLE IS FREE FOR EVERYONE, in every state", () => {
  // Free by decision: you bring your own opponent, so it costs the shared
  // queue nothing, and it is the one route into a battle that works when
  // nobody else is online. It already moves no rating and pays no points,
  // so there is nothing here to protect.
  //
  // friendBattle.js never calls battleEntitlement, so this was true only
  // because nothing asked - while the policy, if asked, used to refuse a
  // lapsed account by lumping friend in with practice. Pinned so that
  // adding a check "for consistency" cannot silently paywall it.
  const users = [userAgedDays(60), userAgedDays(1),
    userAgedDays(60, {subscription: {active: true}})];
  for (const user of users) {
    for (const now of [IN_WINDOW, OUT_OF_WINDOW]) {
      const v = verdict(user, "friend", now);
      assert.strictEqual(v.allowed, true,
          `friend refused for ${v.state} (inWindow=${v.inWindow})`);
    }
  }
});

console.log(`\n${passed} checks passed.`);
