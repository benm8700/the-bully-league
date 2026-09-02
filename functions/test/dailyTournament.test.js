const assert = require("assert");
const {dailyTournamentPlan} = require("../dailyTournament");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

const CONFIG = {
  enabled: true,
  name: "Sixes and Sevens",
  startHourPacific: 18,
  endHourPacific: 19,
};

// Aug 31 2026 is PDT (UTC-7). 6:15pm PDT = 01:15 UTC on Sep 1.
const PDT_KICKOFF = Date.UTC(2026, 8, 1, 1, 15); // month 8 = September
// UTC instants on Aug 31 (PDT day), as {h}pm PDT -> +7h UTC.
const pdt = (hourPacific, minute = 0) =>
  Date.UTC(2026, 7, 31, hourPacific + 7, minute);

console.log("daily tournament plan");

check("creates tonight's tournament during the create window (4pm PDT)", () => {
  const plan = dailyTournamentPlan(pdt(16), CONFIG);
  assert.strictEqual(plan.create, true);
  assert.strictEqual(plan.dayKey, "2026-08-31");
  assert.strictEqual(plan.startsAtMs, PDT_KICKOFF,
      "kickoff is 6:15pm Pacific");
  assert.strictEqual(plan.name, "Sixes and Sevens");
});

check("kickoff is exactly 15 minutes into the window", () => {
  const plan = dailyTournamentPlan(pdt(16), CONFIG);
  const windowStart = Date.UTC(2026, 8, 1, 1, 0); // 6:00pm PDT
  assert.strictEqual(plan.startsAtMs - windowStart, 15 * 60 * 1000);
});

check("does NOT create too early (2pm PDT, >3h before check-in)", () => {
  const plan = dailyTournamentPlan(pdt(14), CONFIG);
  assert.strictEqual(plan.create, false);
  assert.strictEqual(plan.reason, "too-early");
});

check("creates right at the edge of the create window (~3pm PDT)", () => {
  // Check-in opens 6:00pm; create lead is 3h => 3:00pm. A minute after is in.
  const plan = dailyTournamentPlan(pdt(15, 1), CONFIG);
  assert.strictEqual(plan.create, true);
});

check("does NOT create once kickoff has passed (6:30pm PDT)", () => {
  const plan = dailyTournamentPlan(pdt(18, 30), CONFIG);
  assert.strictEqual(plan.create, false);
  assert.strictEqual(plan.reason, "already-started");
});

check("after the window, targets TOMORROW and is too early now", () => {
  // 8pm PDT: window ended (7pm), so tonight means tomorrow, which is >3h off.
  const plan = dailyTournamentPlan(pdt(20), CONFIG);
  assert.strictEqual(plan.create, false);
  assert.strictEqual(plan.reason, "too-early");
  assert.strictEqual(plan.dayKey, "2026-09-01");
});

check("a disabled window never creates", () => {
  const plan = dailyTournamentPlan(pdt(16), {...CONFIG, enabled: false});
  assert.strictEqual(plan.create, false);
  assert.strictEqual(plan.reason, "window-disabled");
});

check("winter (PST, UTC-8) resolves 6:15pm to the right UTC instant", () => {
  // Jan 15 2026 is PST. 4pm PST = 00:00 UTC next day.
  const nowPst = Date.UTC(2026, 0, 16, 0, 0); // Jan 16 00:00 UTC = Jan 15 4pm PST
  const plan = dailyTournamentPlan(nowPst, CONFIG);
  assert.strictEqual(plan.create, true);
  assert.strictEqual(plan.dayKey, "2026-01-15");
  // 6:15pm PST = 02:15 UTC on Jan 16.
  assert.strictEqual(plan.startsAtMs, Date.UTC(2026, 0, 16, 2, 15));
});

console.log(`\n${passed} passed`);
