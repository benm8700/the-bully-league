const assert = require("assert");
const {
  matchesWorthNudging, reminderCopy, canRemind, nextReminderRecord,
  MAX_PER_USER_PER_DAY, WELL_JUDGED_VOTES, CLOSING_SOON_MS,
} = require("../voteReminder");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

const NOW = 1_700_000_000_000;
const HOUR = 60 * 60 * 1000;

const openMatch = (over = {}) => ({
  status: "completed",
  voteFinalized: false,
  voteCount: 1,
  windowEndMs: NOW + 2 * HOUR,
  player1Id: "a",
  player2Id: "b",
  ...over,
});

console.log("voteReminder");

// ------------------------------------------------- what deserves a push
check("an under-judged match closing soon is worth a nudge", () => {
  assert.strictEqual(matchesWorthNudging([openMatch()], NOW).length, 1);
});

check("a WELL-JUDGED match is left alone - it needs no rescuing", () => {
  const busy = openMatch({voteCount: WELL_JUDGED_VOTES});
  assert.strictEqual(matchesWorthNudging([busy], NOW).length, 0);
});

check("a match with hours to spare can be rescued later, so no push now", () => {
  const early = openMatch({windowEndMs: NOW + CLOSING_SOON_MS + HOUR});
  assert.strictEqual(matchesWorthNudging([early], NOW).length, 0);
});

check("an already-closed match is never nudged about", () => {
  assert.strictEqual(
      matchesWorthNudging([openMatch({windowEndMs: NOW - 1})], NOW).length, 0);
  assert.strictEqual(
      matchesWorthNudging([openMatch({voteFinalized: true})], NOW).length, 0);
});

check("an unfinished match is never nudged about", () => {
  assert.strictEqual(
      matchesWorthNudging([openMatch({status: "pending"})], NOW).length, 0);
  assert.strictEqual(
      matchesWorthNudging([openMatch({status: "abandoned"})], NOW).length, 0);
});

check("a missing voteCount counts as zero votes, not as well judged", () => {
  const m = openMatch();
  delete m.voteCount;
  assert.strictEqual(matchesWorthNudging([m], NOW).length, 1);
});

// ------------------------------------------------------------ the copy
check("NOTHING IS SENT when nothing is waiting", () => {
  // A reminder on an empty night teaches people the notification is noise,
  // and that is unrecoverable - a muted app loses every category.
  assert.strictEqual(reminderCopy(0), null);
  assert.strictEqual(reminderCopy(-1), null);
});

check("the copy leads with a real number and names the cost", () => {
  const c = reminderCopy(5);
  assert.ok(c.title.includes("5"), c.title);
  assert.ok(/minute/.test(c.body), c.body);
});

check("singular reads properly, so the app never says '1 battles'", () => {
  const c = reminderCopy(1);
  assert.ok(!/1 battles/.test(c.title + c.body), c.title);
});

check("the reciprocal variant states NO count", () => {
  // One multicast carries one body, but each participant's honest number
  // differs since they cannot judge their own battle. Better to say
  // something true without a number than something slightly wrong.
  const c = reminderCopy(5, {reciprocal: true});
  assert.ok(!/\d/.test(c.body), `reciprocal copy must not claim a count: ${c.body}`);
  assert.ok(/Return the favour/.test(c.body), c.body);
});

// --------------------------------------------------------- who gets one
check("ONE PER DAY, and the second is refused", () => {
  const day = "2026-08-17";
  const fresh = {fcmTokens: ["t"], accountStatus: "active"};
  assert.strictEqual(canRemind(fresh, day), true);
  const reminded = {...fresh, voteReminder: {dayKey: day, count: MAX_PER_USER_PER_DAY}};
  assert.strictEqual(canRemind(reminded, day), false);
});

check("yesterday's reminder does not block today's", () => {
  const reminded = {
    fcmTokens: ["t"], accountStatus: "active",
    voteReminder: {dayKey: "2026-08-16", count: 5},
  };
  assert.strictEqual(canRemind(reminded, "2026-08-17"), true);
});

check("someone with no device is never chased", () => {
  assert.strictEqual(canRemind({fcmTokens: [], accountStatus: "active"}, "d"), false);
  assert.strictEqual(canRemind({accountStatus: "active"}, "d"), false);
});

check("a banned account is not chased, but a legacy one still is", () => {
  assert.strictEqual(
      canRemind({fcmTokens: ["t"], accountStatus: "banned"}, "d"), false);
  // An ABSENT accountStatus means a legacy account, which the rest of the
  // codebase treats as active. Reading it as non-active would silently
  // exclude every pre-existing user.
  assert.strictEqual(canRemind({fcmTokens: ["t"]}, "d"), true);
});

// ------------------------------------------------------- the day record
check("REGRESSION: a new day resets the count instead of carrying it", () => {
  // Written absolutely rather than incremented. An increment would carry
  // yesterday's count into today, so someone reminded once yesterday
  // would land on 2 today and be blocked for the whole day.
  const yesterday = {voteReminder: {dayKey: "2026-08-16", count: 1}};
  assert.deepStrictEqual(
      nextReminderRecord(yesterday, "2026-08-17"),
      {dayKey: "2026-08-17", count: 1});
});

check("a same-day record counts up", () => {
  const today = {voteReminder: {dayKey: "2026-08-17", count: 1}};
  assert.deepStrictEqual(
      nextReminderRecord(today, "2026-08-17"),
      {dayKey: "2026-08-17", count: 2});
});

check("a user who has never been reminded starts at one", () => {
  assert.deepStrictEqual(
      nextReminderRecord({}, "2026-08-17"), {dayKey: "2026-08-17", count: 1});
});

check("the record and the gate agree: one send makes canRemind false", () => {
  // The two halves must line up, or the cap is decorative.
  const day = "2026-08-17";
  const user = {fcmTokens: ["t"], accountStatus: "active"};
  const after = {...user, voteReminder: nextReminderRecord(user, day)};
  assert.strictEqual(canRemind(after, day), false);
});

console.log(`\n${passed} checks passed.`);
