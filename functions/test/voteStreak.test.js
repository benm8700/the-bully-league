const assert = require("assert");
const {streakAfterVote, dayKeys} = require("../voteStreak");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

const TODAY = "2026-08-17";
const YESTERDAY = "2026-08-16";
const go = (current) => streakAfterVote(current, TODAY, YESTERDAY);

console.log("voteStreak");

check("a first ever vote starts a streak of one, and pays", () => {
  const r = go(undefined);
  assert.strictEqual(r.days, 1);
  assert.strictEqual(r.dayKey, TODAY);
  assert.strictEqual(r.awarded, true);
});

check("voting yesterday and again today EXTENDS the run", () => {
  const r = go({days: 4, dayKey: YESTERDAY});
  assert.strictEqual(r.days, 5);
  assert.strictEqual(r.awarded, true);
  assert.strictEqual(r.extended, true);
});

check("PAID ONCE A DAY - a second vote today awards nothing", () => {
  // vote_cast already pays per vote. This rewards the habit, not volume,
  // so a judge working through ten battles is not paid ten streak
  // bonuses.
  const r = go({days: 3, dayKey: TODAY});
  assert.strictEqual(r.awarded, false);
  assert.strictEqual(r.days, 3, "and the run does not inflate either");
});

check("A MISSED DAY RESETS the run to one", () => {
  const r = go({days: 30, dayKey: "2026-08-01"});
  assert.strictEqual(r.days, 1);
  assert.strictEqual(r.awarded, true);
  assert.strictEqual(r.extended, false);
});

check("a run of zero on yesterday's key is treated as new, not extended", () => {
  // Defensive: a malformed record must not produce a streak of 1 that
  // claims to be an extension of nothing.
  const r = go({days: 0, dayKey: YESTERDAY});
  assert.strictEqual(r.days, 1);
  assert.strictEqual(r.extended, false);
});

check("a garbage record degrades to a fresh streak rather than NaN", () => {
  for (const current of [null, {}, {days: "lots"}, {days: -5}, "streak"]) {
    const r = go(current);
    assert.strictEqual(r.days, 1, `current=${JSON.stringify(current)}`);
    assert.strictEqual(r.awarded, true);
  }
});

check("a same-day record with no count still reads as at least one", () => {
  const r = go({dayKey: TODAY});
  assert.strictEqual(r.days, 1);
  assert.strictEqual(r.awarded, false);
});

check("a long run keeps counting up", () => {
  let state = {days: 0, dayKey: null};
  const keys = ["2026-08-10", "2026-08-11", "2026-08-12", "2026-08-13"];
  keys.forEach((today, i) => {
    const yesterday = i === 0 ? "2026-08-09" : keys[i - 1];
    state = streakAfterVote(state, today, yesterday);
  });
  assert.strictEqual(state.days, 4);
});

// ------------------------------------------------------------ day keys
check("day keys are Pacific, and yesterday really is the day before", () => {
  // Pacific rather than UTC because the app's rhythm is Pacific - Sixes
  // and Sevens, the daily push, the vote reminders. A streak rolling over
  // at 5pm local would break for exactly the people the window gathers.
  const {today, yesterday} = dayKeys(Date.UTC(2026, 7, 17, 12, 0));
  assert.match(today, /^\d{4}-\d{2}-\d{2}$/);
  assert.match(yesterday, /^\d{4}-\d{2}-\d{2}$/);
  assert.notStrictEqual(today, yesterday);
  const gap = (new Date(today) - new Date(yesterday)) / 86400000;
  assert.strictEqual(gap, 1, `${yesterday} -> ${today} is not one day`);
});

check("the day boundary holds either side of Pacific midnight", () => {
  // 07:30 UTC is 00:30 Pacific in summer - just past midnight, so the
  // date must have rolled.
  const justAfter = dayKeys(Date.UTC(2026, 7, 17, 7, 30));
  const justBefore = dayKeys(Date.UTC(2026, 7, 17, 6, 30));
  assert.notStrictEqual(justAfter.today, justBefore.today,
      "Pacific midnight must roll the day key");
  assert.strictEqual(justAfter.yesterday, justBefore.today,
      "and yesterday must line up with the day just ended");
});

check("a month boundary rolls correctly", () => {
  const {today, yesterday} = dayKeys(Date.UTC(2026, 8, 1, 20, 0));
  assert.strictEqual(today, "2026-09-01");
  assert.strictEqual(yesterday, "2026-08-31");
});

console.log(`\n${passed} checks passed.`);
