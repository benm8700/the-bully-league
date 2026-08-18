/**
 * Local tests for the weekly recap (functions/weeklyRecap.js).
 * Runs with `node test/weeklyRecap.test.js`.
 *
 * The rule worth pinning hardest is that an EMPTY recap is never sent. A
 * push reading "0 battles, 0 wins" is not a summary - it is a
 * notification telling somebody they were absent, which is a reason to
 * mute the app rather than open it. Muting is also unrecoverable from
 * inside the app and takes every other category with it, so the cost of
 * getting this wrong is not one bad message.
 */

const assert = require("assert");
const {
  pacificWeekKey,
  inSendWindow,
  summarise,
  worthSending,
  recapCopy,
  MAX_RECIPIENTS,
} = require("../weeklyRecap");

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

// --- never send an empty one ---------------------------------------------

test("THE RULE: a week with nothing in it is not sent", () => {
  assert.strictEqual(worthSending(summarise([])), false);
  assert.strictEqual(worthSending({matchesPlayed: 0, votesCast: 0}), false);
});

test("a week of only SPENDING is still an empty week", () => {
  // Buying a clip or a day pass is not a week's activity, and a recap
  // celebrating it would be reporting a purchase as an achievement.
  const s = summarise([
    {reason: "clip", amount: -250},
    {reason: "dayPass", amount: -500},
  ]);
  assert.strictEqual(worthSending(s), false);
  assert.strictEqual(s.pointsEarned, 0, "spends must never count as earned");
});

test("JUDGING ALONE COUNTS as a real week", () => {
  // Votes are the scarce resource the ladder runs on. A recap that only
  // recognised battling would tell the app's most useful people they did
  // nothing.
  assert.strictEqual(
      worthSending(summarise([{reason: "vote_cast", amount: 5}])), true);
});

test("battling alone counts too", () => {
  assert.strictEqual(
      worthSending(summarise([{reason: "match_played", amount: 10}])), true);
});

// --- the numbers ---------------------------------------------------------

test("the ledger is counted by reason, not by amount", () => {
  const s = summarise([
    {reason: "match_played", amount: 10},
    {reason: "match_played", amount: 10},
    {reason: "match_won", amount: 25},
    {reason: "vote_cast", amount: 5},
    {reason: "vote_cast", amount: 5},
    {reason: "vote_cast", amount: 5},
    {reason: "vote_streak_2026-08-18", amount: 15},
  ]);
  assert.strictEqual(s.matchesPlayed, 2);
  assert.strictEqual(s.wins, 1);
  assert.strictEqual(s.votesCast, 3);
  assert.strictEqual(s.pointsEarned, 75, "every positive award counts");
});

test("a malformed entry cannot poison the totals", () => {
  const s = summarise([null, undefined, {}, {amount: "lots"},
    {reason: "match_played"}]);
  assert.strictEqual(s.matchesPlayed, 1);
  assert.ok(Number.isFinite(s.pointsEarned));
});

// --- copy ---------------------------------------------------------------

test("the copy leads with what they actually did", () => {
  const judgeOnly = recapCopy(summarise([
    {reason: "vote_cast", amount: 5}, {reason: "vote_cast", amount: 5},
  ]));
  assert.ok(/judged/.test(judgeOnly.body));
  assert.ok(!/battles,/.test(judgeOnly.body),
      "a judge should not be told about battles they did not play");

  const playOnly = recapCopy(summarise([
    {reason: "match_played", amount: 10}, {reason: "match_won", amount: 25},
  ]));
  assert.ok(/battle/.test(playOnly.body));
  assert.ok(!/judged/.test(playOnly.body),
      "a player should not be told they judged nothing");
});

test("a perfect week is called what it is", () => {
  const s = summarise([
    {reason: "match_played", amount: 10}, {reason: "match_won", amount: 25},
    {reason: "match_played", amount: 10}, {reason: "match_won", amount: 25},
  ]);
  assert.ok(/won every one/.test(recapCopy(s).body), recapCopy(s).body);
});

test("plurals agree, because '1 battles' makes an app feel unfinished", () => {
  const one = recapCopy(summarise([{reason: "match_played", amount: 10}]));
  assert.ok(/1 battle,/.test(one.body), one.body);
  assert.ok(!/1 battles/.test(one.body));
  const two = recapCopy(summarise([
    {reason: "match_played", amount: 10}, {reason: "match_played", amount: 10},
  ]));
  assert.ok(/2 battles/.test(two.body), two.body);
});

test("zero points earned is not mentioned at all", () => {
  const s = summarise([{reason: "match_played", amount: 0}]);
  assert.ok(!/0 points/.test(recapCopy(s).body), recapCopy(s).body);
});

test("it points somewhere - a recap with no next step is just a receipt", () => {
  const s = summarise([{reason: "match_played", amount: 10}]);
  assert.ok(/tonight/.test(recapCopy(s).body));
});

// --- scheduling ----------------------------------------------------------

test("every day of a week maps to the same Sunday key", () => {
  // Sunday 2026-08-16 Pacific through the following Saturday. Times are
  // mid-afternoon UTC so the Pacific date is unambiguous.
  const keys = new Set();
  for (let d = 16; d <= 22; d++) {
    keys.add(pacificWeekKey(new Date(`2026-08-${d}T20:00:00Z`)));
  }
  assert.strictEqual(keys.size, 1, [...keys].join(", "));
  assert.strictEqual([...keys][0], "2026-08-16");
});

test("the next Sunday starts a new key", () => {
  assert.notStrictEqual(
      pacificWeekKey(new Date("2026-08-22T20:00:00Z")),
      pacificWeekKey(new Date("2026-08-23T20:00:00Z")));
});

test("it only sends on a Sunday evening Pacific", () => {
  // Sunday 2026-08-16, 18:00 Pacific = 01:00 UTC on the 17th.
  assert.strictEqual(inSendWindow(new Date("2026-08-17T01:00:00Z")), true);
  // Same Sunday but the morning.
  assert.strictEqual(inSendWindow(new Date("2026-08-16T17:00:00Z")), false);
  // Monday evening.
  assert.strictEqual(inSendWindow(new Date("2026-08-18T01:00:00Z")), false);
});

test("the recipient cap is small enough to find a bug at", () => {
  assert.ok(MAX_RECIPIENTS <= 500,
      "a bug discovered at userbase size is discovered too late");
});

console.log(`weeklyRecap: ${passed} checks passed`);
